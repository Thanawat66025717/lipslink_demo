"""
LipNet PyTorch Model Definitions
สถาปัตยกรรมโมเดลที่ตรงกับ checkpoint .pt ทั้ง 2 ตัว
"""

import torch
import torch.nn as nn
import numpy as np
import json
import os


# ─── Model 1: LipReadingModel (best_model.pt) ────────────────────────────────
# Input: lip frames (grayscale 96x96)
# Architecture: CNN(32→64→128) → Linear(128) → BiGRU(2 layers, hidden=192) → classifier(163)

class LipReadingModel(nn.Module):
    """โมเดลอ่านปากจากภาพปากอย่างเดียว"""

    def __init__(self, vocab_size=163, gru_hidden=192, gru_layers=2, dropout=0.2):
        super().__init__()

        # CNN Encoder สำหรับแต่ละ frame
        self.frame_encoder = nn.Module()
        self.frame_encoder.net = nn.Sequential(
            nn.Conv2d(1, 32, 5, padding=2),
            nn.BatchNorm2d(32),
            nn.ReLU(),
            nn.MaxPool2d(2),
            nn.Conv2d(32, 64, 3, padding=1),
            nn.BatchNorm2d(64),
            nn.ReLU(),
            nn.MaxPool2d(2),
            nn.Conv2d(64, 128, 3, padding=1),
            nn.BatchNorm2d(128),
            nn.ReLU(),
            nn.AdaptiveAvgPool2d(1),
        )
        self.frame_encoder.proj = nn.Linear(128, 128)

        # Bi-GRU for temporal modeling
        self.temporal = nn.GRU(
            128, gru_hidden, num_layers=gru_layers,
            batch_first=True, bidirectional=True, dropout=dropout
        )

        # Classifier
        self.classifier = nn.Linear(gru_hidden * 2, vocab_size)

    def forward(self, x):
        """
        x: (batch, time, height, width) - grayscale lip frames
        """
        B, T, H, W = x.shape
        x = x.view(B * T, 1, H, W)  # (B*T, 1, H, W)

        # Encode each frame
        feat = self.frame_encoder.net(x)  # (B*T, 128, 1, 1)
        feat = feat.view(B * T, -1)  # (B*T, 128)
        feat = self.frame_encoder.proj(feat)  # (B*T, 128)
        feat = feat.view(B, T, -1)  # (B, T, 128)

        # Temporal modeling
        out, _ = self.temporal(feat)  # (B, T, hidden*2)

        # Classify
        logits = self.classifier(out)  # (B, T, vocab_size)
        return logits


# ─── Model 2: DualStreamModel (best_model (1).pt) ────────────────────────────
# Input: face (grayscale 112x112) + mouth (grayscale 96x96)
# Architecture: face_encoder + mouth_encoder → fusion → BiGRU → classifier

class VisualEncoderV4(nn.Module):
    """CNN Encoder V4 สำหรับแต่ละ stream"""

    def __init__(self, out_dim=128):
        super().__init__()
        self.features = nn.Sequential(
            nn.Conv2d(1, 24, kernel_size=5, padding=2, bias=False),
            nn.GroupNorm(6, 24),
            nn.SiLU(inplace=True),
            nn.MaxPool2d(2),

            nn.Conv2d(24, 48, kernel_size=3, padding=1, bias=False),
            nn.GroupNorm(8, 48),
            nn.SiLU(inplace=True),
            nn.MaxPool2d(2),

            nn.Conv2d(48, 96, kernel_size=3, padding=1, bias=False),
            nn.GroupNorm(12, 96),
            nn.SiLU(inplace=True),
            nn.AdaptiveAvgPool2d((1, 1)),
        )
        self.proj = nn.Sequential(
            nn.Flatten(),
            nn.Linear(96, out_dim),
            nn.LayerNorm(out_dim),
        )

    def forward(self, x):
        return self.proj(self.features(x))


