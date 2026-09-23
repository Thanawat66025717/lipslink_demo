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
    load_vocalip_word_model, load_vocalip_real_model,
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

# โหมด debug สำหรับไล่ตรวจ pipeline ทีละขั้น เปิดด้วย VOCALIP_DEBUG=1
# หรือส่ง {"debug": true} มากับ request เป็นครั้งๆ ก็ได้
# เปิดแล้วจะ print ทุกขั้นลง console และเซฟภาพ mouth ROI ล่าสุดไว้ดู
DEBUG_DEFAULT = os.getenv("VOCALIP_DEBUG", "0").lower() not in ("0", "", "false", "no")
DEBUG_DIR = os.path.join(os.path.dirname(__file__), "debug")

# เกณฑ์ปฏิเสธผลที่ไม่น่าเชื่อถือ ค่าตั้งต้นมากับ checkpoint (ดู meta['rejection'])
# จึงไม่ต้องตั้งเองที่นี่ ตัวแปรสภาพแวดล้อมสองตัวนี้ไว้ทับค่านั้นเวลาอยากลองจูน
# โดยไม่ต้องแก้ไฟล์โมเดล — ตั้งแล้วรีสตาร์ท server พอ ไม่ต้อง build APK ใหม่
_env_conf = os.getenv("VOCALIP_MIN_CONFIDENCE")
MIN_WORD_CONFIDENCE_ENV = float(_env_conf) if _env_conf else None

# ปิด motion gate ได้เวลาต้องการดูว่าโมเดลตอบอะไรจริงๆ โดยไม่มีด่านมาขวาง
MOTION_GATE_ENABLED = os.getenv("VOCALIP_MOTION_GATE", "1").lower() not in (
    "0", "", "false", "no")

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
    #
    # รองรับสอง checkpoint ที่ฟอร์แมตต่างกัน เรียงจากใหม่ไปเก่า ตัวแรกที่เจอชนะ
    # รุ่น 05 บอกค่า deployment มาครบกว่ามาก (ลำดับช่องสี, เกณฑ์ปฏิเสธ,
    # motion gate) จึงไม่ต้องเดาอะไรเองเหมือนตอนใช้รุ่น 03
    word_candidates = [
        ("05_44word_real_lipreading_deployment.pt", load_vocalip_real_model),
        ("03_vocalip_44words_deployment.pt", load_vocalip_word_model),
    ]
    for filename, loader in word_candidates:
        word_path = os.path.join(MODEL_DIR, filename)
        if not os.path.exists(word_path):
            continue
        try:
            model, id_to_word, meta = loader(word_path)
            models["vocalip_word"] = {
                "model": model,
                "id_to_word": id_to_word,
                "meta": meta,
                "type": "word_classifier",
            }
            pre = meta.get("preprocessing", {})
            metrics = meta.get("test_metrics", {})
            print(
                f"✅ VocaLip word model loaded: {filename} "
                f"({meta['num_classes']} words, "
                f"{_want_frames(meta)} frames, roi={_roi_size(meta)}, "
                f"channels={pre.get('cache_channel_order', 'BGR')})"
            )
            if metrics:
                print(
                    f"   test acc={metrics.get('accuracy', 0):.2%} "
                    f"macro-F1={metrics.get('macro_f1', 0):.4f} "
                    f"top3={metrics.get('top3', 0):.2%}"
                )
            print(f"   ⚠️ scope: {meta.get('scope')}")
            break
        except Exception as e:
            print(f"❌ Failed to load {filename}: {e}")
    else:
        print("⚠️ ไม่พบ checkpoint โมเดลทำนายคำใน server/models/")

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
    # เปิด debug เฉพาะ request นี้ โดยไม่ต้องรีสตาร์ท server ด้วย VOCALIP_DEBUG
    debug: Optional[bool] = None


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
    # หมายเหตุ: เป็นแค่ "ธง" ไม่ได้กรองผลทิ้ง — top_k คืนค่าดิบเสมอ
    low_confidence: bool
    # เกณฑ์ที่ใช้ตัดสิน low_confidence ส่งมาด้วยเพื่อให้ตรวจสอบได้ว่า server
    # ตั้งไว้เท่าไร โดยไม่ต้องเดาจากฝั่ง client
    min_confidence: float
    # ระยะห่างระหว่างอันดับ 1 กับอันดับ 2 — ใกล้กันมากแปลว่าโมเดลลังเล
    # แม้ความมั่นใจอันดับ 1 จะดูสูงก็ตาม checkpoint กำหนดเกณฑ์นี้มาด้วย
    min_margin: float
    margin: float
    # ปริมาณการขยับปากที่วัดได้ และเกณฑ์ที่ checkpoint กำหนด (null = ไม่ได้ใช้)
    mouth_motion: float
    motion_threshold: Optional[float] = None
    # ข้อที่ไม่ผ่าน: "confidence" / "margin" / "motion" — ว่างแปลว่าผ่านหมด
    reject_reasons: List[str] = []
    # มีค่าเฉพาะตอนเปิด debug — รูปร่าง/ช่วงค่าของ tensor ในแต่ละขั้น
    debug: Optional[dict] = None


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
        "format": meta.get("format"),
        "config": meta.get("config", {}),
        "frames": _want_frames(meta),
        "roi": _roi_size(meta),
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
    """base64 -> ภาพสีเรียงช่องแบบ BGR ขนาด roi x roi (uint8, HWC)

    ⚠️ ต้องเป็น BGR ไม่ใช่ RGB — training cache สร้างด้วย OpenCV ซึ่งให้ BGR
    และตอนเทรนไม่มีการแปลงเป็น RGB ก่อนเข้าโมเดล (ยืนยันจากผู้เทรนแล้ว)
    ถ้าสลับเป็น RGB ตรงนี้ โมเดลจะเห็นผิวหน้าเป็นโทนฟ้าและทำนายเพี้ยน
    โดยไม่มี error ฟ้อง

    cv2.imdecode คืนค่าเป็น BGR อยู่แล้ว จึงใช้ได้ตรงๆ ไม่ต้องแปลง
    ส่วนทาง PIL ได้ RGB มา ต้องกลับลำดับช่องเองให้เป็น BGR
    """
    img_bytes = base64.b64decode(b64_string)
    img_array = np.frombuffer(img_bytes, dtype=np.uint8)
    img = cv2.imdecode(img_array, cv2.IMREAD_COLOR)   # BGR ตามที่โมเดลต้องการ

    if img is None:
        pil_img = Image.open(io.BytesIO(img_bytes)).convert("RGB")
        img = np.array(pil_img)[:, :, ::-1]            # RGB -> BGR

    if img.shape[:2] != (roi, roi):
        img = cv2.resize(img, (roi, roi))

    return np.ascontiguousarray(img)


