"""
LipsLink API Server
FastAPI server สำหรับรับ lip frames จากแอป Flutter แล้วรัน prediction ด้วย PyTorch
"""

import os
import sys
import io
import csv
import base64
import time
import logging
from datetime import datetime
import numpy as np
import cv2
import torch

# Fix Windows cp1252 encoding error when printing emojis
if sys.platform == 'win32':
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')
    sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding='utf-8')


class _HealthCheckLogFilter(logging.Filter):
    """กรอง log การเรียก /health และ /word_model_info ออกจาก console

    แอป Flutter ยิงสอง endpoint นี้เองทุก 20 วินาทีตลอดเวลาที่เปิดหน้าสแกน
    (เช็กว่า server ยังพร้อมมั้ย + ดึงค่า preprocessing ปัจจุบัน) ไม่ใช่ error
    และไม่ได้บอกอะไรที่มีประโยชน์ต่อการ debug แต่ถ้าไม่กรองออก console จะเต็ม
    ไปด้วยบรรทัดพวกนี้จนหา log ของ /predict_word ที่สำคัญกว่าไม่เจอ
    """

    def filter(self, record: logging.LogRecord) -> bool:
        msg = record.getMessage()
        return "/health" not in msg and "/word_model_info" not in msg


logging.getLogger("uvicorn.access").addFilter(_HealthCheckLogFilter())

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from typing import List, Optional
from PIL import Image

from lip_model import load_vocalip_word_model, load_vocalip_real_model
from vocalip_ctc import load_vocalip_ctc, resample_to_fps, predict_text
from vocalip_v4 import router as v4_router, preload as v4_preload

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
app.include_router(v4_router)

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

# อัตราขยายกรอบครอปปากที่จะบอกให้แอปใช้ — ยังไม่รู้ว่าตอนเทรนใช้เท่าไร
# (checkpoint ไม่ได้บอกมา และยังไม่ได้โค้ดที่สร้าง cache จากผู้เทรน) ตั้งค่านี้
# แล้วรีสตาร์ท server แอปจะรับไปใช้เองภายใน 20 วินาที ไม่ต้อง build APK ใหม่
# จึงลองหลายค่าเทียบกันได้เร็ว
_env_scale = os.getenv("VOCALIP_MOUTH_SCALE")
MOUTH_SCALE_OVERRIDE = float(_env_scale) if _env_scale else None

# Global model storage
models = {}


