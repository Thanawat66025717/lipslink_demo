"""
============================================================================
 LipNet Training Pipeline — Step 1: Video Preprocessing
============================================================================
 Pipeline:
   Video (MP4) -> Frames -> MediaPipe FaceLandmarker -> Lip Crop -> Resize
   -> Grayscale -> Normalize (0-1) -> Save as .npy
============================================================================
"""

import os
import sys

# Fix Windows cp874 encoding
if sys.platform == 'win32':
    os.environ['PYTHONIOENCODING'] = 'utf-8'
    try:
        sys.stdout.reconfigure(encoding='utf-8')
        sys.stderr.reconfigure(encoding='utf-8')
    except Exception:
        pass

import argparse
import cv2
import numpy as np
import mediapipe as mp
from mediapipe.tasks import python as mp_python
from mediapipe.tasks.python import vision
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt


# ─── MediaPipe Face Mesh lip landmark indices (478 landmarks) ────────────────
# These indices correspond to the lip region in MediaPipe's 478 face landmarks
UPPER_LIP = [61, 185, 40, 39, 37, 0, 267, 269, 270, 409, 291]
LOWER_LIP = [61, 146, 91, 181, 84, 17, 314, 405, 321, 375, 291]
UPPER_INNER = [78, 191, 80, 81, 82, 13, 312, 311, 310, 415, 308]
LOWER_INNER = [78, 95, 88, 178, 87, 14, 317, 402, 318, 324, 308]
ALL_LIP_INDICES = list(set(UPPER_LIP + LOWER_LIP + UPPER_INNER + LOWER_INNER))

# Target crop size
LIP_WIDTH = 100
LIP_HEIGHT = 50

# Path to the face landmarker model
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
MODEL_PATH = os.path.join(SCRIPT_DIR, 'face_landmarker.task')


def extract_lip_frames(video_path: str, max_frames: int = 75) -> np.ndarray:
    """
    Read video -> crop lip region from every frame -> return numpy array

    Args:
        video_path: path to video file
        max_frames: max number of frames (pad/truncate if needed)

    Returns:
        np.ndarray shape (max_frames, LIP_HEIGHT, LIP_WIDTH, 1)
    """
    if not os.path.exists(video_path):
        print(f"[ERROR] Video not found: {video_path}")
        sys.exit(1)

    cap = cv2.VideoCapture(video_path)
    if not cap.isOpened():
        print(f"[ERROR] Cannot open video: {video_path}")
        sys.exit(1)

    fps = cap.get(cv2.CAP_PROP_FPS)
    total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    if total_frames < 0:
        # Some codecs report negative; count manually
        total_frames = 0
        while cap.read()[0]:
            total_frames += 1
        cap.set(cv2.CAP_PROP_POS_FRAMES, 0)

    print(f"[VIDEO] File: {video_path}")
    print(f"        FPS: {fps:.1f}, Total frames: {total_frames}")

    # ─── MediaPipe FaceLandmarker (new Tasks API) ─────────────────────────
    if not os.path.exists(MODEL_PATH):
        print(f"[ERROR] Face landmarker model not found: {MODEL_PATH}")
        print("  Download from: https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/latest/face_landmarker.task")
        sys.exit(1)

    base_options = mp_python.BaseOptions(model_asset_path=MODEL_PATH)
    options = vision.FaceLandmarkerOptions(
        base_options=base_options,
        num_faces=1,
        min_face_detection_confidence=0.3,
        min_face_presence_confidence=0.3,
        min_tracking_confidence=0.3,
    )

    landmarker = vision.FaceLandmarker.create_from_options(options)

    lip_frames = []
    frame_idx = 0
    no_face_count = 0

    while True:
        ret, frame = cap.read()
        if not ret:
            break

        # Convert BGR -> RGB
        rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)

        # Create MediaPipe Image
        mp_image = mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb)

        # Detect face landmarks
        result = landmarker.detect(mp_image)

        if result.face_landmarks and len(result.face_landmarks) > 0:
            landmarks = result.face_landmarks[0]
            h, w, _ = frame.shape

            # Get lip landmark coordinates
            lip_points = []
            for idx in ALL_LIP_INDICES:
                if idx < len(landmarks):
                    lm = landmarks[idx]
                    x = int(lm.x * w)
                    y = int(lm.y * h)
                    lip_points.append((x, y))

            if len(lip_points) > 0:
                lip_points = np.array(lip_points)

                # Calculate bounding box with padding
                x_min, y_min = lip_points.min(axis=0)
                x_max, y_max = lip_points.max(axis=0)

                # Add 50% padding
                pad_x = int((x_max - x_min) * 0.5)
                pad_y = int((y_max - y_min) * 0.5)

                x_min = max(0, x_min - pad_x)
                y_min = max(0, y_min - pad_y)
                x_max = min(w, x_max + pad_x)
                y_max = min(h, y_max + pad_y)

                # Crop lip region
                lip_crop = frame[y_min:y_max, x_min:x_max]

                if lip_crop.size > 0:
                    # Convert to grayscale
                    lip_gray = cv2.cvtColor(lip_crop, cv2.COLOR_BGR2GRAY)
                    # Resize to standard size
                    lip_resized = cv2.resize(lip_gray, (LIP_WIDTH, LIP_HEIGHT))
                    # Normalize to 0-1
                    lip_norm = lip_resized.astype(np.float32) / 255.0
                    lip_frames.append(lip_norm)
                else:
                    no_face_count += 1
            else:
                no_face_count += 1
        else:
            no_face_count += 1

        frame_idx += 1

    cap.release()
    landmarker.close()

    print(f"[OK] Extracted {len(lip_frames)} lip frames from {frame_idx} total frames")
    if no_face_count > 0:
        print(f"     ({no_face_count} frames had no face detected)")

    if len(lip_frames) == 0:
        print("[ERROR] No face detected in any frame! Please check video.")
        sys.exit(1)

    # ─── Pad or truncate to max_frames ────────────────────────────────────
    frames = np.array(lip_frames)

    if len(frames) > max_frames:
        # Uniformly sample frames
        indices = np.linspace(0, len(frames) - 1, max_frames, dtype=int)
        frames = frames[indices]
        print(f"     Truncated to {max_frames} frames (uniform sampling)")
    elif len(frames) < max_frames:
        # Pad with zeros (black frames)
        pad_count = max_frames - len(frames)
        pad = np.zeros((pad_count, LIP_HEIGHT, LIP_WIDTH), dtype=np.float32)
        frames = np.concatenate([frames, pad], axis=0)
        print(f"     Padded to {max_frames} frames (+{pad_count} black frames)")

    # Add channel dimension -> (T, H, W, 1)
    frames = frames[..., np.newaxis]

    return frames


