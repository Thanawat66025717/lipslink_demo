"""VocaLip_TH sentence model: visual encoder + BiGRU CTC over 106 characters.

Everything that must match training (frame rate, colour order, scaling, blank
offset, vocabulary) is read from the config files shipped with the model, so a
new export with different values is picked up without code changes.
"""
import json
import os

import numpy as np
import torch
import torch.nn as nn


class VisualEncoder(nn.Module):
    # Layer names follow the shipped weights (net.* / proj.*). The package's
    # deployment_model.py calls them cnn.* / projection.*, which cannot load
    # those weights strictly.
    def __init__(self, dim=256):
        super().__init__()
        self.net = nn.Sequential(
            nn.Conv2d(3, 32, 5, 2, 2), nn.BatchNorm2d(32), nn.ReLU(),
            nn.Conv2d(32, 64, 3, 2, 1), nn.BatchNorm2d(64), nn.ReLU(),
            nn.Conv2d(64, 128, 3, 2, 1), nn.BatchNorm2d(128), nn.ReLU(),
            nn.Conv2d(128, 256, 3, 2, 1), nn.BatchNorm2d(256), nn.ReLU(),
            nn.AdaptiveAvgPool2d(1),
        )
        self.proj = nn.Linear(256, dim)

    def forward(self, x):
        b, t, c, h, w = x.shape
        z = self.net(x.reshape(b * t, c, h, w)).flatten(1)
        return self.proj(z).reshape(b, t, -1)


class _TemporalEncoder(nn.Module):
    def __init__(self, dim, hidden, layers):
        super().__init__()
        self.gru = nn.GRU(dim, hidden, num_layers=layers,
                          batch_first=True, bidirectional=True)

    def forward(self, x):
        return self.gru(x)[0]


class FeatureCTC(nn.Module):
    def __init__(self, vocab_size, dim=256, hidden=256, layers=2):
        super().__init__()
        self.temporal_encoder = _TemporalEncoder(dim, hidden, layers)
        self.ctc_head = nn.Linear(hidden * 2, vocab_size)

    def forward(self, features):
        return self.ctc_head(self.temporal_encoder(features))


def _read_json(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def load_vocalip_ctc(model_dir):
    """Raises FileNotFoundError when the model folder is incomplete."""
    pipeline = _read_json(os.path.join(model_dir, "pipeline_config.json"))
    decoder = _read_json(os.path.join(model_dir, "decoder_config.json"))
    vocab = _read_json(os.path.join(model_dir, "vocab.json"))

    id_to_char = {int(k): v for k, v in vocab["id_to_char"].items()}
    blank_id = int(vocab["blank_id"])
    vocab_size = int(vocab["vocab_size"])
    dim = int(pipeline["visual_feature_dim"])

    enc_ck = torch.load(os.path.join(model_dir, "visual_encoder.pt"),
                        map_location="cpu", weights_only=False)
    encoder = VisualEncoder(dim)
    encoder.load_state_dict(enc_ck["model_state_dict"], strict=True)
    encoder.eval()

    ctc_ck = torch.load(os.path.join(model_dir, "vocalip_th_ctc.pt"),
                        map_location="cpu", weights_only=False)
    ctc = FeatureCTC(vocab_size, dim)
    ctc.load_state_dict(ctc_ck["model_state_dict"], strict=True)
    ctc.eval()

    meta = {
        "format": ctc_ck.get("format"),
        "encoder_format": enc_ck.get("format"),
        "validation_cer": decoder.get("calibrated_cer", ctc_ck.get("validation_cer")),
        "validation_samples": decoder.get("validation_samples"),
        "target_fps": float(pipeline["target_fps"]),
        "roi": int(pipeline["roi_size"]),
        "mouth_scale": float(pipeline["mouth_scale"]),
        "color_order": pipeline["color_order"],
        "blank_id": blank_id,
        "blank_logit_offset": float(decoder["blank_logit_offset"]),
        "vocab_size": vocab_size,
    }
    if meta["color_order"].upper() != "RGB":
        raise ValueError(f"unsupported color_order {meta['color_order']!r}")
    return encoder, ctc, id_to_char, meta


def resample_to_fps(frames, capture_ms, target_fps):
    """Spread frames captured over capture_ms onto a target_fps timeline.

    The phone captures at 2-7 fps while the model was trained at 25 fps, so
    frames are repeated (nearest in time) to give the model the timeline length
    it expects. Repeating adds no lip motion; it only keeps the frames-per-
    character ratio close to training.
    """
    n = len(frames)
    if not capture_ms or capture_ms <= 0 or n == 0:
        return frames
    t = max(1, int(round(capture_ms / 1000.0 * target_fps)))
    idx = np.minimum((np.arange(t) * n) // t, n - 1)
    return frames[idx]


def ctc_greedy_decode(logits, id_to_char, blank_id, blank_offset):
    """logits: [T, V]. Offset is subtracted from the blank logit before argmax."""
    x = logits.clone()
    x[:, blank_id] -= blank_offset
    raw = x.argmax(dim=-1).tolist()
    tokens, prev = [], None
    for tok in raw:
        if tok != prev and tok != blank_id:
            tokens.append(tok)
        prev = tok
    blank_rate = sum(1 for tok in raw if tok == blank_id) / max(len(raw), 1)
    return "".join(id_to_char[t] for t in tokens), tokens, blank_rate


@torch.inference_mode()
def predict_text(encoder, ctc, id_to_char, meta, frames_rgb):
    """frames_rgb: uint8 [T, H, W, 3] in RGB order, already at target fps."""
    x = torch.from_numpy(np.ascontiguousarray(frames_rgb)).permute(0, 3, 1, 2)
    x = x.float().div(255.0).unsqueeze(0)
    logits = ctc(encoder(x))[0]
    return ctc_greedy_decode(logits, id_to_char, meta["blank_id"],
                             meta["blank_logit_offset"])