def _want_frames(meta: dict) -> int:
    """จำนวนเฟรมที่โมเดลรับ — คีย์คนละชื่อกันระหว่าง checkpoint สองรุ่น"""
    pre = meta.get("preprocessing", {})
    cfg = meta.get("config", {})
    return int(pre.get("target_frames") or cfg.get("frames") or 16)


def _roi_size(meta: dict) -> int:
    """ขนาดด้านของภาพปากที่โมเดลรับ (จัตุรัส)"""
    pre = meta.get("preprocessing", {})
    cfg = meta.get("config", {})
    return int(pre.get("roi_size") or cfg.get("roi") or 112)


def _mouth_motion(frames: np.ndarray) -> float:
    """ปริมาณการขยับปากตลอดคลิป — สูตรเดียวกับ motion_score() ใน Notebook 05

    ลำดับสำคัญมาก: เฉลี่ย 3 ช่องสีให้เป็นภาพเทา "ก่อน" แล้วค่อยหาผลต่างระหว่าง
    เฟรม ถ้าสลับลำดับ (หาผลต่างทีละช่องแล้วค่อยเฉลี่ย) จะได้ค่าสูงกว่าเสมอ
    เพราะเครื่องหมายลบกันเองไม่ได้ ทำให้เทียบกับ threshold ผิดสเกล

    แล้วตัดเอาเฉพาะกลางภาพ (แถว 25-80%, คอลัมน์ 12-88%) เพื่อตัดขอบที่เป็น
    คาง จมูก และพื้นหลัง ซึ่งขยับตามหัวโดยไม่เกี่ยวกับการพูด
    """
    if len(frames) < 2:
        return 0.0

    x = frames.astype(np.float32) / 255.0
    gray = x.mean(-1)                                   # (T, H, W)
    diff = np.abs(gray[1:] - gray[:-1])

    h, w = gray.shape[1:]
    diff = diff[:, int(.25 * h):int(.80 * h), int(.12 * w):int(.88 * w)]
    return float(diff.mean())


