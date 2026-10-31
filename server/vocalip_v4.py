"""
VocaLip Thai v4 — endpoint ชุดใหม่สำหรับ LipsLink server (/v4/...)

ต่างจากโมเดลเดิม: โมเดล v4 อ่านจาก "จุดบนใบหน้า 478 จุด + blendshapes" ของ MediaPipe ไม่ใช่ภาพปาก
แอปจึงส่ง "ภาพทั้งใบหน้า" (ครอปจากกรอบหน้าของ ML Kit) มา แล้ว server รัน MediaPipe เอง
จากนั้นส่งเข้าโมเดล ONNX ซึ่งมีขั้นเตรียมข้อมูล (จัดแนวหน้า, หารระยะหางตา, ปรับเทียบผู้ใช้) อยู่ในไฟล์แล้ว

ติดตั้งใน app.py แค่ 2 บรรทัด:
    from vocalip_v4 import router as v4_router
    app.include_router(v4_router)

ไฟล์โมเดลอยู่ที่ server/models/vocalip_v4/ — เปลี่ยนรุ่นโมเดลได้ด้วยการแทนไฟล์ในโฟลเดอร์นั้นอย่างเดียว
(model.onnx / model.int8.onnx, calibrate.onnx, vocab.json, config.json, face_landmarker.task)

ตัวแปรสภาพแวดล้อม (ไม่ตั้งก็ได้):
    VOCALIP_V4_DIR            โฟลเดอร์โมเดล (ค่าเริ่มต้น server/models/vocalip_v4)
    VOCALIP_V4_MODEL          ชื่อไฟล์โมเดล (ค่าเริ่มต้น model.int8.onnx ถ้ามี ไม่งั้น model.onnx)
    VOCALIP_V4_MIN_CONFIDENCE เกณฑ์ low_confidence ของคำอันดับ 1 (ค่าเริ่มต้น 0.10 — มี 200 คลาส ค่าจึงต่ำกว่าโมเดลเดิม)
    VOCALIP_V4_MIN_MOTION     เกณฑ์การขยับปากขั้นต่ำ (ค่าเริ่มต้น 0.02 = ส่วนเบี่ยงเบนของการอ้าปาก / ระยะหางตา)

ความเป็นส่วนตัว: โมดูลนี้ไม่บันทึกภาพหรือ landmark ลงดิสก์เลย (ภาพใบหน้าผู้ป่วยเป็นข้อมูลส่วนบุคคล)
"""

import base64
import json
import os
import threading
import time
from typing import List, Optional

import cv2
import numpy as np
import onnxruntime as ort
from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

HERE = os.path.dirname(os.path.abspath(__file__))
MODEL_DIR = os.getenv("VOCALIP_V4_DIR", os.path.join(HERE, "models", "vocalip_v4"))
MIN_CONFIDENCE = float(os.getenv("VOCALIP_V4_MIN_CONFIDENCE", "0.10"))
MIN_MOTION = float(os.getenv("VOCALIP_V4_MIN_MOTION", "0.02"))

# ดัชนีจุดของ MediaPipe Face Mesh (ต้องตรงกับตอนเทรน) — ใช้แค่วัดการขยับปากเพื่อกันผลมั่ว
EYE_R_OUTER, EYE_L_OUTER, LIP_TOP_IN, LIP_BOT_IN = 33, 263, 13, 14

router = APIRouter(prefix="/v4", tags=["VocaLip v4"])


# ─── โหลดโมเดล ──────────────────────────────────────────────────────────────────

