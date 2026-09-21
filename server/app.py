"""
LipsLink API Server
FastAPI server สำหรับรับ lip frames จากแอป Flutter แล้วรัน prediction ด้วย PyTorch
"""

import os
import sys
import io
import base64
import time
import numpy as np
import cv2
import torch

# Fix Windows cp1252 encoding error when printing emojis
if sys.platform == 'win32':
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')
    sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding='utf-8')

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from typing import List, Optional
from PIL import Image

from lip_model import (
    load_model_1, load_model_2,
    ctc_greedy_decode, LipReadingModel, DualStreamModel,
    load_vocalip_word_model,
)

# ─── App Setup ────────────────────────────────────────────────────────────────

app = FastAPI(
    title="LipsLink API",
    description="API สำหรับอ่านปาก (Lip Reading) ด้วย AI",
    version="1.0.0",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# ─── Load Models on Startup ──────────────────────────────────────────────────

MODEL_DIR = os.path.join(os.path.dirname(__file__), "models")

# Global model storage
models = {}


@app.on_event("startup")
async def load_models():
    """โหลดโมเดลทั้งหมดตอน server เริ่มต้น"""
    global models

    # Model 1: lip frames only
    model1_path = os.path.join(MODEL_DIR, "best_model_1_9_26.pt")
    if os.path.exists(model1_path):
        try:
            model, itos, config = load_model_1(model1_path)
            models["model1"] = {"model": model, "itos": itos, "config": config, "type": "lip_only"}
            print(f"✅ Model 1 loaded: {model1_path} (lip frames, image_size={config.get('image_size', 96)})")
        except Exception as e:
            print(f"❌ Failed to load Model 1: {e}")
    else:
        print(f"⚠️ Model 1 not found: {model1_path}")

    # Model 2: face + mouth
    model2_path = os.path.join(MODEL_DIR, "best_model_2_9_26.pt")
    if os.path.exists(model2_path):
        try:
            model, itos, config = load_model_2(model2_path)
            models["model2"] = {"model": model, "itos": itos, "config": config, "type": "dual_stream"}
            print(f"✅ Model 2 loaded: {model2_path} (face+mouth, face={config.get('face_size', 112)}, mouth={config.get('mouth_size', 96)})")
        except Exception as e:
            print(f"❌ Failed to load Model 2: {e}")
    else:
        print(f"⚠️ Model 2 not found: {model2_path}")

    # VocaLip Thai: ทำนายเป็น "คำ" จาก 44 คำที่เทรนไว้ (คนละตระกูลกับสองตัวบน
    # ซึ่งเป็น CTC ระดับตัวอักษร) จึงแยก endpoint และแยก preprocessing กันคนละชุด
    word_path = os.path.join(MODEL_DIR, "03_vocalip_44words_deployment.pt")
    if os.path.exists(word_path):
        try:
            model, id_to_word, meta = load_vocalip_word_model(word_path)
            models["vocalip_word"] = {
                "model": model,
                "id_to_word": id_to_word,
                "meta": meta,
                "type": "word_classifier",
            }
            cfg = meta["config"]
            acc = meta.get("test_metrics", {}).get("accuracy")
            print(
                f"✅ VocaLip word model loaded: {word_path} "
                f"({meta['num_classes']} words, {cfg.get('frames')} frames, "
                f"roi={cfg.get('roi')}, test acc={acc:.2%})"
                if acc is not None else
                f"✅ VocaLip word model loaded: {word_path}"
            )
            print(f"   ⚠️ scope: {meta.get('scope')}")
        except Exception as e:
            print(f"❌ Failed to load VocaLip word model: {e}")
    else:
        print(f"⚠️ VocaLip word model not found: {word_path}")

    if not models:
        print("⚠️ No models loaded! Place .pt files in server/models/")


# ─── Request/Response Models ─────────────────────────────────────────────────

class PredictRequest(BaseModel):
    """Request body สำหรับ prediction"""
    frames: List[str]  # List of base64-encoded grayscale lip frame images
    face_frames: Optional[List[str]] = None  # For dual-stream model (optional)
    model: Optional[str] = "model1"  # "model1" or "model2"


class PredictResponse(BaseModel):
    """Response body สำหรับ prediction"""
    text: str
    confidence: float
    model_used: str
    processing_time_ms: float
    num_frames: int


class WordPredictRequest(BaseModel):
    """Request body สำหรับโมเดลทำนายคำ (VocaLip 44 คำ)

    frames: ภาพปาก base64 (PNG/JPEG) เรียงตามเวลา — ส่งมากี่เฟรมก็ได้
            เซิร์ฟเวอร์จะเลือกให้เหลือ 16 เฟรมกระจายเท่าๆ กันเอง
    """
    frames: List[str]
    top_k: Optional[int] = 3


class WordCandidate(BaseModel):
    word: str
    confidence: float


class WordPredictResponse(BaseModel):
    word: str
    confidence: float
    top_k: List[WordCandidate]
    processing_time_ms: float
    num_frames_received: int
    num_frames_used: int
    # ต่ำกว่าเกณฑ์นี้ควรถือว่า "ไม่แน่ใจ" — โมเดลบังคับเลือก 1 ใน 44 คำเสมอ
    # แม้ผู้ใช้จะพูดคำนอกชุด จึงต้องให้ client ตัดสินใจเองได้
    low_confidence: bool


# ─── Helper Functions ─────────────────────────────────────────────────────────

def decode_base64_frame(b64_string: str, target_size: tuple) -> np.ndarray:
    """แปลง base64 string กลับเป็นภาพ grayscale แล้ว resize"""
    img_bytes = base64.b64decode(b64_string)
    img_array = np.frombuffer(img_bytes, dtype=np.uint8)
    img = cv2.imdecode(img_array, cv2.IMREAD_GRAYSCALE)

    if img is None:
        # Try loading with PIL as fallback
        pil_img = Image.open(io.BytesIO(img_bytes)).convert('L')
        img = np.array(pil_img)

    # Resize to target size
    img = cv2.resize(img, target_size)

    # Normalize to 0-1
    img = img.astype(np.float32) / 255.0

    return img


# ─── API Endpoints ────────────────────────────────────────────────────────────

@app.get("/")
async def root():
    return {
        "service": "LipsLink API",
        "status": "running",
        "models_loaded": list(models.keys()),
    }


def _model_summary(info: dict) -> dict:
    """สรุปข้อมูลโมเดลแบบรองรับทั้งตระกูล CTC (itos) และตระกูลทำนายคำ

    สองตระกูลเก็บ metadata คนละคีย์กัน จึงต้องแยกอ่าน ไม่งั้น endpoint
    ที่วนทุกโมเดลจะพังทันทีที่มีโมเดลตระกูลใหม่โผล่มา
    """
    if "itos" in info:
        return {
            "type": info["type"],
            "config": info.get("config", {}),
            "vocab_size": len(info["itos"]),
        }

    meta = info.get("meta", {})
    return {
        "type": info["type"],
        "config": meta.get("config", {}),
        "vocab_size": meta.get("num_classes"),
        "test_metrics": meta.get("test_metrics", {}),
        "scope": meta.get("scope"),
    }


@app.get("/health")
async def health_check():
    """เช็กสถานะ Server"""
    return {
        "status": "healthy",
        "models_loaded": list(models.keys()),
        "model_details": {
            name: _model_summary(info) for name, info in models.items()
        },
    }


@app.get("/models")
async def list_models():
    """ดูรายชื่อโมเดลที่มี"""
    return {name: _model_summary(info) for name, info in models.items()}


@app.post("/predict", response_model=PredictResponse)
async def predict(request: PredictRequest):
    """
    รับ lip frames (base64) แล้วรัน prediction

    - model1: ส่งแค่ frames (lip images 96x96)
    - model2: ส่ง frames (mouth 96x96) + face_frames (face 112x112)
    """
    start_time = time.time()

    # Validate model selection
    model_key = request.model or "model1"
    if model_key not in models:
        available = list(models.keys())
        if not available:
            raise HTTPException(status_code=503, detail="ไม่มีโมเดลโหลดอยู่ กรุณาตรวจสอบไฟล์ .pt")
        model_key = available[0]  # Fallback to first available

    model_info = models[model_key]
    model = model_info["model"]
    itos = model_info["itos"]
    config = model_info["config"]

    # Validate frames
    if not request.frames or len(request.frames) == 0:
        raise HTTPException(status_code=400, detail="ไม่มี frames ส่งมา")

    try:
        with torch.no_grad():
            if model_info["type"] == "lip_only":
                # ─── Model 1: lip frames only ─────────────────────────────
                img_size = config.get("image_size", 96)
                frames = []
                for b64 in request.frames:
                    frame = decode_base64_frame(b64, (img_size, img_size))
                    frames.append(frame)

                # Stack: (1, T, H, W)
                frames_tensor = torch.FloatTensor(np.array(frames)).unsqueeze(0)
                logits = model(frames_tensor)  # (1, T, vocab_size)

            elif model_info["type"] == "dual_stream":
                # ─── Model 2: face + mouth ────────────────────────────────
                mouth_size = config.get("mouth_size", 96)
                face_size = config.get("face_size", 112)

                mouth_frames = []
                for b64 in request.frames:
                    frame = decode_base64_frame(b64, (mouth_size, mouth_size))
                    mouth_frames.append(frame)

                face_frames = []
                if request.face_frames:
                    for b64 in request.face_frames:
                        frame = decode_base64_frame(b64, (face_size, face_size))
                        face_frames.append(frame)
                else:
                    # Fallback: ใช้ mouth frames resize เป็น face size
                    for b64 in request.frames:
                        frame = decode_base64_frame(b64, (face_size, face_size))
                        face_frames.append(frame)

                mouth_tensor = torch.FloatTensor(np.array(mouth_frames)).unsqueeze(0)
                face_tensor = torch.FloatTensor(np.array(face_frames)).unsqueeze(0)
                logits = model(face_tensor, mouth_tensor)  # (1, T, vocab_size)

            else:
                raise HTTPException(status_code=500, detail=f"Unknown model type: {model_info['type']}")

            # CTC Decode
            probs = torch.softmax(logits[0], dim=-1)
            text = ctc_greedy_decode(probs, itos)

            # Confidence: average max probability per timestep
            max_probs = torch.max(probs, dim=-1).values
            confidence = float(torch.mean(max_probs).item())

    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Prediction error: {str(e)}")

    elapsed = (time.time() - start_time) * 1000  # ms

    return PredictResponse(
        text=text if text else "(ไม่สามารถอ่านได้)",
        confidence=round(confidence, 4),
        model_used=model_key,
        processing_time_ms=round(elapsed, 2),
        num_frames=len(request.frames),
    )


# ─── VocaLip 44-word prediction ──────────────────────────────────────────────

def _decode_color_frame(b64_string: str, roi: int) -> np.ndarray:
    """base64 -> ภาพสี RGB ขนาด roi x roi (uint8, HWC)"""
    img_bytes = base64.b64decode(b64_string)
    img_array = np.frombuffer(img_bytes, dtype=np.uint8)
    img = cv2.imdecode(img_array, cv2.IMREAD_COLOR)   # ได้ BGR จาก OpenCV

    if img is None:
        pil_img = Image.open(io.BytesIO(img_bytes)).convert("RGB")
        img = np.array(pil_img)                        # RGB อยู่แล้ว
    else:
        img = cv2.cvtColor(img, cv2.COLOR_BGR2RGB)     # ทำให้เป็น RGB เสมอ

    if img.shape[:2] != (roi, roi):
        img = cv2.resize(img, (roi, roi))

    return img


def _pick_evenly(items: list, n: int) -> list:
    """เลือก n รายการกระจายเท่าๆ กันจาก items

    ถ้ามีน้อยกว่า n จะวนซ้ำเฟรมสุดท้ายให้ครบ เพราะโมเดลรับความยาวคงที่
    """
    if len(items) == n:
        return items
    if len(items) > n:
        idx = np.linspace(0, len(items) - 1, n).round().astype(int)
        return [items[i] for i in idx]
    return items + [items[-1]] * (n - len(items))


@app.post("/predict_word", response_model=WordPredictResponse)
async def predict_word(request: WordPredictRequest):
    """ทำนายว่าเป็นคำใดใน 44 คำ จากลำดับภาพปาก

    ต่างจาก /predict ตรงที่ตัวนี้คืน "คำเดียว" ต่อหนึ่งคลิป ไม่ใช่ข้อความอิสระ
    """
    start_time = time.time()

    entry = models.get("vocalip_word")
    if entry is None:
        raise HTTPException(
            status_code=503,
            detail="โมเดลทำนายคำยังไม่ถูกโหลด ตรวจสอบไฟล์ใน server/models/",
        )

    if not request.frames:
        raise HTTPException(status_code=400, detail="ไม่มี frames ส่งมา")

    model = entry["model"]
    id_to_word = entry["id_to_word"]
    meta = entry["meta"]
    cfg = meta["config"]
    pre = meta["preprocessing"]

    want_frames = int(cfg.get("frames", 16))
    roi = int(cfg.get("roi", 112))
    mean = np.array(pre.get("mean", [0.485, 0.456, 0.406]), dtype=np.float32)
    std = np.array(pre.get("std", [0.229, 0.224, 0.225]), dtype=np.float32)

    try:
        selected = _pick_evenly(list(request.frames), want_frames)
        frames = np.stack([_decode_color_frame(b, roi) for b in selected])

        # ลำดับขั้นตรงตาม Notebook 03 CELL 2: /255 -> (x-mean)/std -> THWC->TCHW
        x = frames.astype(np.float32) / 255.0
        x = (x - mean[None, None, None, :]) / std[None, None, None, :]
        x = np.ascontiguousarray(np.transpose(x, (0, 3, 1, 2)), dtype=np.float32)

        tensor = torch.from_numpy(x).unsqueeze(0)      # [1, T, C, H, W]

        with torch.no_grad():
            probs = torch.softmax(model(tensor), dim=1)[0]

        k = max(1, min(int(request.top_k or 3), len(id_to_word)))
        top_p, top_i = torch.topk(probs, k)

        candidates = [
            WordCandidate(
                word=id_to_word.get(int(i), f"<{int(i)}>"),
                confidence=round(float(p), 4),
            )
            for p, i in zip(top_p, top_i)
        ]

    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Prediction error: {str(e)}")

    elapsed = (time.time() - start_time) * 1000

    return WordPredictResponse(
        word=candidates[0].word,
        confidence=candidates[0].confidence,
        top_k=candidates,
        processing_time_ms=round(elapsed, 2),
        num_frames_received=len(request.frames),
        num_frames_used=want_frames,
        low_confidence=candidates[0].confidence < 0.35,
    )


@app.get("/word_model_info")
async def word_model_info():
    """ข้อมูลโมเดลทำนายคำ รวมรายการคำทั้งหมดและผลวัดที่ผู้เทรนบันทึกมา"""
    entry = models.get("vocalip_word")
    if entry is None:
        raise HTTPException(status_code=503, detail="โมเดลทำนายคำยังไม่ถูกโหลด")

    meta = entry["meta"]
    return {
        "format": meta["format"],
        "config": meta["config"],
        "preprocessing": meta["preprocessing"],
        "test_metrics": meta["test_metrics"],
        "scope": meta["scope"],
        "words": [entry["id_to_word"][i] for i in sorted(entry["id_to_word"])],
    }


# ─── Run Server ───────────────────────────────────────────────────────────────

if __name__ == "__main__":
    import uvicorn
    uvicorn.run("app:app", host="0.0.0.0", port=8000, reload=True)
