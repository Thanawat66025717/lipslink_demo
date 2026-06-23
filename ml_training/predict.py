"""
============================================================================
 LipNet Training Pipeline — Step 4: Inference (Prediction)
============================================================================
 วิธีใช้:
   python predict.py --video data/raw/your_video.mp4

 ทดสอบ predict จากวิดีโอ โดยใช้ model ที่เทรนแล้ว
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
import numpy as np
import cv2
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import tensorflow as tf
from tensorflow import keras

from model import build_lipnet, decode_predictions, ctc_beam_decode, NUM_CHARS
from preprocess import extract_lip_frames, LIP_WIDTH, LIP_HEIGHT


def load_model(model_dir='models', input_shape=(75, 50, 100, 1)):
    """โหลด prediction model"""
    # Try loading full model first
    pred_model_path = os.path.join(model_dir, 'lipnet_prediction.keras')
    if os.path.exists(pred_model_path):
        print(f"📂 Loading model: {pred_model_path}")
        model = keras.models.load_model(pred_model_path, compile=False)
        return model

    # Fallback: rebuild + load weights
    weights_path = os.path.join(model_dir, 'lipnet_final.weights.h5')
    if os.path.exists(weights_path):
        print(f"📂 Loading weights: {weights_path}")
        _, prediction_model = build_lipnet(input_shape=input_shape, num_chars=NUM_CHARS)
        prediction_model.load_weights(weights_path)
        return prediction_model

    print(f"❌ ไม่พบ model ใน {model_dir}/")
    print("   กรุณารัน train.py ก่อน")
    sys.exit(1)


def predict_video(video_path: str, model, max_frames: int = 75):
    """
    Predict ข้อความจากวิดีโอ

    Returns:
        greedy_text: ผลจาก greedy decoding
        beam_text: ผลจาก beam search decoding
        confidence: ค่าเฉลี่ย confidence
        lip_frames: lip frames ที่ตัดมา
    """
    print(f"\n🔄 Preprocessing video: {video_path}")
    lip_frames = extract_lip_frames(video_path, max_frames=max_frames)

    # Add batch dimension
    X = lip_frames[np.newaxis, ...]  # (1, T, H, W, 1)

    # Predict
    print("🔮 Running prediction...")
    y_pred = model.predict(X, verbose=0)  # (1, T, num_chars)

    # Greedy decoding
    greedy_text = decode_predictions(y_pred)[0]

    # Beam search decoding
    try:
        beam_text = ctc_beam_decode(y_pred, beam_width=10)[0]
    except Exception:
        beam_text = greedy_text  # fallback

    # Confidence (average max probability per time step)
    max_probs = np.max(y_pred[0], axis=-1)
    confidence = np.mean(max_probs)

    return greedy_text, beam_text, confidence, lip_frames, y_pred[0]


def save_prediction_report(video_path, greedy_text, beam_text, confidence,
                           lip_frames, y_pred, output_dir='outputs'):
    """สร้าง prediction report"""
    os.makedirs(output_dir, exist_ok=True)

    fig = plt.figure(figsize=(16, 10))
    fig.suptitle('🔮 LipNet Prediction Report', fontsize=16, fontweight='bold')

    # ─── 1. Lip frame samples ────────────────────────────────────────────
    ax_frames = fig.add_subplot(3, 1, 1)
    total = lip_frames.shape[0]
    n_show = min(10, total)
    indices = np.linspace(0, total - 1, n_show, dtype=int)

    montage = np.hstack([lip_frames[i, :, :, 0] for i in indices])
    ax_frames.imshow(montage, cmap='gray', aspect='auto')
    ax_frames.set_title('Lip Frames (sampled)', fontsize=12)
    ax_frames.axis('off')

    # ─── 2. Confidence over time ──────────────────────────────────────────
    ax_conf = fig.add_subplot(3, 1, 2)
    max_probs = np.max(y_pred, axis=-1)
    ax_conf.plot(max_probs, color='#2196F3', linewidth=1.5)
    ax_conf.fill_between(range(len(max_probs)), max_probs, alpha=0.2, color='#2196F3')
    ax_conf.set_xlabel('Time Step')
    ax_conf.set_ylabel('Confidence')
    ax_conf.set_title(f'Prediction Confidence (avg: {confidence:.2%})', fontsize=12)
    ax_conf.set_ylim(0, 1)
    ax_conf.grid(True, alpha=0.3)

    # ─── 3. Top characters per time step ──────────────────────────────────
    ax_chars = fig.add_subplot(3, 1, 3)
    top_indices = np.argmax(y_pred, axis=-1)
    ax_chars.bar(range(len(top_indices)), top_indices, color='#4CAF50', alpha=0.7, width=1)
    ax_chars.set_xlabel('Time Step')
    ax_chars.set_ylabel('Character Index')
    ax_chars.set_title('Predicted Character Indices per Time Step', fontsize=12)
    ax_chars.grid(True, alpha=0.3)

    plt.tight_layout()

    report_path = os.path.join(output_dir, 'prediction_report.png')
    plt.savefig(report_path, dpi=150, bbox_inches='tight')
    plt.close()
    print(f"📊 Report saved: {report_path}")

    # ─── Text summary ────────────────────────────────────────────────────
    summary_path = os.path.join(output_dir, 'prediction_result.txt')
    with open(summary_path, 'w', encoding='utf-8') as f:
        f.write("=" * 50 + "\n")
        f.write("  LipNet Prediction Result\n")
        f.write("=" * 50 + "\n")
        f.write(f"Video:              {video_path}\n")
        f.write(f"Greedy Decoding:    \"{greedy_text}\"\n")
        f.write(f"Beam Search:        \"{beam_text}\"\n")
        f.write(f"Avg Confidence:     {confidence:.2%}\n")
        f.write(f"Total Frames:       {lip_frames.shape[0]}\n")
        f.write("=" * 50 + "\n")
    print(f"📝 Result saved: {summary_path}")


def main():
    parser = argparse.ArgumentParser(description='LipNet Prediction — ทดสอบ predict จากวิดีโอ')
    parser.add_argument('--video', type=str, required=True, help='Path ไปยังไฟล์วิดีโอ')
    parser.add_argument('--model-dir', type=str, default='models', help='Model directory')
    parser.add_argument('--max-frames', type=int, default=75, help='Max frames')

    args = parser.parse_args()

    print("=" * 60)
    print("  🔮 LipNet Inference Pipeline")
    print("=" * 60)

    # Load model
    model = load_model(args.model_dir, input_shape=(args.max_frames, LIP_HEIGHT, LIP_WIDTH, 1))

    # Predict
    greedy, beam, conf, frames, y_pred = predict_video(
        args.video, model, max_frames=args.max_frames
    )

    # Print results
    print("\n" + "=" * 60)
    print("  📋 Prediction Results")
    print("=" * 60)
    print(f"  Greedy Decoding: \"{greedy}\"")
    print(f"  Beam Search:     \"{beam}\"")
    print(f"  Confidence:      {conf:.2%}")
    print("=" * 60)

    # Save report
    save_prediction_report(args.video, greedy, beam, conf, frames, y_pred)

    print("\n✅ Done!")


if __name__ == '__main__':
    main()