class _Engine:
    def __init__(self, model_dir: str):
        self.dir = model_dir
        self.cfg = json.load(open(os.path.join(model_dir, "config.json"), encoding="utf-8"))
        self.vocab = [v["word"] for v in json.load(open(os.path.join(model_dir, "vocab.json"), encoding="utf-8"))]
        name = os.getenv("VOCALIP_V4_MODEL") or (
            "model.int8.onnx" if os.path.exists(os.path.join(model_dir, "model.int8.onnx")) else "model.onnx")
        self.model_file = name
        opts = ort.SessionOptions()
        opts.intra_op_num_threads = 2            # Cloud Run --cpu 2
        self.model = ort.InferenceSession(os.path.join(model_dir, name), opts, providers=["CPUExecutionProvider"])
        self.calib = ort.InferenceSession(os.path.join(model_dir, "calibrate.onnx"), opts,
                                          providers=["CPUExecutionProvider"])
        self.task = os.path.join(model_dir, "face_landmarker.task")
        self.default_mean = np.array(self.cfg["default_feat_mean"], np.float32)
        self.default_std = np.array(self.cfg["default_feat_std"], np.float32)
        self.fps = float(self.cfg["fps"])
        self.min_frames = int(self.cfg["min_frames"])
        self.max_frames = int(self.cfg["max_frames"])

    def new_landmarker(self):
        """สร้าง landmarker ใหม่ทุก request — VIDEO mode ต้องการเวลาเพิ่มขึ้นเรื่อยๆ ต่อหนึ่งตัว
        จึงแชร์ข้าม request ไม่ได้ (request พร้อมกันจะเวลาตีกัน) ใช้เวลาสร้างประมาณ 50–100 ms"""
        from mediapipe.tasks.python import BaseOptions, vision
        return vision.FaceLandmarker.create_from_options(vision.FaceLandmarkerOptions(
            base_options=BaseOptions(model_asset_path=self.task),
            running_mode=vision.RunningMode.VIDEO, num_faces=1, output_face_blendshapes=True))


_engine: Optional[_Engine] = None
_engine_lock = threading.Lock()


def get_engine() -> _Engine:
    global _engine
    if _engine is None:
        with _engine_lock:
            if _engine is None:
                if not os.path.exists(os.path.join(MODEL_DIR, "config.json")):
                    raise HTTPException(503, f"ไม่พบโมเดล v4 ที่ {MODEL_DIR}")
                _engine = _Engine(MODEL_DIR)
                print(f"✅ VocaLip v4 loaded: {_engine.cfg['version']} ({_engine.model_file}, "
                      f"{len(_engine.vocab)} classes)", flush=True)
    return _engine


def preload():
    """เรียกตอน startup เพื่อให้ request แรกไม่ช้า (ไม่บังคับ)"""
    try:
        get_engine()
    except Exception as e:                                  # server ยังให้บริการโมเดลเดิมต่อได้
        print(f"⚠️ VocaLip v4 not loaded: {e}", flush=True)


# ─── ภาพ → landmarks ───────────────────────────────────────────────────────────

def _decode(b64: str, fmt: str, roi: Optional[int]) -> np.ndarray:
    """base64 → ภาพ RGB uint8 (MediaPipe ต้องการ RGB)"""
    raw = base64.b64decode(b64)
    if fmt == "rgb":
        if not roi or len(raw) != roi * roi * 3:
            raise HTTPException(400, f"frame_format=rgb ต้องส่ง roi และขนาดต้องเป็น roi*roi*3 (ได้ {len(raw)} ไบต์)")
        return np.frombuffer(raw, np.uint8).reshape(roi, roi, 3).copy()
    img = cv2.imdecode(np.frombuffer(raw, np.uint8), cv2.IMREAD_COLOR)
    if img is None:
        raise HTTPException(400, "ถอดรหัสภาพไม่ได้ (รองรับ jpeg / png / rgb)")
    return cv2.cvtColor(img, cv2.COLOR_BGR2RGB)


def _timestamps(n: int, ts: Optional[List[float]], capture_ms: Optional[int], fps: float) -> np.ndarray:
    """เวลาของแต่ละเฟรม (วินาที) — ใช้ timestamps_ms ถ้ามี ไม่งั้นกระจายเท่าๆ กันตาม capture_ms"""
    if ts is not None:
        if len(ts) != n:
            raise HTTPException(400, f"timestamps_ms มี {len(ts)} ค่า แต่ frames มี {n} ภาพ")
        t = np.asarray(ts, np.float64) / 1000.0
        if np.any(np.diff(t) <= 0):
            raise HTTPException(400, "timestamps_ms ต้องเพิ่มขึ้นเรื่อยๆ")
        return t - t[0]
    step = (capture_ms / 1000.0 / max(n - 1, 1)) if capture_ms else 1.0 / fps
    return np.arange(n) * step