@app.on_event("startup")
async def load_models():
    """โหลดโมเดลทั้งหมดตอน server เริ่มต้น"""
    global models

    # VocaLip Thai: ทำนายเป็น "คำ" จาก 44 คำที่เทรนไว้
    #
    # รองรับสอง checkpoint ที่ฟอร์แมตต่างกัน เรียงจากใหม่ไปเก่า ตัวแรกที่เจอชนะ
    # รุ่น 05 บอกค่า deployment มาครบกว่ามาก (ลำดับช่องสี, เกณฑ์ปฏิเสธ,
    # motion gate) จึงไม่ต้องเดาอะไรเองเหมือนตอนใช้รุ่น 03
    # หาไฟล์ *_deployment.pt ทุกตัวในโฟลเดอร์ แล้วเรียงจากใหม่ไปเก่าตามชื่อ
    # (ผู้เทรนขึ้นต้นชื่อด้วยเลขโน้ตบุ๊ก 03_, 05_, ... ซึ่งเรียงตามรุ่นพอดี)
    # ไม่ผูกกับชื่อไฟล์ตายตัว เพราะรุ่นหน้าจะชื่ออะไรก็ได้ ถ้าผูกไว้แล้วลืมแก้
    # server จะเงียบๆ ไม่โหลดอะไรเลย หรือแย่กว่านั้นคือเสิร์ฟรุ่นเก่าต่อไป
    deployment_files = sorted(
        (f for f in os.listdir(MODEL_DIR) if f.endswith("_deployment.pt")),
        reverse=True,
    ) if os.path.isdir(MODEL_DIR) else []

    # ลองตัวโหลดทั้งสองแบบกับทุกไฟล์ ตัวไหนอ่านฟอร์แมตได้ก็ใช้ตัวนั้น
    word_candidates = [
        (f, loader)
        for f in deployment_files
        for loader in (load_vocalip_real_model, load_vocalip_word_model)
    ]
    for filename, loader in word_candidates:
        word_path = os.path.join(MODEL_DIR, filename)
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
        except ValueError:
            # ฟอร์แมตไม่ตรงกับตัวโหลดนี้ เป็นเรื่องปกติเพราะเราลองทุกคู่
            # ไฟล์จริงที่พังจะโยน exception ชนิดอื่นแล้วรายงานข้างล่างแทน
            continue
        except Exception as e:
            print(f"❌ Failed to load {filename}: {e}")
    else:
        # บอกให้ชัดว่าเจอไฟล์อะไร ฟอร์แมตอะไร และเรารองรับอะไร — ไม่งั้นเวลา
        # ผู้เทรนส่ง checkpoint ฟอร์แมตใหม่มา server จะเงียบเฉยๆ แล้วต้องมานั่ง
        # เดาว่าไฟล์หาย ไฟล์พัง หรือชื่อผิด
        print("⚠️ ไม่พบ checkpoint โมเดลทำนายคำที่อ่านได้ใน server/models/")
        if deployment_files:
            print(f"   เจอไฟล์ {len(deployment_files)} ไฟล์ แต่อ่านฟอร์แมตไม่ได้:")
            for f in deployment_files:
                try:
                    fmt = torch.load(
                        os.path.join(MODEL_DIR, f),
                        map_location="cpu", weights_only=False,
                    ).get("format", "(ไม่มีคีย์ format)")
                except Exception as e:
                    fmt = f"(เปิดไม่ได้: {e})"
                print(f"     {f}  ->  format={fmt!r}")
            print("   ฟอร์แมตที่รองรับ: 'VocaLip-44word-real-lipreading-v1', "
                  "'VocaLipThai-44Word-v1'")
        else:
            print("   ไม่มีไฟล์ที่ลงท้ายด้วย _deployment.pt เลย")

    # โมเดลประโยค (ทดลอง) — ไม่มีก็ไม่เป็นไร server ยังให้บริการโมเดลอื่นต่อ
    ctc_dir = os.path.join(MODEL_DIR, "vocalip_th_ctc")
    if os.path.isdir(ctc_dir):
        try:
            encoder, ctc, id_to_char, meta = load_vocalip_ctc(ctc_dir)
            models["vocalip_sentence"] = {
                "encoder": encoder, "ctc": ctc, "id_to_char": id_to_char,
                "meta": meta, "type": "sentence_ctc",
            }
            print(
                f"✅ VocaLip sentence model loaded (EXPERIMENTAL): {meta['format']} "
                f"({meta['vocab_size']} chars, {meta['target_fps']:g} fps, "
                f"roi={meta['roi']}, {meta['color_order']}, "
                f"blank offset={meta['blank_logit_offset']})"
            )
            print(f"   ⚠️ validation CER={meta['validation_cer']:.1%} "
                  f"on {meta['validation_samples']} samples")
        except Exception as e:
            print(f"❌ Failed to load sentence model from {ctc_dir}: {e}")

    v4_preload()

    if not models:
        print("⚠️ No models loaded! Place .pt files in server/models/")


# ─── Request/Response Models ─────────────────────────────────────────────────

class WordPredictRequest(BaseModel):
    """Request body สำหรับโมเดลทำนายคำ (VocaLip 44 คำ)

    frames: ภาพปาก base64 (PNG/JPEG) เรียงตามเวลา — ส่งมากี่เฟรมก็ได้
            เซิร์ฟเวอร์จะเลือกให้เหลือ 16 เฟรมกระจายเท่าๆ กันเอง
    """
    frames: List[str]
    top_k: Optional[int] = 3
    # เปิด debug เฉพาะ request นี้ โดยไม่ต้องรีสตาร์ท server ด้วย VOCALIP_DEBUG
    debug: Optional[bool] = None
    # เวลาที่ใช้เก็บเฟรมทั้งชุด (มิลลิวินาที) — บอกได้ว่ากล้องเก็บได้กี่เฟรม
    # ต่อวินาที ซึ่งต้องใกล้เคียงกับตอนเทรน ไม่งั้นโมเดลเห็นปากขยับคนละความเร็ว
    capture_ms: Optional[int] = None
    # จำนวนเฟรมที่ client เก็บได้จริง ต่างจาก len(frames) ที่ถูกลดเหลือเท่าที่
    # โมเดลรับแล้ว — ต้องใช้ตัวนี้หารเวลา ไม่งั้นได้อัตราเฟรมที่ต่ำกว่าความจริง
    collected_frames: Optional[int] = None
    # False = ผลระหว่างพูด, True = ผลตอนพูดจบ ใช้แยกแถวใน log ตอนวัดความแม่น
    is_final: Optional[bool] = None
    # "png" (ค่าเดิม) = ไฟล์ภาพ / "rgb" = พิกเซลดิบ RGB เรียงต่อกัน ไม่มีหัวไฟล์
    # แบบ rgb เลี่ยงการเข้ารหัสแล้วถอดกลับเป็นพิกเซลชุดเดิม ซึ่งหนักทั้งสองฝั่ง
    frame_format: Optional[str] = "png"
    # ขนาดด้านของภาพดิบ จำเป็นเฉพาะ frame_format="rgb" เพราะพิกเซลดิบไม่มีหัว
    # ไฟล์บอกขนาดมาด้วย ไม่ส่งมาจะใช้ค่าจาก checkpoint
    roi: Optional[int] = None


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