class DualStreamModel(nn.Module):
    """โมเดลอ่านปากจากทั้งใบหน้า + ภาพปาก (V4)"""

    def __init__(self, vocab_size=163, feature_dim=128, gru_hidden=192, gru_layers=2, dropout=0.10):
        super().__init__()
        self.face_encoder = VisualEncoderV4(feature_dim)
        self.mouth_encoder = VisualEncoderV4(feature_dim)

        # learned gate
        self.gate = nn.Sequential(
            nn.Linear(feature_dim * 2, feature_dim),
            nn.Sigmoid(),
        )
        self.fusion_norm = nn.LayerNorm(feature_dim)

        self.temporal = nn.GRU(
            input_size=feature_dim,
            hidden_size=gru_hidden,
            num_layers=gru_layers,
            batch_first=True,
            bidirectional=True,
            dropout=dropout if gru_layers > 1 else 0.0,
        )

        self.dropout = nn.Dropout(dropout)
        self.classifier = nn.Linear(gru_hidden * 2, vocab_size)

    def forward(self, face_frames, mouth_frames):
        """
        face_frames: (batch, time, 112, 112)
        mouth_frames: (batch, time, 96, 96)
        """
        B, T = face_frames.shape[:2]

        face_flat = face_frames.reshape(B * T, 1, face_frames.shape[2], face_frames.shape[3])
        mouth_flat = mouth_frames.reshape(B * T, 1, mouth_frames.shape[2], mouth_frames.shape[3])

        f = self.face_encoder(face_flat)
        m = self.mouth_encoder(mouth_flat)

        g = self.gate(torch.cat([f, m], dim=-1))
        fused = g * m + (1.0 - g) * f
        fused = self.fusion_norm(fused).reshape(B, T, -1)

        # Temporal
        out, _ = self.temporal(fused)

        logits = self.classifier(self.dropout(out))
        return logits


# ─── CTC Decoding ─────────────────────────────────────────────────────────────

def ctc_greedy_decode(logits, itos):
    """
    CTC greedy decoding

    Args:
        logits: (time, vocab_size) - output จากโมเดล
        itos: dict mapping index → character

    Returns:
        decoded text string
    """
    # Argmax at each timestep
    indices = torch.argmax(logits, dim=-1).tolist()

    # Remove blanks and consecutive duplicates
    decoded = []
    prev_idx = -1
    for idx in indices:
        if idx == 0:  # <blank>
            prev_idx = -1
            continue
        if idx == prev_idx:  # skip repeated
            continue
        if idx == 1:  # <unk>
            prev_idx = idx
            continue
        char = itos.get(str(idx), itos.get(idx, ''))
        if char and char not in ('<blank>', '<unk>'):
            decoded.append(char)
        prev_idx = idx

    return ''.join(decoded)


# ─── Model Loading ────────────────────────────────────────────────────────────

def load_model_1(model_path):
    """โหลด best_model.pt (lip frames only)"""
    checkpoint = torch.load(model_path, map_location='cpu', weights_only=False)
    config = checkpoint.get('config', {})
    vocab_size = checkpoint.get('vocab_size', 163)
    itos = checkpoint.get('itos', {})

    model = LipReadingModel(
        vocab_size=vocab_size,
        gru_hidden=config.get('gru_hidden', 192),
        gru_layers=config.get('gru_layers', 2),
        dropout=config.get('dropout', 0.2),
    )
    model.load_state_dict(checkpoint['model_state_dict'])
    model.eval()

    # Normalize itos keys to strings
    if isinstance(itos, list):
        itos = {str(i): c for i, c in enumerate(itos)}
    elif isinstance(itos, dict):
        itos = {str(k): v for k, v in itos.items()}

    return model, itos, config


def load_model_2(model_path):
    """โหลด best_model (1).pt (face + mouth)"""
    checkpoint = torch.load(model_path, map_location='cpu', weights_only=False)
    config = checkpoint.get('config', {})
    vocab_size = checkpoint.get('vocab_size', 163)
    itos = checkpoint.get('itos', {})

    model = DualStreamModel(
        vocab_size=vocab_size,
        feature_dim=config.get('feature_dim', 128),
        gru_hidden=config.get('gru_hidden', 192),
        gru_layers=config.get('gru_layers', 2),
        dropout=config.get('dropout', 0.10),
    )
    model.load_state_dict(checkpoint['model_state_dict'])
    model.eval()

    if isinstance(itos, list):
        itos = {str(i): c for i, c in enumerate(itos)}
    elif isinstance(itos, dict):
        itos = {str(k): v for k, v in itos.items()}

    return model, itos, config