def _save_debug_frames(frames: np.ndarray) -> dict:
    """เซฟภาพ mouth ROI ที่ server ได้รับจริงลง server/debug/ ไว้เปิดดูด้วยตา

    frames เป็น BGR อยู่แล้ว และ cv2.imwrite ก็คาดหวัง BGR พอดี จึงเขียนตรงๆ ได้
    ถ้าเปิดไฟล์แล้วเห็นผิวหน้าเป็นโทนฟ้า แปลว่า client ส่งช่องสีสลับมา
    """
    os.makedirs(DEBUG_DIR, exist_ok=True)
    paths = {}

    last = frames[-1]
    last_path = os.path.join(DEBUG_DIR, "last_mouth_roi.png")
    cv2.imwrite(last_path, last)
    paths["last_roi"] = last_path

    # เรียงทุกเฟรมต่อกันเป็นแถบเดียว จะได้เห็นว่าปากขยับจริงตลอดคลิปหรือนิ่งค้าง
    strip_path = os.path.join(DEBUG_DIR, "frames_strip.png")
    cv2.imwrite(strip_path, np.concatenate(list(frames), axis=1))
    paths["strip"] = strip_path

    return paths


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
    pre = meta["preprocessing"]

    want_frames = _want_frames(meta)
    roi = _roi_size(meta)
    mean = np.array(pre.get("mean", [0.485, 0.456, 0.406]), dtype=np.float32)
    std = np.array(pre.get("std", [0.229, 0.224, 0.225]), dtype=np.float32)

    # เกณฑ์ปฏิเสธมากับ checkpoint ให้ใช้ค่านั้นเป็นหลัก ยกเว้นตั้ง env มาทับ
    rej = meta.get("rejection", {})
    min_conf = (MIN_WORD_CONFIDENCE_ENV
                if MIN_WORD_CONFIDENCE_ENV is not None
                else float(rej.get("confidence_threshold_start", 0.35)))
    min_margin = float(rej.get("top1_top2_margin_start", 0.0))

    gate = meta.get("motion_gate", {})
    gate_on = bool(gate.get("enabled")) and MOTION_GATE_ENABLED
    gate_threshold = float(gate.get("starting_threshold", 0.0))

    debug = DEBUG_DEFAULT if request.debug is None else bool(request.debug)
    dbg: dict = {}

    try:
        selected = _pick_evenly(list(request.frames), want_frames)
        frames = np.stack([_decode_color_frame(b, roi) for b in selected])

        # ลำดับขั้นตรงตาม preprocessing ที่ checkpoint ระบุ:
        # /255 -> (x-mean)/std -> THWC->TCHW -> เพิ่มมิติ batch
        # ไม่มีการสลับ BGR->RGB เพราะ checkpoint ระบุ convert_bgr_to_rgb=False
        x = frames.astype(np.float32) / 255.0
        x = (x - mean[None, None, None, :]) / std[None, None, None, :]
        x = np.ascontiguousarray(np.transpose(x, (0, 3, 1, 2)), dtype=np.float32)

        tensor = torch.from_numpy(x).unsqueeze(0)      # [1, T, C, H, W]

        with torch.no_grad():
            logits = model(tensor)
            probs = torch.softmax(logits, dim=1)[0]

        k = max(1, min(int(request.top_k or 3), len(id_to_word)))
        top_p, top_i = torch.topk(probs, k)

        candidates = [
            WordCandidate(
                word=id_to_word.get(int(i), f"<{int(i)}>"),
                confidence=round(float(p), 4),
            )
            for p, i in zip(top_p, top_i)
        ]

        motion = _mouth_motion(frames)

        if debug:
            dbg = {
                "buffer": f"{len(request.frames)} received -> {want_frames} used",
                "roi_shape": list(frames.shape[1:]),
                "roi_uint8_range": [int(frames.min()), int(frames.max())],
                "channel_order": pre.get("cache_channel_order", "BGR"),
                "mouth_motion": round(motion, 6),
                "motion_threshold": round(gate_threshold, 6),
                "input_tensor_shape": list(tensor.shape),
                "input_tensor_dtype": str(tensor.dtype),
                "input_tensor_min": round(float(tensor.min()), 4),
                "input_tensor_max": round(float(tensor.max()), 4),
                "logits_shape": list(logits.shape),
                "logits_min": round(float(logits.min()), 4),
                "logits_max": round(float(logits.max()), 4),
                "vocab_size": len(id_to_word),
            }
            dbg["debug_images"] = _save_debug_frames(frames)
            _print_word_debug(dbg, candidates)

    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Prediction error: {str(e)}")

    elapsed = (time.time() - start_time) * 1000

    # เหตุผลที่ปฏิเสธ แยกกันคนละข้อ เพื่อให้ไล่ได้ว่าติดด่านไหน
    # ทั้งสามข้อมาจาก checkpoint ไม่ใช่เกณฑ์ที่ฝั่ง deployment คิดขึ้นเอง
    margin = (candidates[0].confidence - candidates[1].confidence
              if len(candidates) > 1 else candidates[0].confidence)

    reasons = []
    if candidates[0].confidence < min_conf:
        reasons.append("confidence")
    if margin < min_margin:
        reasons.append("margin")
    if gate_on and motion < gate_threshold:
        reasons.append("motion")

    return WordPredictResponse(
        word=candidates[0].word,
        confidence=candidates[0].confidence,
        top_k=candidates,
        processing_time_ms=round(elapsed, 2),
        num_frames_received=len(request.frames),
        num_frames_used=want_frames,
        low_confidence=bool(reasons),
        min_confidence=min_conf,
        min_margin=min_margin,
        margin=round(margin, 4),
        mouth_motion=round(motion, 6),
        motion_threshold=round(gate_threshold, 6) if gate_on else None,
        reject_reasons=reasons,
        debug=dbg or None,
    )