def _landmarks(eng: _Engine, frames: List[str], fmt: str, roi: Optional[int], t: np.ndarray):
    """รัน MediaPipe ทุกเฟรม → (เวลา, landmarks [N,478,2], blendshapes [N,52], ขนาดภาพ) เฉพาะเฟรมที่เจอหน้า"""
    import mediapipe as mp
    keep_t, lms, bss, size = [], [], [], None
    with eng.new_landmarker() as det:
        for b64, ti in zip(frames, t):
            img = _decode(b64, fmt, roi)
            size = (img.shape[1], img.shape[0])
            r = det.detect_for_video(mp.Image(image_format=mp.ImageFormat.SRGB, data=img), int(round(ti * 1000)))
            if r.face_landmarks:
                keep_t.append(ti)
                lms.append([[p.x, p.y] for p in r.face_landmarks[0]])
                bss.append([c.score for c in r.face_blendshapes[0]])
    if not keep_t:
        return np.zeros(0), np.zeros((0, 478, 2), np.float32), np.zeros((0, 52), np.float32), size
    return np.array(keep_t), np.array(lms, np.float32), np.array(bss, np.float32), size


def _resample(t, lm, bs, fps):
    """ยืด/หดให้เป็น fps ของตอนเทรน (25) ด้วยการประมาณค่าเชิงเส้นตามเวลาจริง"""
    grid = np.arange(t[0], t[-1] + 1e-6, 1.0 / fps)
    j = np.clip(np.searchsorted(t, grid), 1, len(t) - 1)
    w = np.clip((grid - t[j - 1]) / np.maximum(t[j] - t[j - 1], 1e-6), 0, 1).astype(np.float32)
    lm2 = lm[j - 1] * (1 - w)[:, None, None] + lm[j] * w[:, None, None]
    bs2 = bs[j - 1] * (1 - w)[:, None] + bs[j] * w[:, None]
    return lm2.astype(np.float32), bs2.astype(np.float32)


def _mouth_motion(lm: np.ndarray, size) -> float:
    """ส่วนเบี่ยงเบนของระยะอ้าปาก / ระยะหางตา — ปากนิ่งได้ประมาณ 0"""
    p = lm * np.asarray(size, np.float32)
    iod = np.linalg.norm(p[:, EYE_L_OUTER] - p[:, EYE_R_OUTER], axis=1) + 1e-6
    opening = np.linalg.norm(p[:, LIP_BOT_IN] - p[:, LIP_TOP_IN], axis=1) / iod
    return float(opening.std())


def _user_stats(eng: _Engine, mean, std):
    if mean is None or std is None:
        return eng.default_mean, eng.default_std, False
    if len(mean) != len(eng.default_mean) or len(std) != len(eng.default_std):
        raise HTTPException(400, f"feat_mean/feat_std ต้องมี {len(eng.default_mean)} ค่า (ปรับเทียบใหม่หลังเปลี่ยนรุ่นโมเดล)")
    return np.asarray(mean, np.float32), np.maximum(np.asarray(std, np.float32), 1e-4), True


# ─── Request / Response ────────────────────────────────────────────────────────

class V4Frames(BaseModel):
    frames: List[str]                       # ภาพทั้งใบหน้า base64 เรียงตามเวลา
    timestamps_ms: Optional[List[float]] = None   # เวลาของแต่ละเฟรม (แนะนำให้ส่ง)
    capture_ms: Optional[int] = None        # ใช้แทน timestamps_ms ได้ถ้าเฟรมห่างเท่าๆ กัน
    frame_format: Optional[str] = "jpeg"    # "jpeg" | "png" | "rgb"
    roi: Optional[int] = None               # ด้านของภาพ (จำเป็นเฉพาะ frame_format="rgb")