def save_preview(frames: np.ndarray, output_path: str, num_samples: int = 10):
    """Save preview of lip frames as image"""
    total = frames.shape[0]
    indices = np.linspace(0, total - 1, min(num_samples, total), dtype=int)

    fig, axes = plt.subplots(2, 5, figsize=(15, 4))
    fig.suptitle('Lip Crop Preview (Preprocessed Frames)', fontsize=14, fontweight='bold')

    for i, ax in enumerate(axes.flat):
        if i < len(indices):
            ax.imshow(frames[indices[i], :, :, 0], cmap='gray', vmin=0, vmax=1)
            ax.set_title(f'Frame {indices[i]}', fontsize=9)
        ax.axis('off')

    plt.tight_layout()
    plt.savefig(output_path, dpi=150, bbox_inches='tight')
    plt.close()
    print(f"[OK] Preview saved: {output_path}")


def main():
    parser = argparse.ArgumentParser(description='LipNet Preprocessing')
    parser.add_argument('--video', type=str, required=True, help='Path to video file')
    parser.add_argument('--label', type=str, required=True, help='Text spoken in video')
    parser.add_argument('--max-frames', type=int, default=75, help='Max frames (default: 75)')
    parser.add_argument('--output-dir', type=str, default='data/processed', help='Output directory')

    args = parser.parse_args()

    print("=" * 60)
    print("  LipNet Preprocessing Pipeline")
    print("=" * 60)
    print(f"  Video: {args.video}")
    print(f"  Label: \"{args.label}\"")
    print(f"  Max Frames: {args.max_frames}")
    print("=" * 60)

    # Ensure output directories exist
    os.makedirs(args.output_dir, exist_ok=True)
    os.makedirs('outputs', exist_ok=True)

    # ─── Step 1: Extract lip frames ───────────────────────────────────────
    print("\n[STEP 1] Extracting lip frames...")
    frames = extract_lip_frames(args.video, max_frames=args.max_frames)
    print(f"         Final shape: {frames.shape}")

    # ─── Step 2: Save .npy ────────────────────────────────────────────────
    npy_path = os.path.join(args.output_dir, 'lips.npy')
    np.save(npy_path, frames)
    print(f"\n[STEP 2] Saved lip data -> {npy_path}")
    print(f"         Size: {os.path.getsize(npy_path) / 1024:.1f} KB")

    # ─── Step 3: Save label ───────────────────────────────────────────────
    label_path = os.path.join(args.output_dir, 'label.txt')
    with open(label_path, 'w', encoding='utf-8') as f:
        f.write(args.label)
    print(f"         Label saved -> {label_path}")

    # ─── Step 4: Save preview ─────────────────────────────────────────────
    preview_path = os.path.join('outputs', 'lip_preview.png')
    print(f"\n[STEP 3] Generating preview...")
    save_preview(frames, preview_path)

    print("\n" + "=" * 60)
    print("  [DONE] Preprocessing complete!")
    print(f"  Lip frames: {npy_path}")
    print(f"  Label:      {label_path}")
    print(f"  Preview:    {preview_path}")
    print("=" * 60)
    print("\n  Next: python train.py --epochs 200")


if __name__ == '__main__':
    main()