class SentencePredictRequest(BaseModel):
    """Request body สำหรับโมเดลประโยค (ทดลอง)

    frames: พิกเซลดิบ RGB base64 เรียงตามเวลา ส่งทุกเฟรมที่เก็บได้ ไม่ต้องลด
    capture_ms: จำเป็นมาก — ใช้ยืดเฟรมให้เป็น 25 fps ตามตอนเทรน
    """
    frames: List[str]
    capture_ms: Optional[int] = None
    roi: Optional[int] = None
    frame_format: Optional[str] = "rgb"
    debug: Optional[bool] = None


class SentencePredictResponse(BaseModel):
    text: str
    token_count: int
    # สัดส่วนเฟรมที่โมเดลตอบว่า "ไม่มีตัวอักษร" สูงมากแปลว่าแทบไม่ได้อะไรเลย
    blank_rate: float
    num_frames_received: int
    # จำนวนเฟรมหลังยืดให้เป็น target_fps แล้ว (คือความยาวที่โมเดลเห็นจริง)
    num_frames_used: int
    capture_fps: Optional[float] = None
    target_fps: float
    processing_time_ms: float
    # โมเดลนี้ไม่มีค่าความมั่นใจต่อผลลัพธ์ ต่างจากโมเดลคำ จึงกรองผลมั่วไม่ได้
    experimental: bool = True
    validation_cer: Optional[float] = None
    debug: Optional[dict] = None


# ─── API Endpoints ────────────────────────────────────────────────────────────

@app.get("/")
async def root():
    return {
        "service": "LipsLink API",
        "status": "running",
        "models_loaded": list(models.keys()),
    }