# ============================================================
# VocaLip Thai — 44-word classifier (Notebook 03)
# ============================================================
#
# โครงสร้างพอร์ตมาจาก Notebook 03 CELL 3 ตรงตัว ห้ามแก้ตัวเลขใดๆ
# เพราะน้ำหนักที่เทรนมาผูกกับโครงสร้างนี้เป๊ะ ถ้าไม่ตรงจะโหลดไม่ผ่าน
# (ตั้งใจใช้ strict=True เพื่อให้ error ทันทีแทนที่จะทำนายมั่วเงียบๆ)


class VocaLipFrameCNN(nn.Module):
    def __init__(self):
        super().__init__()
        self.features = nn.Sequential(
            nn.Conv2d(3, 32, 3, padding=1, bias=False),
            nn.BatchNorm2d(32), nn.ReLU(True), nn.MaxPool2d(2),
            nn.Conv2d(32, 64, 3, padding=1, bias=False),
            nn.BatchNorm2d(64), nn.ReLU(True), nn.MaxPool2d(2),
            nn.Conv2d(64, 96, 3, padding=1, bias=False),
            nn.BatchNorm2d(96), nn.ReLU(True), nn.MaxPool2d(2),
            nn.Conv2d(96, 128, 3, padding=1, bias=False),
            nn.BatchNorm2d(128), nn.ReLU(True), nn.AdaptiveAvgPool2d((1, 1)),
        )
        self.projection = nn.Sequential(
            nn.Flatten(), nn.Linear(128, 128), nn.ReLU(True), nn.Dropout(0.10),
        )

    def forward(self, x):
        return self.projection(self.features(x))


class VocaLipAttention(nn.Module):
    def __init__(self):
        super().__init__()
        self.attention = nn.Sequential(
            nn.Linear(512, 128), nn.Tanh(), nn.Linear(128, 1),
        )

    def forward(self, x):
        w = torch.softmax(self.attention(x).squeeze(-1), 1)
        return (x * w.unsqueeze(-1)).sum(1), w


class VocaLipEncoder(nn.Module):
    def __init__(self):
        super().__init__()
        self.frame_encoder = VocaLipFrameCNN()
        self.temporal_encoder = nn.GRU(
            128, 256, 2, batch_first=True, bidirectional=True, dropout=0.20,
        )
        self.temporal_attention = VocaLipAttention()

    def forward(self, x):
        B, T, C, H, W = x.shape
        f = self.frame_encoder(x.reshape(B * T, C, H, W)).reshape(B, T, -1)
        h, _ = self.temporal_encoder(f)
        return self.temporal_attention(h)[0]


class VocaLipWordModel(nn.Module):
    def __init__(self, num_classes=44):
        super().__init__()
        self.encoder = VocaLipEncoder()
        self.classifier = nn.Sequential(
            nn.LayerNorm(512), nn.Dropout(0.2),
            nn.Linear(512, 256), nn.ReLU(True), nn.Dropout(0.2),
            nn.Linear(256, num_classes),
        )

    def forward(self, x):
        return self.classifier(self.encoder(x))


def load_vocalip_word_model(model_path):
    """โหลด deployment checkpoint ฟอร์แมต VocaLipThai-44Word-v1

    คืน (model, id_to_word, meta) โดย meta รวม config/preprocessing/metrics
    ที่ผู้เทรนบันทึกมาด้วย เพื่อให้ฝั่ง API ใช้ค่าจริงจาก checkpoint
    แทนการ hardcode เอง
    """
    checkpoint = torch.load(model_path, map_location='cpu', weights_only=False)

    fmt = checkpoint.get('format')
    if fmt != 'VocaLipThai-44Word-v1':
        raise ValueError(
            f"ฟอร์แมต checkpoint ไม่ตรงที่รองรับ: {fmt!r} "
            "(ต้องการ 'VocaLipThai-44Word-v1')"
        )

    config = checkpoint.get('model_config', {})
    num_classes = int(config.get('classes', 44))

    model = VocaLipWordModel(num_classes=num_classes)
    model.load_state_dict(checkpoint['model_state_dict'], strict=True)
    model.eval()

    # คีย์อาจเป็น int หรือ str แล้วแต่ตอนเซฟ ทำให้เป็น int ให้หมด
    id_to_word = {
        int(k): str(v) for k, v in checkpoint['id_to_word'].items()
    }

    meta = {
        'format': fmt,
        'config': config,
        'preprocessing': checkpoint.get('preprocessing', {}),
        'test_metrics': checkpoint.get('test_metrics', {}),
        'scope': checkpoint.get('scope'),
        'num_classes': num_classes,
    }

    return model, id_to_word, meta