class V4PredictRequest(V4Frames):
    feat_mean: Optional[List[float]] = None  # จาก /v4/calibrate (ไม่ส่ง = ใช้ค่ากลาง แม่นน้อยลง)
    feat_std: Optional[List[float]] = None
    # (ไม่บังคับ) เฟรมที่เวลาน้อยกว่าค่านี้ใช้แค่ให้ MediaPipe ติดตามหน้า ไม่ส่งเข้าโมเดล
    # ทดสอบแล้ว (300 คลิป) ไม่ได้ช่วยให้แม่นขึ้น — ค่าเริ่มต้น 0 = ใช้ทุกเฟรม
    warmup_ms: Optional[float] = 0
    top_k: Optional[int] = 5
    debug: Optional[bool] = False


class V4Candidate(BaseModel):
    word: str
    confidence: float


class V4PredictResponse(BaseModel):
    # ฟิลด์ชุดเดียวกับ /predict_word เดิม — คลาส WordPrediction ในแอปอ่านได้เลย
    word: str
    confidence: float
    top_k: List[V4Candidate]
    processing_time_ms: float
    num_frames_received: int
    num_frames_used: int
    low_confidence: bool
    min_confidence: float
    min_margin: float = 0.0
    margin: float
    mouth_motion: float
    motion_threshold: Optional[float] = None
    reject_reasons: List[str] = []
    # ฟิลด์ใหม่
    calibrated: bool
    face_ratio: float                       # สัดส่วนเฟรมที่ MediaPipe เจอหน้า
    capture_fps: Optional[float] = None
    model_version: str
    debug: Optional[dict] = None


class V4CalibrateResponse(BaseModel):
    feat_mean: List[float]
    feat_std: List[float]
    frames_received: int
    frames_with_face: int
    seconds: float
    model_version: str                      # เก็บไว้คู่กับค่าปรับเทียบ — ถ้ารุ่นโมเดลเปลี่ยน ควรปรับเทียบใหม่
    warning: Optional[str] = None


# ─── Endpoints (เป็น def ธรรมดา → FastAPI รันใน thread pool ไม่บล็อก request อื่น) ──

@router.get("/model_info")
def model_info():
    eng = get_engine()
    c = eng.cfg
    return {
        "version": c["version"], "model_file": eng.model_file, "n_classes": len(eng.vocab),
        "words": eng.vocab, "fps": eng.fps, "min_frames": eng.min_frames, "max_frames": eng.max_frames,
        "min_seconds": eng.min_frames / eng.fps, "max_seconds": eng.max_frames / eng.fps,
        "calibration_seconds": c.get("calibration_seconds", 20.0),
        "recommended_face_crop": {"size": 192, "box_scale": 1.4, "format": "jpeg", "quality": 80,
                                  "mirror": False, "upright": True},
        "min_confidence": MIN_CONFIDENCE, "min_motion": MIN_MOTION,
        "evaluation": c.get("evaluation", {}),
    }


@router.post("/calibrate", response_model=V4CalibrateResponse)
def calibrate(req: V4Frames):
    eng = get_engine()
    if len(req.frames) < 10:
        raise HTTPException(400, "ต้องการภาพอย่างน้อย 10 ภาพ (แนะนำประมาณ 20 วินาที ที่ 5 fps ≈ 100 ภาพ)")
    t = _timestamps(len(req.frames), req.timestamps_ms, req.capture_ms, 5.0)
    tk, lm, bs, size = _landmarks(eng, req.frames, (req.frame_format or "jpeg").lower(), req.roi, t)
    if len(tk) < 10:
        raise HTTPException(422, f"เจอใบหน้าแค่ {len(tk)} จาก {len(req.frames)} ภาพ — ให้หันหน้าเข้ากล้อง แสงพอ แล้วลองใหม่")
    mean, std = eng.calib.run(None, {"landmarks": lm, "blendshapes": bs, "image_size": np.asarray(size, np.float32)})
    secs = float(t[-1] - t[0])
    warn = None
    if secs < 10:
        warn = f"ปรับเทียบแค่ {secs:.0f} วินาที — แนะนำประมาณ 20 วินาที"
    elif len(tk) < 0.7 * len(req.frames):
        warn = f"เจอหน้าแค่ {len(tk)}/{len(req.frames)} ภาพ — ผลปรับเทียบอาจไม่ดี"
    return V4CalibrateResponse(feat_mean=mean.tolist(), feat_std=std.tolist(), frames_received=len(req.frames),
                               frames_with_face=len(tk), seconds=round(secs, 1), model_version=eng.cfg["version"],
                               warning=warn)


