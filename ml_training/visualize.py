"""
============================================================================
 LipNet Training Pipeline — Step 5: Visualization & Learning Tools
============================================================================
 วิธีใช้:
   python visualize.py

 เครื่องมือสำหรับเรียนรู้และ visualize ทุกขั้นตอนของ pipeline:
 1. แสดง lip crop frames แบบ animation
 2. แสดง model architecture diagram
 3. แสดง training loss curve
 4. แสดง CTC alignment visualization
 5. เปรียบเทียบ prediction vs ground truth
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

import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.gridspec import GridSpec
import matplotlib.patches as mpatches


def visualize_lip_frames(data_dir='data/processed', output_dir='outputs'):
    """แสดง lip crop frames ที่ preprocess แล้ว"""
    lips_path = os.path.join(data_dir, 'lips.npy')
    if not os.path.exists(lips_path):
        print("❌ ไม่พบ lips.npy — กรุณารัน preprocess.py ก่อน")
        return

    lips = np.load(lips_path)  # (T, H, W, 1)
    total = lips.shape[0]

    # ─── Frame montage ────────────────────────────────────────────────────
    n_rows = 4
    n_cols = 8
    n_show = min(n_rows * n_cols, total)
    indices = np.linspace(0, total - 1, n_show, dtype=int)

    fig, axes = plt.subplots(n_rows, n_cols, figsize=(16, 8))
    fig.suptitle(f'👄 Lip Frames — Total: {total} frames', fontsize=16, fontweight='bold')

    for i, ax in enumerate(axes.flat):
        if i < n_show:
            ax.imshow(lips[indices[i], :, :, 0], cmap='gray', vmin=0, vmax=1)
            ax.set_title(f'#{indices[i]}', fontsize=8, color='#666')
        ax.axis('off')

    plt.tight_layout()
    path = os.path.join(output_dir, 'lip_frames_all.png')
    plt.savefig(path, dpi=150, bbox_inches='tight')
    plt.close()
    print(f"✅ Lip frames saved: {path}")

    # ─── Frame statistics ─────────────────────────────────────────────────
    fig, axes = plt.subplots(1, 3, figsize=(15, 4))
    fig.suptitle('📊 Frame Statistics', fontsize=14, fontweight='bold')

    # Mean brightness over time
    mean_brightness = lips[:, :, :, 0].mean(axis=(1, 2))
    axes[0].plot(mean_brightness, color='#FF9800', linewidth=1.5)
    axes[0].set_title('Mean Brightness per Frame')
    axes[0].set_xlabel('Frame')
    axes[0].set_ylabel('Brightness (0-1)')
    axes[0].grid(True, alpha=0.3)

    # Pixel intensity histogram
    axes[1].hist(lips.flatten(), bins=50, color='#2196F3', alpha=0.7, edgecolor='white')
    axes[1].set_title('Pixel Intensity Distribution')
    axes[1].set_xlabel('Pixel Value')
    axes[1].set_ylabel('Count')

    # Frame-to-frame difference (motion)
    if total > 1:
        diffs = np.abs(lips[1:, :, :, 0] - lips[:-1, :, :, 0]).mean(axis=(1, 2))
        axes[2].plot(diffs, color='#4CAF50', linewidth=1.5)
        axes[2].fill_between(range(len(diffs)), diffs, alpha=0.2, color='#4CAF50')
        axes[2].set_title('Frame-to-Frame Motion')
        axes[2].set_xlabel('Frame')
        axes[2].set_ylabel('Mean Absolute Diff')
        axes[2].grid(True, alpha=0.3)

    plt.tight_layout()
    path = os.path.join(output_dir, 'frame_statistics.png')
    plt.savefig(path, dpi=150, bbox_inches='tight')
    plt.close()
    print(f"✅ Frame statistics saved: {path}")


def visualize_architecture(output_dir='outputs'):
    """แสดง model architecture diagram"""
    fig, ax = plt.subplots(1, 1, figsize=(12, 16))
    ax.set_xlim(0, 10)
    ax.set_ylim(0, 22)
    ax.axis('off')
    ax.set_title('🧠 LipNet Architecture', fontsize=18, fontweight='bold', pad=20)

    # Define layers
    layers_info = [
        ('Input', '(75, 50, 100, 1)', '#E3F2FD', 'วิดีโอ lip frames\n75 frames × 50×100 grayscale'),
        ('Conv3D + BN + ReLU', '→ (75, 25, 50, 32)', '#C8E6C9', '3D Convolution: จับ pattern\nของปากทั้ง spatial + temporal'),
        ('Conv3D + BN + ReLU', '→ (75, 12, 25, 64)', '#C8E6C9', 'Feature extraction:\nรูปร่างปากละเอียดขึ้น'),
        ('Conv3D + BN + ReLU', '→ (75, 6, 12, 96)', '#C8E6C9', 'High-level features:\nจับ pattern การขยับปาก'),
        ('Reshape', '→ (75, 6912)', '#FFF3E0', 'Flatten spatial dimensions\nเหลือแค่ time × features'),
        ('Bi-LSTM 1', '→ (75, 512)', '#E1BEE7', 'Sequential modeling:\nเข้าใจลำดับการขยับปาก'),
        ('Bi-LSTM 2', '→ (75, 512)', '#E1BEE7', 'Deep sequence features:\nจับ context ยาวขึ้น'),
        ('Dense + Softmax', '→ (75, 70)', '#FFCDD2', 'Output per time step:\nความน่าจะเป็นของแต่ละตัวอักษร'),
        ('CTC Decode', '→ "สวัสดีครับ"', '#FFF9C4', 'Connectionist Temporal Classification:\nแปลง sequence → text'),
    ]

    y_start = 20
    box_h = 1.5
    gap = 0.3

    for i, (name, shape, color, desc) in enumerate(layers_info):
        y = y_start - i * (box_h + gap)

        # Main box
        rect = mpatches.FancyBboxPatch(
            (1, y - box_h/2), 8, box_h,
            boxstyle='round,pad=0.15',
            facecolor=color, edgecolor='#333', linewidth=1.5
        )
        ax.add_patch(rect)

        # Layer name
        ax.text(5, y + 0.2, name, fontsize=12, fontweight='bold',
                ha='center', va='center', color='#333')
        # Shape
        ax.text(5, y - 0.15, shape, fontsize=9, ha='center', va='center',
                color='#666', style='italic')
        # Description (right side)
        ax.text(5, y - 0.5, desc, fontsize=7, ha='center', va='center',
                color='#888')

        # Arrow
        if i < len(layers_info) - 1:
            ax.annotate('', xy=(5, y - box_h/2 - 0.05),
                        xytext=(5, y - box_h/2 - gap + 0.05),
                        arrowprops=dict(arrowstyle='->', color='#666', lw=2))

    plt.tight_layout()
    path = os.path.join(output_dir, 'architecture_diagram.png')
    plt.savefig(path, dpi=150, bbox_inches='tight')
    plt.close()
    print(f"✅ Architecture diagram saved: {path}")


def visualize_training(output_dir='outputs'):
    """แสดง training loss curve (ถ้ามี)"""
    loss_path = os.path.join(output_dir, 'training_loss.png')
    if os.path.exists(loss_path):
        print(f"✅ Training loss curve already exists: {loss_path}")
    else:
        print("⚠️ ไม่พบ training loss — กรุณารัน train.py ก่อน")


def visualize_prediction(output_dir='outputs'):
    """แสดง prediction result (ถ้ามี)"""
    report_path = os.path.join(output_dir, 'prediction_report.png')
    if os.path.exists(report_path):
        print(f"✅ Prediction report already exists: {report_path}")
    else:
        print("⚠️ ไม่พบ prediction report — กรุณารัน predict.py ก่อน")


def create_pipeline_overview(output_dir='outputs'):
    """สร้างภาพรวม pipeline ทั้งหมด"""
    fig = plt.figure(figsize=(18, 6))
    fig.suptitle('🔄 LipNet Training Pipeline Overview', fontsize=18, fontweight='bold')

    steps = [
        ('📹\nVideo Input', 'MP4 file\nwith face', '#E3F2FD'),
        ('🔍\nFace Mesh', 'MediaPipe\n468 landmarks', '#C8E6C9'),
        ('✂️\nLip Crop', 'ROI extraction\n100×50 px', '#FFF3E0'),
        ('🔢\nNormalize', 'Grayscale\n0-1 float', '#E1BEE7'),
        ('🧠\n3D-CNN', 'Spatial +\nTemporal', '#FFCDD2'),
        ('📊\nBi-LSTM', 'Sequence\nModeling', '#B3E5FC'),
        ('🎯\nCTC Loss', 'Alignment\nFree', '#FFF9C4'),
        ('📝\nText Output', '"สวัสดีครับ"', '#C8E6C9'),
    ]

    for i, (title, desc, color) in enumerate(steps):
        x = i * 2.2 + 0.5
        rect = mpatches.FancyBboxPatch(
            (x, 1), 1.8, 3.5,
            boxstyle='round,pad=0.2',
            facecolor=color, edgecolor='#555', linewidth=1.5
        )
        fig.gca().add_patch(rect)
        fig.gca().text(x + 0.9, 3.8, title, fontsize=11, fontweight='bold',
                       ha='center', va='center')
        fig.gca().text(x + 0.9, 2.0, desc, fontsize=8, ha='center', va='center',
                       color='#666')

        if i < len(steps) - 1:
            fig.gca().annotate('', xy=(x + 2.0, 2.75), xytext=(x + 1.85, 2.75),
                               arrowprops=dict(arrowstyle='->', color='#888', lw=2))

    fig.gca().set_xlim(-0.2, len(steps) * 2.2 + 0.3)
    fig.gca().set_ylim(0, 5.5)
    fig.gca().axis('off')

    path = os.path.join(output_dir, 'pipeline_overview.png')
    plt.savefig(path, dpi=150, bbox_inches='tight')
    plt.close()
    print(f"✅ Pipeline overview saved: {path}")


def main():
    output_dir = 'outputs'
    os.makedirs(output_dir, exist_ok=True)

    print("=" * 60)
    print("  📊 LipNet Visualization & Learning Tools")
    print("=" * 60)

    # 1. Pipeline overview
    print("\n📌 1. Pipeline Overview")
    create_pipeline_overview(output_dir)

    # 2. Architecture diagram
    print("\n📌 2. Architecture Diagram")
    visualize_architecture(output_dir)

    # 3. Lip frames
    print("\n📌 3. Lip Frames")
    visualize_lip_frames(output_dir=output_dir)

    # 4. Training results
    print("\n📌 4. Training Results")
    visualize_training(output_dir)

    # 5. Prediction results
    print("\n📌 5. Prediction Results")
    visualize_prediction(output_dir)

    print("\n" + "=" * 60)
    print("  ✅ Visualization เสร็จสมบูรณ์!")
    print(f"  📁 ไฟล์ทั้งหมดอยู่ใน: {output_dir}/")
    print("=" * 60)

    # List generated files
    if os.path.exists(output_dir):
        files = os.listdir(output_dir)
        if files:
            print("\n  📄 Generated files:")
            for f in sorted(files):
                size = os.path.getsize(os.path.join(output_dir, f))
                print(f"     - {f} ({size/1024:.1f} KB)")


if __name__ == '__main__':
    main()
