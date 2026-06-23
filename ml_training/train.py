"""
============================================================================
 LipNet Training Pipeline — Step 3: Training Script
============================================================================
 Usage:
   python train.py --epochs 200
   python train.py --epochs 500 --lr 0.0005

 For 1-clip demo: overfits the model on a single clip
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
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import tensorflow as tf
from tensorflow import keras

# Import our model
from model import (
    build_lipnet, text_to_indices, decode_predictions,
    NUM_CHARS, CHAR_TO_IDX
)


def compute_ctc_loss(y_true, y_pred, input_length, label_length):
    """Compute CTC loss"""
    return tf.reduce_mean(tf.nn.ctc_loss(
        labels=tf.cast(y_true, tf.int32),
        logits=tf.math.log(y_pred + 1e-8),  # log-softmax
        label_length=tf.cast(tf.squeeze(label_length, axis=-1), tf.int32),
        logit_length=tf.cast(tf.squeeze(input_length, axis=-1), tf.int32),
        logits_time_major=False,
        blank_index=0,
    ))


class LipNetTrainer:
    """Training manager for LipNet model"""

    def __init__(self, data_dir='data/processed', model_dir='models',
                 output_dir='outputs', epochs=200, batch_size=2, lr=0.001):
        self.data_dir = data_dir
        self.model_dir = model_dir
        self.output_dir = output_dir
        self.epochs = epochs
        self.batch_size = batch_size
        self.lr = lr
        self.loss_history = []

        os.makedirs(model_dir, exist_ok=True)
        os.makedirs(output_dir, exist_ok=True)

    def load_data(self):
        """Load preprocessed data"""
        lips_path = os.path.join(self.data_dir, 'lips.npy')
        label_path = os.path.join(self.data_dir, 'label.txt')

        if not os.path.exists(lips_path):
            print(f"[ERROR] Not found: {lips_path}")
            print("  Please run preprocess.py first")
            sys.exit(1)

        if not os.path.exists(label_path):
            print(f"[ERROR] Not found: {label_path}")
            sys.exit(1)

        # Load lip frames
        self.lips = np.load(lips_path)  # (T, H, W, 1)
        print(f"[DATA] Loaded lip frames: {self.lips.shape}")

        # Load label
        with open(label_path, 'r', encoding='utf-8') as f:
            self.label_text = f.read().strip()

        self.label_indices = text_to_indices(self.label_text)
        print(f"[DATA] Label: \"{self.label_text}\" -> {self.label_indices}")
        print(f"       Label length: {len(self.label_indices)} characters")

    def prepare_training_data(self):
        """Prepare data for CTC training"""
        num_copies = max(8, self.batch_size * 4)

        # Input video: (batch, T, H, W, C)
        self.X = np.repeat(self.lips[np.newaxis, ...], num_copies, axis=0).astype(np.float32)

        # Labels
        self.labels = np.array([self.label_indices] * num_copies, dtype=np.int32)

        # Input length (time steps)
        time_steps = self.lips.shape[0]
        self.input_lengths = np.full((num_copies, 1), time_steps, dtype=np.int32)

        # Label lengths
        max_label_len = len(self.label_indices)
        self.label_lengths = np.full((num_copies, 1), max_label_len, dtype=np.int32)

        print(f"\n[DATA] Training data prepared:")
        print(f"       Samples: {num_copies} (copies of 1 clip)")
        print(f"       Video shape: {self.X.shape}")
        print(f"       Labels shape: {self.labels.shape}")
        print(f"       Time steps: {time_steps}")

    def build_model(self):
        """Build prediction model (without CTC inputs)"""
        input_shape = self.lips.shape  # (T, H, W, 1)

        # We only need the prediction model for custom training
        _, self.model = build_lipnet(
            input_shape=input_shape, num_chars=NUM_CHARS
        )

        self.optimizer = keras.optimizers.Adam(learning_rate=self.lr)

        total_params = self.model.count_params()
        print(f"\n[MODEL] Built LipNet:")
        print(f"        Optimizer: Adam (lr={self.lr})")
        print(f"        Total parameters: {total_params:,}")

    @tf.function
    def train_step(self, video_batch, labels_batch, input_len_batch, label_len_batch):
        """Single training step with CTC loss"""
        with tf.GradientTape() as tape:
            # Forward pass
            y_pred = self.model(video_batch, training=True)
            # Compute CTC loss
            loss = compute_ctc_loss(labels_batch, y_pred, input_len_batch, label_len_batch)

        # Backward pass
        grads = tape.gradient(loss, self.model.trainable_variables)
        # Clip gradients to prevent explosion
        grads, _ = tf.clip_by_global_norm(grads, 5.0)
        self.optimizer.apply_gradients(zip(grads, self.model.trainable_variables))

        return loss

    def train(self):
        """Custom training loop"""
        print("\n" + "=" * 60)
        print("  Starting Training (Custom Loop)")
        print("=" * 60)

        num_samples = len(self.X)
        best_loss = float('inf')
        patience_counter = 0
        lr_patience = 20
        current_lr = self.lr

        # Convert to TF tensors
        dataset = tf.data.Dataset.from_tensor_slices((
            self.X, self.labels, self.input_lengths, self.label_lengths
        )).batch(self.batch_size).prefetch(tf.data.AUTOTUNE)

        for epoch in range(self.epochs):
            epoch_losses = []

            for video_b, labels_b, input_len_b, label_len_b in dataset:
                loss = self.train_step(video_b, labels_b, input_len_b, label_len_b)
                epoch_losses.append(float(loss))

            avg_loss = np.mean(epoch_losses)
            self.loss_history.append(avg_loss)

            # Print progress
            if (epoch + 1) % 10 == 0 or epoch == 0:
                print(f"  Epoch {epoch+1:4d}/{self.epochs} | Loss: {avg_loss:.4f} | LR: {current_lr:.6f}")

            # Decode prediction every 50 epochs
            if (epoch + 1) % 50 == 0:
                pred = self.model.predict(self.X[:1], verbose=0)
                decoded = decode_predictions(pred)
                print(f"  >>> Prediction: \"{decoded[0]}\" | Truth: \"{self.label_text}\"")

            # Save best model
            if avg_loss < best_loss:
                best_loss = avg_loss
                patience_counter = 0
                # Save best weights
                best_path = os.path.join(self.model_dir, 'lipnet_best.weights.h5')
                self.model.save_weights(best_path)
            else:
                patience_counter += 1

            # Reduce LR on plateau
            if patience_counter >= lr_patience:
                current_lr = max(current_lr * 0.5, 1e-6)
                self.optimizer.learning_rate.assign(current_lr)
                patience_counter = 0
                print(f"  [LR] Reduced to {current_lr:.6f}")

        print(f"\n  Best loss: {best_loss:.4f}")

    def save_results(self):
        """Save model and results"""
        # ─── Save final model ─────────────────────────────────────────────
        weights_path = os.path.join(self.model_dir, 'lipnet_final.weights.h5')
        self.model.save_weights(weights_path)
        print(f"\n[SAVE] Model weights: {weights_path}")

        pred_model_path = os.path.join(self.model_dir, 'lipnet_prediction.keras')
        self.model.save(pred_model_path)
        print(f"[SAVE] Prediction model: {pred_model_path}")

        # ─── Plot training loss ───────────────────────────────────────────
        if self.loss_history:
            fig, ax = plt.subplots(1, 1, figsize=(10, 5))

            ax.plot(self.loss_history, color='#4CAF50', linewidth=2, label='Training Loss')
            ax.set_xlabel('Epoch', fontsize=12)
            ax.set_ylabel('CTC Loss', fontsize=12)
            ax.set_title('Training Loss Curve', fontsize=14, fontweight='bold')
            ax.legend(fontsize=11)
            ax.grid(True, alpha=0.3)

            final_loss = self.loss_history[-1]
            ax.annotate(f'Final: {final_loss:.4f}',
                        xy=(len(self.loss_history)-1, final_loss),
                        fontsize=10, color='red',
                        arrowprops=dict(arrowstyle='->', color='red'))

            loss_path = os.path.join(self.output_dir, 'training_loss.png')
            plt.savefig(loss_path, dpi=150, bbox_inches='tight')
            plt.close()
            print(f"[SAVE] Loss curve: {loss_path}")

        # ─── Final prediction ─────────────────────────────────────────────
        print("\n" + "=" * 60)
        print("  Final Prediction")
        print("=" * 60)

        test_input = self.X[:1]
        pred = self.model.predict(test_input, verbose=0)
        decoded = decode_predictions(pred)

        print(f"  Ground Truth: \"{self.label_text}\"")
        print(f"  Prediction:   \"{decoded[0]}\"")
        match = decoded[0] == self.label_text
        print(f"  Match: {'YES!' if match else 'No (normal for 1 clip demo)'}")


def main():
    parser = argparse.ArgumentParser(description='LipNet Training')
    parser.add_argument('--epochs', type=int, default=200, help='Epochs (default: 200)')
    parser.add_argument('--lr', type=float, default=0.001, help='Learning rate (default: 0.001)')
    parser.add_argument('--batch-size', type=int, default=2, help='Batch size (default: 2)')
    parser.add_argument('--data-dir', type=str, default='data/processed', help='Data directory')

    args = parser.parse_args()

    print("=" * 60)
    print("  LipNet Training Pipeline")
    print("=" * 60)

    # Check GPU
    gpus = tf.config.list_physical_devices('GPU')
    if gpus:
        print(f"  GPU detected: {gpus[0].name}")
        for gpu in gpus:
            tf.config.experimental.set_memory_growth(gpu, True)
    else:
        print("  No GPU -- using CPU (OK for demo)")

    trainer = LipNetTrainer(
        data_dir=args.data_dir,
        epochs=args.epochs,
        batch_size=args.batch_size,
        lr=args.lr,
    )

    trainer.load_data()
    trainer.prepare_training_data()
    trainer.build_model()
    trainer.train()
    trainer.save_results()

    print("\n" + "=" * 60)
    print("  [DONE] Training complete!")
    print("=" * 60)
    print("  Next: python predict.py --video \"data/raw/your_video.mp4\"")
    print("  Or:   python visualize.py")


if __name__ == '__main__':
    main()
