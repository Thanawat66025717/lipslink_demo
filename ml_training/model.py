"""
============================================================================
 LipNet Training Pipeline — Step 2: Model Architecture
============================================================================
 สถาปัตยกรรม LipNet-style สำหรับ Lip Reading

 Architecture:
   Input (T, 50, 100, 1)
     → 3D-CNN (3 layers) — Extract spatiotemporal features
     → Reshape
     → Bi-LSTM (2 layers) — Sequence modeling
     → Dense + Softmax — Character prediction
     → CTC Loss — Alignment-free training

 Thai character set:
   ก-ฮ, สระ, วรรณยุกต์, ตัวเลข, เว้นวรรค
============================================================================
"""

import sys
import os

# Fix Windows cp874 encoding — force UTF-8 output
if sys.platform == 'win32':
    os.environ['PYTHONIOENCODING'] = 'utf-8'
    try:
        sys.stdout.reconfigure(encoding='utf-8')
        sys.stderr.reconfigure(encoding='utf-8')
    except Exception:
        pass

import numpy as np
import tensorflow as tf
from tensorflow import keras
from tensorflow.keras import layers


# ─── Thai character set ───────────────────────────────────────────────────────
THAI_CONSONANTS = 'กขฃคฅฆงจฉชซฌญฎฏฐฑฒณดตถทธนบปผฝพฟภมยรลวศษสหฬอฮ'
THAI_VOWELS = 'ะัาำิีึืุูเแโใไ็่้๊๋์'
THAI_DIGITS = '๐๑๒๓๔๕๖๗๘๙'
THAI_SPECIAL = ' '  # space

# Full character set (blank token '' at index 0 for CTC)
CHAR_LIST = [''] + list(THAI_CONSONANTS + THAI_VOWELS + THAI_DIGITS + THAI_SPECIAL)
CHAR_TO_IDX = {c: i for i, c in enumerate(CHAR_LIST)}
IDX_TO_CHAR = {i: c for i, c in enumerate(CHAR_LIST)}
NUM_CHARS = len(CHAR_LIST)  # includes CTC blank


def text_to_indices(text: str) -> list:
    """แปลงข้อความภาษาไทยเป็น list ของ indices"""
    indices = []
    for char in text:
        if char in CHAR_TO_IDX:
            indices.append(CHAR_TO_IDX[char])
        else:
            print(f"[WARN] Unknown char: '{char}'")
    return indices


def indices_to_text(indices: list) -> str:
    """แปลง indices กลับเป็นข้อความ (ข้าม blank token)"""
    text = ''
    prev_idx = -1
    for idx in indices:
        if idx == 0:  # CTC blank
            prev_idx = -1
            continue
        if idx == prev_idx:  # skip repeated (CTC decoding)
            continue
        if idx in IDX_TO_CHAR:
            text += IDX_TO_CHAR[idx]
        prev_idx = idx
    return text


# ─── CTC Loss Layer ──────────────────────────────────────────────────────────
class CTCLossLayer(layers.Layer):
    """Custom CTC Loss layer for training"""

    def __init__(self, **kwargs):
        super().__init__(**kwargs)

    def call(self, y_true, y_pred, input_length, label_length):
        loss = tf.nn.ctc_loss(
            labels=tf.cast(y_true, tf.int32),
            logits=y_pred,
            label_length=tf.cast(tf.squeeze(label_length), tf.int32),
            logit_length=tf.cast(tf.squeeze(input_length), tf.int32),
            logits_time_major=False,
            blank_index=0,
        )
        self.add_loss(tf.reduce_mean(loss))
        return y_pred