def _model_summary(info: dict) -> dict:
    """สรุปข้อมูลโมเดล — โมเดลคำกับโมเดลประโยคเก็บ metadata คนละคีย์กัน"""
    if info["type"] == "sentence_ctc":
        meta = info["meta"]
        return {
            "type": info["type"],
            "format": meta["format"],
            "experimental": True,
            "target_fps": meta["target_fps"],
            "roi": meta["roi"],
            "mouth_scale": meta["mouth_scale"],
            "color_order": meta["color_order"],
            "vocab_size": meta["vocab_size"],
            "validation_cer": meta["validation_cer"],
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


def _decode_raw_rgb_frame(b64_string: str, src_roi: int, roi: int,
                          to_bgr: bool = True) -> np.ndarray:
    """พิกเซลดิบ RGB -> ภาพ BGR ขนาด roi x roi (uint8, HWC)

    client ส่ง RGB มาเพราะเป็นลำดับที่มันคำนวณออกมาตรงๆ จาก YUV ส่วนโมเดล
    ต้องการ BGR (เหมือนที่ cv2.imdecode คืนมาตอนใช้ PNG) จึงกลับช่องที่นี่
    ให้ได้ผลเหมือนกันทุกประการกับทางเดิม

    to_bgr=False สำหรับโมเดลประโยค ซึ่งเทรนด้วย RGB — คนละแบบกับโมเดลคำ
    """
    raw = base64.b64decode(b64_string)
    expected = src_roi * src_roi * 3
    if len(raw) != expected:
        raise HTTPException(
            status_code=400,
            detail=(f"ขนาดพิกเซลดิบไม่ตรง: ได้ {len(raw)} ไบต์ "
                    f"แต่ {src_roi}x{src_roi}x3 ต้องเป็น {expected}"),
        )

    img = np.frombuffer(raw, dtype=np.uint8).reshape(src_roi, src_roi, 3)
    if to_bgr:
        img = img[:, :, ::-1]                   # RGB -> BGR
    if src_roi != roi:
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


PREDICTION_LOG = os.path.join(DEBUG_DIR, "predictions.csv")

_PREDICTION_LOG_HEADER = [
    "time", "is_final", "top1", "conf1", "top2", "conf2", "top3", "conf3",
    "margin", "motion", "accepted", "reject_reasons",
    "frames_received", "collected_frames", "capture_ms", "capture_fps",
]


def _log_prediction(row: dict) -> None:
    """ต่อท้ายผลทำนายทุกครั้งลง csv ไว้วัดความแม่นทีหลัง

    เขียนด้วย utf-8-sig เพื่อให้ Excel เปิดแล้วอ่านภาษาไทยออก ไม่ใช่ตัวขยะ
    ล้มเหลวเงียบๆ ได้ เพราะ log พังไม่ควรทำให้ทำนายไม่ได้
    """
    try:
        os.makedirs(DEBUG_DIR, exist_ok=True)

        # ถ้าไฟล์เดิมมีหัวตารางคนละชุด (เพราะเพิ่มคอลัมน์ทีหลัง) ต้องขึ้นไฟล์ใหม่
        # ไม่งั้นค่าจะเลื่อนช่องทั้งไฟล์แบบเงียบๆ อ่านแล้วได้ตัวเลขผิดโดยไม่รู้ตัว
        is_new = not os.path.exists(PREDICTION_LOG)
        if not is_new:
            with open(PREDICTION_LOG, "r", encoding="utf-8-sig") as f:
                old_header = (f.readline().strip().split(",")
                              if os.path.getsize(PREDICTION_LOG) else [])
            if old_header != _PREDICTION_LOG_HEADER:
                stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
                os.replace(PREDICTION_LOG,
                           PREDICTION_LOG.replace(".csv", f".{stamp}.csv"))
                is_new = True

        with open(PREDICTION_LOG, "a", newline="", encoding="utf-8-sig") as f:
            writer = csv.DictWriter(f, fieldnames=_PREDICTION_LOG_HEADER)
            if is_new:
                writer.writeheader()
            writer.writerow(row)
    except Exception as e:
        print(f"⚠️ เขียน prediction log ไม่สำเร็จ: {e}", flush=True)


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
        if (request.frame_format or "png").lower() == "rgb":
            src_roi = int(request.roi or roi)
            frames = np.stack(
                [_decode_raw_rgb_frame(b, src_roi, roi) for b in selected])
        else:
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

    def _cand(i: int, field: str):
        return getattr(candidates[i], field) if i < len(candidates) else ""

    collected = request.collected_frames or len(request.frames)
    fps = (round(collected / (request.capture_ms / 1000.0), 1)
           if request.capture_ms else "")
    _log_prediction({
        "time": datetime.now().strftime("%H:%M:%S"),
        "is_final": request.is_final if request.is_final is not None else "",
        "top1": _cand(0, "word"), "conf1": _cand(0, "confidence"),
        "top2": _cand(1, "word"), "conf2": _cand(1, "confidence"),
        "top3": _cand(2, "word"), "conf3": _cand(2, "confidence"),
        "margin": round(margin, 4),
        "motion": round(motion, 6),
        "accepted": not reasons,
        "reject_reasons": "|".join(reasons),
        "frames_received": len(request.frames),
        "collected_frames": collected,
        "capture_ms": request.capture_ms if request.capture_ms else "",
        "capture_fps": fps,
    })

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


@app.post("/predict_sentence", response_model=SentencePredictResponse)
async def predict_sentence(request: SentencePredictRequest):
    """อ่านปากเป็นข้อความอิสระ (CTC ระดับตัวอักษร) — โหมดทดลอง

    ⚠️ ทดสอบแล้วว่าผลแทบไม่ขึ้นกับการขยับปาก (ภาพนิ่งซ้ำได้ผลใกล้เคียงคลิปจริง)
    เปิดไว้ให้ลองต่อระบบเท่านั้น อย่าใช้ผลนี้ตัดสินอะไร
    """
    start_time = time.time()

    entry = models.get("vocalip_sentence")
    if entry is None:
        raise HTTPException(
            status_code=503,
            detail="โมเดลประโยคยังไม่ถูกโหลด ตรวจสอบ server/models/vocalip_th_ctc/",
        )
    if not request.frames:
        raise HTTPException(status_code=400, detail="ไม่มี frames ส่งมา")
    if (request.frame_format or "rgb").lower() != "rgb":
        raise HTTPException(status_code=400,
                            detail="โมเดลประโยครับเฉพาะ frame_format='rgb'")

    meta = entry["meta"]
    roi = meta["roi"]
    src_roi = int(request.roi or roi)

    try:
        frames = np.stack([
            _decode_raw_rgb_frame(b, src_roi, roi, to_bgr=False)
            for b in request.frames
        ])
        timeline = resample_to_fps(frames, request.capture_ms, meta["target_fps"])
        text, tokens, blank_rate = predict_text(
            entry["encoder"], entry["ctc"], entry["id_to_char"], meta, timeline)
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Prediction error: {str(e)}")

    capture_fps = (round(len(frames) / (request.capture_ms / 1000.0), 1)
                   if request.capture_ms else None)

    debug = DEBUG_DEFAULT if request.debug is None else bool(request.debug)
    dbg = None
    if debug:
        os.makedirs(DEBUG_DIR, exist_ok=True)
        pick = frames[np.linspace(0, len(frames) - 1, min(len(frames), 24)).astype(int)]
        strip_path = os.path.join(DEBUG_DIR, "sentence_frames_strip.png")
        cv2.imwrite(strip_path, np.concatenate(list(pick), axis=1)[:, :, ::-1])
        dbg = {"strip": strip_path, "token_ids": tokens}

    elapsed = (time.time() - start_time) * 1000
    print(f"📝 sentence: '{text}' | blank {blank_rate:.0%} | "
          f"{len(frames)} frames @ {capture_fps} fps -> {len(timeline)} "
          f"@ {meta['target_fps']:g} fps | {elapsed:.0f}ms", flush=True)

    return SentencePredictResponse(
        text=text,
        token_count=len(tokens),
        blank_rate=round(blank_rate, 4),
        num_frames_received=len(frames),
        num_frames_used=len(timeline),
        capture_fps=capture_fps,
        target_fps=meta["target_fps"],
        processing_time_ms=round(elapsed, 2),
        validation_cer=meta["validation_cer"],
        debug=dbg,
    )


@app.get("/word_model_info")
async def word_model_info():
    """ข้อมูลโมเดลทำนายคำ รวมรายการคำทั้งหมดและผลวัดที่ผู้เทรนบันทึกมา"""
    entry = models.get("vocalip_word")
    if entry is None:
        raise HTTPException(status_code=503, detail="โมเดลทำนายคำยังไม่ถูกโหลด")

    meta = entry["meta"]
    pre = dict(meta.get("preprocessing", {}))
    # ให้ค่าที่ตั้งผ่าน env ทับค่าใน checkpoint เพื่อให้ทดลองได้โดยไม่ต้องแก้ไฟล์
    # โมเดล ถ้าวันหนึ่งผู้เทรนใส่ mouth_scale มาใน checkpoint ค่านั้นจะถูกใช้เอง
    if MOUTH_SCALE_OVERRIDE is not None:
        pre["mouth_scale"] = MOUTH_SCALE_OVERRIDE

    # เดิมส่งค่า rejection ดิบจาก checkpoint ตรงๆ ทำให้ตัวเลขที่แสดงตรงนี้กับ
    # ค่าที่ /predict_word ใช้จริงไม่ตรงกันเวลาตั้ง VOCALIP_MIN_CONFIDENCE ทับไว้
    # (ตัวเลขจริงถูกอยู่แล้ว แค่ endpoint นี้โชว์ผิด) เอาค่าที่ใช้จริงมาแทนที่
    rejection = dict(meta.get("rejection", {}))
    if MIN_WORD_CONFIDENCE_ENV is not None:
        rejection["confidence_threshold_start"] = MIN_WORD_CONFIDENCE_ENV
        rejection["confidence_threshold_source"] = "VOCALIP_MIN_CONFIDENCE (env)"
    else:
        rejection["confidence_threshold_source"] = "checkpoint"

    return {
        "format": meta["format"],
        "config": meta.get("config", {}),
        "preprocessing": pre,
        "frames": _want_frames(meta),
        "roi": _roi_size(meta),
        # รุ่น 05 ระบุ cache_channel_order มาตรงๆ ส่วนรุ่น 03 เขียนไว้กำกวมว่า
        # "cached order; no channel swap" จึงเติมค่าที่ยืนยันกับผู้เทรนแล้วให้
        "channel_order_resolved": pre.get("cache_channel_order", "BGR"),
        "rejection": rejection,
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