@router.post("/predict_word", response_model=V4PredictResponse)
def predict_word(req: V4PredictRequest):
    t_start = time.time()
    eng = get_engine()
    if not req.frames:
        raise HTTPException(400, "ไม่มี frames ส่งมา")
    t = _timestamps(len(req.frames), req.timestamps_ms, req.capture_ms, eng.fps)
    tk, lm, bs, size = _landmarks(eng, req.frames, (req.frame_format or "jpeg").lower(), req.roi, t)
    warm = float(req.warmup_ms or 0) / 1000.0
    if warm > 0:
        if warm >= t[-1]:
            raise HTTPException(400, "warmup_ms ยาวกว่าคลิปทั้งหมด")
        n_word = int(np.sum(t >= warm))
        keep = tk >= warm
        tk, lm, bs = tk[keep], lm[keep], bs[keep]
        face_ratio = len(tk) / max(n_word, 1)
    else:
        face_ratio = len(tk) / len(req.frames)
    capture_fps = round((len(req.frames) - 1) / t[-1], 1) if t[-1] > 0 else None
    mean, std, calibrated = _user_stats(eng, req.feat_mean, req.feat_std)

    reasons = []
    if len(tk) < 2:
        raise HTTPException(422, "ไม่เจอใบหน้าในภาพ — ต้องเห็นทั้งตาและปาก หน้าตรง แสงพอ")
    lm25, bs25 = _resample(tk, lm, bs, eng.fps)
    if len(lm25) < eng.min_frames:
        reasons.append("too_short")
        pad = eng.min_frames - len(lm25)                    # เติมเฟรมสุดท้ายให้ครบขั้นต่ำ แล้วติดธงไว้
        lm25 = np.concatenate([lm25, np.repeat(lm25[-1:], pad, 0)])
        bs25 = np.concatenate([bs25, np.repeat(bs25[-1:], pad, 0)])
    if len(lm25) > eng.max_frames:                          # ตัดตรงกลาง เหมือนตอนเทรน
        c = (len(lm25) - eng.max_frames) // 2
        lm25, bs25 = lm25[c:c + eng.max_frames], bs25[c:c + eng.max_frames]
    if face_ratio < 0.6:
        reasons.append("face")

    probs = eng.model.run(["probs"], {"landmarks": lm25[None], "blendshapes": bs25[None],
                                      "image_size": np.asarray(size, np.float32),
                                      "feat_mean": mean, "feat_std": std})[0][0]
    k = max(1, min(int(req.top_k or 5), len(eng.vocab)))
    top = np.argsort(-probs)[:k]
    cands = [V4Candidate(word=eng.vocab[i], confidence=round(float(probs[i]), 4)) for i in top]
    margin = float(probs[top[0]] - probs[top[1]]) if k > 1 else float(probs[top[0]])
    motion = _mouth_motion(lm25, size)
    if cands[0].confidence < MIN_CONFIDENCE:
        reasons.append("confidence")
    if motion < MIN_MOTION:
        reasons.append("motion")

    dbg = None
    if req.debug:
        dbg = {"frames_with_face": len(tk), "frames_25fps": int(len(lm25)), "image_size": list(size),
               "timestamps_s": [round(float(x), 3) for x in t]}
    return V4PredictResponse(
        word=cands[0].word, confidence=cands[0].confidence, top_k=cands,
        processing_time_ms=round((time.time() - t_start) * 1000, 1),
        num_frames_received=len(req.frames), num_frames_used=int(len(lm25)),
        low_confidence=bool(reasons), min_confidence=MIN_CONFIDENCE, margin=round(margin, 4),
        mouth_motion=round(motion, 5), motion_threshold=MIN_MOTION, reject_reasons=reasons,
        calibrated=calibrated, face_ratio=round(face_ratio, 3), capture_fps=capture_fps,
        model_version=eng.cfg["version"], debug=dbg)
