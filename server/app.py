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
    ctc_greedy_decode, LipReadingModel, DualStreamModel
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


@app.get("/health")
async def health_check():
    """เช็กสถานะ Server"""
    return {
        "status": "healthy",
        "models_loaded": list(models.keys()),
        "model_details": {
            name: {
                "type": info["type"],
                "vocab_size": len(info["itos"]),
            }
            for name, info in models.items()
        }
    }


@app.get("/models")
async def list_models():
    """ดูรายชื่อโมเดลที่มี"""
    return {
        name: {
            "type": info["type"],
            "config": info["config"],
            "vocab_size": len(info["itos"]),
        }
        for name, info in models.items()
    }


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


# ─── Run Server ───────────────────────────────────────────────────────────────

if __name__ == "__main__":
    import uvicorn
    uvicorn.run("app:app", host="0.0.0.0", port=8000, reload=True)
