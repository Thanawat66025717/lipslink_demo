"""
ทดสอบ endpoint /v4 ของ LipsLink server ด้วยไฟล์วิดีโอ — จำลองสิ่งที่แอปทำทุกขั้น:
  ครอปใบหน้า (สี่เหลี่ยมจัตุรัส ×1.4) → ย่อ 192×192 → JPEG q80 → ส่งพร้อมเวลาของแต่ละเฟรม

ตัวอย่าง:
  # 1) เช็กว่า server โหลดโมเดลได้
  python test_v4_api.py --url http://localhost:8000 --info

  # 2) ทดสอบเต็มขั้น: ปรับเทียบจากวิดีโอ 20 วินาที แล้วทายคำในช่วง 3.2–4.0 วินาทีของอีกคลิป
  python test_v4_api.py --url http://localhost:8000 --calib-video me_talking.mp4 --video me_word.mp4 --start 3.2 --end 4.0

  # 3) ทดสอบกับ Cloud Run
  python test_v4_api.py --url https://lipslink-api-xxxx.a.run.app --video me_word.mp4

อัดคลิปทดสอบเองได้ด้วยกล้องหน้ามือถือ: ถือระยะเซลฟี่ หน้าตรง แล้วพูดคำที่อยู่ในรายการคำ (ดูจาก --info)
ต้องติดตั้ง: pip install requests opencv-python-headless mediapipe numpy
"""
import argparse
import base64
import json
import os
import time

import cv2
import numpy as np
import requests

HERE = os.path.dirname(os.path.abspath(__file__))
TASK = os.path.join(HERE, "models", "vocalip_v4", "face_landmarker.task")


def face_crops(video, start, end, fps_out, size=192, box_scale=1.4, quality=80):
    """อ่านวิดีโอ → ภาพใบหน้า JPEG (base64) + เวลา (ms) ที่ fps_out
    ในแอปจริงใช้กรอบหน้าจาก ML Kit แทน MediaPipe ตรงนี้ — ผลเหมือนกัน แค่ต้องได้กรอบหน้า"""
    import mediapipe as mp
    from mediapipe.tasks.python import BaseOptions, vision
    det = vision.FaceLandmarker.create_from_options(vision.FaceLandmarkerOptions(
        base_options=BaseOptions(model_asset_path=TASK), running_mode=vision.RunningMode.IMAGE, num_faces=1))
    cap = cv2.VideoCapture(video)
    half = 0.5 / max(cap.get(cv2.CAP_PROP_FPS) or 30.0, 1.0)   # เผื่อครึ่งเฟรม ไม่งั้นวิดีโอ 30 fps จะถูกเลือกได้แค่ 15 fps
    if start:
        cap.set(cv2.CAP_PROP_POS_MSEC, start * 1000)
    frames, ts, box, next_t = [], [], None, None
    while True:
        ok, bgr = cap.read()
        t = cap.get(cv2.CAP_PROP_POS_MSEC) / 1000
        if not ok or (end and t > end):
            break
        if t < (start or 0) or (next_t is not None and t < next_t - half):
            continue
        next_t = t + 1.0 / fps_out
        H, W = bgr.shape[:2]
        if box is None or len(frames) % 5 == 0:                 # หากรอบหน้าใหม่ทุก 5 เฟรม (เหมือนแอปที่ไม่รัน ML Kit ทุกเฟรม)
            r = det.detect(mp.Image(image_format=mp.ImageFormat.SRGB, data=cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)))
            if r.face_landmarks:
                p = np.array([[q.x * W, q.y * H] for q in r.face_landmarks[0]])
                cx, cy = (p.min(0) + p.max(0)) / 2
                side = (p.max(0) - p.min(0)).max() * box_scale
                box = (cx, cy, side)
        if box is None:
            continue
        if size == 0:                                          # ไม่ครอป: ส่งทั้งภาพ (ใช้เทียบผลเท่านั้น)
            ok, jpg = cv2.imencode(".jpg", bgr, [cv2.IMWRITE_JPEG_QUALITY, quality])
            frames.append(base64.b64encode(jpg.tobytes()).decode())
            ts.append(round((t - (start or 0)) * 1000, 1))
            continue
        cx, cy, side = box
        x0, y0 = int(cx - side / 2), int(cy - side / 2)
        x1, y1 = x0 + int(side), y0 + int(side)
        pad = max(0, -x0, -y0, x1 - W, y1 - H)                 # ขอบเกินภาพ → เติมดำ
        if pad:
            bgr = cv2.copyMakeBorder(bgr, pad, pad, pad, pad, cv2.BORDER_CONSTANT)
            x0, y0, x1, y1 = x0 + pad, y0 + pad, x1 + pad, y1 + pad
        crop = cv2.resize(bgr[y0:y1, x0:x1], (size, size), interpolation=cv2.INTER_AREA)
        ok, jpg = cv2.imencode(".jpg", crop, [cv2.IMWRITE_JPEG_QUALITY, quality])
        frames.append(base64.b64encode(jpg.tobytes()).decode())
        ts.append(round((t - (start or 0)) * 1000, 1))
    if not frames:
        raise SystemExit(f"ไม่เจอใบหน้าใน {video}")
    return frames, ts