def build_lipnet(input_shape=(75, 50, 100, 1), num_chars=NUM_CHARS):
    """
    สร้าง LipNet-style model

    Architecture:
        3D-CNN (spatial+temporal features)
        -> Bi-LSTM (sequence modeling)
        -> Dense + Softmax (character prediction)

    Args:
        input_shape: (time_steps, height, width, channels)
        num_chars: จำนวนตัวอักษร (รวม CTC blank)

    Returns:
        model: keras.Model (for training with CTC)
        prediction_model: keras.Model (for inference)
    """
    time_steps = input_shape[0]

    # ─── Input ────────────────────────────────────────────────────────────
    input_video = layers.Input(shape=input_shape, name='input_video', dtype='float32')

    # ─── 3D CNN Backbone ──────────────────────────────────────────────────
    # Layer 1: Conv3D -> BatchNorm -> ReLU -> MaxPool3D
    x = layers.Conv3D(32, (3, 5, 5), padding='same', name='conv3d_1')(input_video)
    x = layers.BatchNormalization(name='bn_1')(x)
    x = layers.Activation('relu')(x)
    x = layers.MaxPooling3D((1, 2, 2), name='pool_1')(x)  # -> (T, 25, 50, 32)
    x = layers.Dropout(0.2)(x)

    # Layer 2: Conv3D -> BatchNorm -> ReLU -> MaxPool3D
    x = layers.Conv3D(64, (3, 5, 5), padding='same', name='conv3d_2')(x)
    x = layers.BatchNormalization(name='bn_2')(x)
    x = layers.Activation('relu')(x)
    x = layers.MaxPooling3D((1, 2, 2), name='pool_2')(x)  # -> (T, 12, 25, 64)
    x = layers.Dropout(0.2)(x)

    # Layer 3: Conv3D -> BatchNorm -> ReLU -> MaxPool3D
    x = layers.Conv3D(96, (3, 3, 3), padding='same', name='conv3d_3')(x)
    x = layers.BatchNormalization(name='bn_3')(x)
    x = layers.Activation('relu')(x)
    x = layers.MaxPooling3D((1, 2, 2), name='pool_3')(x)  # -> (T, 6, 12, 96)
    x = layers.Dropout(0.2)(x)

    # ─── Reshape: (T, H, W, C) -> (T, H*W*C) ─────────────────────────────
    # Flatten spatial dimensions, keep temporal
    shape = x.shape
    x = layers.Reshape((time_steps, -1), name='reshape')(x)

    # ─── Bi-LSTM Sequence Modeling ────────────────────────────────────────
    x = layers.Bidirectional(
        layers.LSTM(256, return_sequences=True, dropout=0.2),
        name='bi_lstm_1'
    )(x)
    x = layers.Bidirectional(
        layers.LSTM(256, return_sequences=True, dropout=0.2),
        name='bi_lstm_2'
    )(x)

    # ─── Output: Dense -> Softmax ──────────────────────────────────────────
    y_pred = layers.Dense(num_chars, activation='softmax', name='output')(x)

    # ─── CTC Training Model ──────────────────────────────────────────────
    labels = layers.Input(name='labels', shape=[None], dtype='int32')
    input_length = layers.Input(name='input_length', shape=[1], dtype='int32')
    label_length = layers.Input(name='label_length', shape=[1], dtype='int32')

    ctc_loss = CTCLossLayer(name='ctc_loss')(labels, y_pred, input_length, label_length)

    # Training model (with CTC loss)
    training_model = keras.Model(
        inputs=[input_video, labels, input_length, label_length],
        outputs=y_pred,
        name='lipnet_training'
    )

    # Prediction model (without CTC inputs)
    prediction_model = keras.Model(
        inputs=input_video,
        outputs=y_pred,
        name='lipnet_prediction'
    )

    return training_model, prediction_model


def decode_predictions(y_pred: np.ndarray) -> list:
    """
    CTC greedy decoding

    Args:
        y_pred: shape (batch, time_steps, num_chars) — softmax output

    Returns:
        list of decoded strings
    """
    results = []
    for pred in y_pred:
        # Greedy: argmax at each time step
        indices = np.argmax(pred, axis=-1)
        # CTC decode: remove blanks and consecutive duplicates
        text = indices_to_text(indices.tolist())
        results.append(text)
    return results


def ctc_beam_decode(y_pred: np.ndarray, beam_width: int = 10) -> list:
    """
    CTC beam search decoding using TensorFlow

    Args:
        y_pred: shape (batch, time_steps, num_chars)
        beam_width: beam width for search

    Returns:
        list of decoded strings
    """
    # TF expects time-major: (time, batch, chars)
    logits = tf.transpose(y_pred, [1, 0, 2])
    seq_len = tf.fill([y_pred.shape[0]], y_pred.shape[1])

    decoded, _ = tf.nn.ctc_beam_search_decoder(
        tf.math.log(logits + 1e-8),
        seq_len,
        beam_width=beam_width
    )

    results = []
    sparse = decoded[0]
    dense = tf.sparse.to_dense(sparse, default_value=0).numpy()
    for row in dense:
        text = indices_to_text(row.tolist())
        results.append(text)
    return results


# ─── Print model summary ─────────────────────────────────────────────────────
if __name__ == '__main__':
    print("=" * 60)
    print("  LipNet Model Architecture")
    print("=" * 60)
    print(f"  Thai character set: {NUM_CHARS} characters (incl. CTC blank)")
    print("=" * 60)

    training_model, prediction_model = build_lipnet()

    print("\n[INFO] Training Model:")
    training_model.summary()

    print("\n[INFO] Prediction Model:")
    prediction_model.summary()

    # Test encoding/decoding
    test_text = "sawasdee krub"
    test_thai = "\u0e2a\u0e27\u0e31\u0e2a\u0e14\u0e35\u0e04\u0e23\u0e31\u0e1a"
    encoded = text_to_indices(test_thai)
    decoded = indices_to_text(encoded)
    print(f"\n[TEST] Encoding: '{test_thai}' -> {encoded} -> '{decoded}'")