# ─── VocaLip 44 คำ รุ่น "real lipreading" (05_...) ────────────────────────────
# ชิ้นส่วนข้างในเหมือนรุ่นก่อนทุกตัว (ชื่อและรูปร่าง tensor ตรงกันหมด) ต่างกันแค่
# รุ่นก่อนห่อ frame_encoder/temporal_encoder/temporal_attention ไว้ใต้ .encoder
# อีกชั้น ส่วนรุ่นนี้วางไว้ที่ระดับบนสุดเลย จึงใช้คลาสเดิมประกอบใหม่ได้

class VocaLipRealModel(nn.Module):
    def __init__(self, num_classes=44, gru_hidden=256, gru_layers=2,
                 feature_dim=128, dropout=0.2):
        super().__init__()
        self.frame_encoder = VocaLipFrameCNN()
        self.temporal_encoder = nn.GRU(
            feature_dim, gru_hidden, gru_layers,
            batch_first=True, bidirectional=True, dropout=dropout,
        )
        self.temporal_attention = VocaLipAttention()
        self.classifier = nn.Sequential(
            nn.LayerNorm(gru_hidden * 2), nn.Dropout(dropout),
            nn.Linear(gru_hidden * 2, 256), nn.ReLU(True), nn.Dropout(dropout),
            nn.Linear(256, num_classes),
        )

    def forward(self, x):
        B, T, C, H, W = x.shape
        f = self.frame_encoder(x.reshape(B * T, C, H, W)).reshape(B, T, -1)
        h, _ = self.temporal_encoder(f)
        pooled, _ = self.temporal_attention(h)
        return self.classifier(pooled)


def load_vocalip_real_model(model_path):
    """โหลด checkpoint ฟอร์แมต VocaLip-44word-real-lipreading-v1

    คืน (model, id_to_word, meta) โดยค่าทุกอย่างที่ deployment ต้องใช้ —
    ลำดับช่องสี, จำนวนเฟรม, ขนาด ROI, เกณฑ์ปฏิเสธ, motion gate — อ่านจาก
    checkpoint ทั้งหมด ไม่ hardcode ที่ฝั่ง server

    โหลดแบบ strict=True เพื่อให้พังทันทีถ้าสถาปัตยกรรมไม่ตรง ดีกว่าโหลดผ่าน
    แบบหลวมๆ แล้วได้โมเดลที่น้ำหนักบางส่วนเป็นค่าสุ่มโดยไม่มีอะไรฟ้อง
    """
    checkpoint = torch.load(model_path, map_location='cpu', weights_only=False)

    fmt = checkpoint.get('format')
    if fmt != 'VocaLip-44word-real-lipreading-v1':
        raise ValueError(
            f"ฟอร์แมต checkpoint ไม่ตรงที่รองรับ: {fmt!r} "
            "(ต้องการ 'VocaLip-44word-real-lipreading-v1')"
        )

    config = checkpoint.get('model_config', {})
    num_classes = int(config.get('num_classes', 44))

    model = VocaLipRealModel(
        num_classes=num_classes,
        gru_hidden=int(config.get('gru_hidden', 256)),
        gru_layers=int(config.get('gru_layers', 2)),
        feature_dim=int(config.get('feature_dim', 128)),
        dropout=float(config.get('dropout', 0.2)),
    )
    model.load_state_dict(checkpoint['model_state_dict'], strict=True)
    model.eval()

    id_to_word = {int(k): str(v) for k, v in checkpoint['id_to_word'].items()}

    meta = {
        'format': fmt,
        'config': config,
        'preprocessing': checkpoint.get('preprocessing', {}),
        'rejection': checkpoint.get('rejection', {}),
        'motion_gate': checkpoint.get('motion_gate', {}),
        'test_metrics': checkpoint.get('test_metrics', {}),
        'scope': checkpoint.get('scope'),
        'num_classes': num_classes,
    }

    return model, id_to_word, meta