def post(url, path, body):
    t0 = time.time()
    r = requests.post(url.rstrip("/") + path, json=body, timeout=120)
    ms = (time.time() - t0) * 1000
    kb = len(json.dumps(body)) / 1024
    if r.status_code != 200:
        raise SystemExit(f"{path} → HTTP {r.status_code}: {r.content.decode('utf-8', 'replace')}")
    return json.loads(r.content.decode("utf-8")), ms, kb


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="http://localhost:8000")
    ap.add_argument("--info", action="store_true")
    ap.add_argument("--video")
    ap.add_argument("--start", type=float, default=0.0)
    ap.add_argument("--end", type=float)
    ap.add_argument("--calib-video", help="วิดีโอผู้พูดคนเดียวกัน ~20 วินาที (ไม่ใส่ = ใช้ค่ากลาง)")
    ap.add_argument("--calib-start", type=float, default=0.0)
    ap.add_argument("--fps", type=float, default=25.0, help="อัตราเฟรมที่ส่ง (จำลองมือถือ เช่น 15)")
    a = ap.parse_args()

    if a.info or not a.video:
        info = requests.get(a.url.rstrip("/") + "/v4/model_info", timeout=60)
        info.raise_for_status()
        d = json.loads(info.content.decode("utf-8"))
        print(f"model {d['version']} ({d['model_file']}) | {d['n_classes']} คำ | "
              f"คลิปยาว {d['min_seconds']:.2f}–{d['max_seconds']:.2f} วินาที")
        print("คำ:", ", ".join(d["words"]))
        if not a.video:
            raise SystemExit(0)

    stats = {}
    if a.calib_video:
        fr, ts = face_crops(a.calib_video, a.calib_start, a.calib_start + 20, fps_out=5)
        c, ms, kb = post(a.url, "/v4/calibrate", {"frames": fr, "timestamps_ms": ts, "frame_format": "jpeg"})
        print(f"calibrate: {c['frames_with_face']}/{c['frames_received']} ภาพเจอหน้า, {c['seconds']} วินาที "
              f"| ส่ง {kb:.0f} KB, {ms:.0f} ms" + (f" | ⚠️ {c['warning']}" if c.get("warning") else ""))
        stats = {"feat_mean": c["feat_mean"], "feat_std": c["feat_std"]}

    fr, ts = face_crops(a.video, a.start, a.end, fps_out=a.fps)
    p, ms, kb = post(a.url, "/v4/predict_word",
                     {"frames": fr, "timestamps_ms": ts, "frame_format": "jpeg", "top_k": 5, **stats})
    print(f"predict: {len(fr)} ภาพ ({p['capture_fps']} fps) → {p['num_frames_used']} เฟรมที่ 25 fps "
          f"| ส่ง {kb:.0f} KB | server {p['processing_time_ms']:.0f} ms, รวมเน็ต {ms:.0f} ms "
          f"| calibrated={p['calibrated']} face_ratio={p['face_ratio']}")
    for i, c in enumerate(p["top_k"], 1):
        print(f"  {i}. {c['word']}\t{c['confidence']:.3f}")
    print("low_confidence:", p["low_confidence"], p["reject_reasons"] or "")