def _print_word_debug(dbg: dict, candidates: List[WordCandidate]) -> None:
    """พิมพ์สรุปแต่ละขั้นของ pipeline ลง console ให้ไล่ดูได้ทีละบรรทัด"""
    print("─" * 52, flush=True)
    print(f"Buffer: {dbg['buffer']}", flush=True)
    print(f"ROI: {tuple(dbg['roi_shape'])} {dbg['channel_order']} "
          f"uint8 range {dbg['roi_uint8_range']}", flush=True)
    print(f"Input tensor: {tuple(dbg['input_tensor_shape'])} "
          f"{dbg['input_tensor_dtype']} "
          f"min={dbg['input_tensor_min']} max={dbg['input_tensor_max']}",
          flush=True)
    print(f"Logits: {tuple(dbg['logits_shape'])} "
          f"min={dbg['logits_min']} max={dbg['logits_max']}", flush=True)
    print(f"Mouth motion: {dbg['mouth_motion']} "
          f"(threshold {dbg['motion_threshold']})", flush=True)
    print(f"\nTOP-{len(candidates)}", flush=True)
    for rank, c in enumerate(candidates, 1):
        print(f"{rank}. {c.word}\t{c.confidence:.4f}", flush=True)
    print(f"\nsaved: {dbg['debug_images']['last_roi']}", flush=True)
    print("─" * 52, flush=True)


@app.get("/word_model_info")
async def word_model_info():
    """ข้อมูลโมเดลทำนายคำ รวมรายการคำทั้งหมดและผลวัดที่ผู้เทรนบันทึกมา"""
    entry = models.get("vocalip_word")
    if entry is None:
        raise HTTPException(status_code=503, detail="โมเดลทำนายคำยังไม่ถูกโหลด")

    meta = entry["meta"]
    pre = meta.get("preprocessing", {})
    return {
        "format": meta["format"],
        "config": meta.get("config", {}),
        "preprocessing": pre,
        "frames": _want_frames(meta),
        "roi": _roi_size(meta),
        # รุ่น 05 ระบุ cache_channel_order มาตรงๆ ส่วนรุ่น 03 เขียนไว้กำกวมว่า
        # "cached order; no channel swap" จึงเติมค่าที่ยืนยันกับผู้เทรนแล้วให้
        "channel_order_resolved": pre.get("cache_channel_order", "BGR"),
        "rejection": meta.get("rejection", {}),
        "motion_gate": meta.get("motion_gate", {}),
        # สูตรเดียวกับ motion_score() ใน Notebook 05 CELL 16
        "motion_metric": (
            "mean |gray(t) - gray(t-1)| where gray = mean over channels, "
            "cropped to rows 25-80% and cols 12-88%, 0-1 scale"
        ),
        "test_metrics": meta.get("test_metrics", {}),
        "scope": meta.get("scope"),
        "words": [entry["id_to_word"][i] for i in sorted(entry["id_to_word"])],
    }


# ─── Run Server ───────────────────────────────────────────────────────────────

if __name__ == "__main__":
    import uvicorn
    uvicorn.run("app:app", host="0.0.0.0", port=8000, reload=True)
