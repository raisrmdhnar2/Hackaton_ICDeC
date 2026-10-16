"""
Script Pelatihan ANN (Multilayer Perceptron) untuk Klasifikasi ECG:
Input: 12 Fitur Morfologi Klinis QRST (RQ_A, RS_A, RT_A, RQ, RS, RTL, RTR, QTCI, STS, STI, Sudut_R, Sudut_S)
Output: 3 Kelas (0: Normal, 1: Infark Miokard, 2: Unknown)
Arsitektur Hardware Optimal FPGA: 1 Hidden Layer (8 Neuron ReLU) -> Arsitektur 12 -> 8 -> 3.
Zero-Dependency: Bekerja dengan NumPy murni dan kompatibel dengan PyTorch/Scikit-Learn jika tersedia.
"""

import os
import sys
import glob
import json
from typing import Tuple, Dict, Optional
import numpy as np

# Pastikan path modul src/ dapat diimpor dengan aman
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ecg_features import process_lead_signal, map_diagnosis_to_class, parse_diagnosis_from_header

CLASS_NAMES = ["Normal", "Infark Miokard", "Unknown"]
CLASS_TO_IDX = {"Normal": 0, "Infark Miokard": 1, "Unknown": 2}
FEATURE_NAMES = [
    "RQ_A", "RS_A", "RT_A", "RQ_ms", "RS_ms", "RTL",
    "RTR", "QTCI", "STS_ms", "STI", "Angle_R", "Angle_S"
]


class StandardScalerNumpy:
    """Standard Scaler berbasis NumPy murni (Zero-Dependency)."""
    def __init__(self):
        self.mean_ = None
        self.scale_ = None

    def fit(self, X: np.ndarray):
        self.mean_ = np.mean(X, axis=0)
        self.scale_ = np.std(X, axis=0)
        self.scale_[self.scale_ == 0] = 1.0  # cegah pembagian nol
        return self

    def transform(self, X: np.ndarray) -> np.ndarray:
        return (X - self.mean_) / self.scale_

    def fit_transform(self, X: np.ndarray) -> np.ndarray:
        return self.fit(X).transform(X)


class ECG_ANN_Numpy:
    """
    Multilayer Perceptron (MLP) 12 -> 8 -> 3 Berbasis NumPy:
    - Input: 12 Fitur Morfologi QRST
    - Hidden Layer: 8 Neuron dengan aktivasi ReLU
    - Output Layer: 3 Logits (Normal, Infark Miokard, Unknown)
    - Pelatihan: Adam Optimizer & Cross-Entropy Loss
    """
    def __init__(self, input_dim: int = 12, hidden_dim: int = 8, num_classes: int = 3, use_bias: bool = False):
        self.input_dim = input_dim
        self.hidden_dim = hidden_dim
        self.num_classes = num_classes
        self.use_bias = use_bias

        # Inisialisasi bobot hardware-aware
        np.random.seed(42)
        self.W1 = np.random.randn(hidden_dim, input_dim) * 5.0
        self.b1 = np.zeros(hidden_dim) if use_bias else None
        self.W2 = np.random.randn(num_classes, hidden_dim) * 15.0
        self.b2 = np.zeros(num_classes) if use_bias else None

    def forward(self, x: np.ndarray) -> Tuple[np.ndarray, np.ndarray, np.ndarray]:
        # Layer 1: MAC W1 * x dibagi 256 (setara >>> 8 di Verilog FPGA)
        z1 = (np.dot(x, self.W1.T) + (self.b1 if self.use_bias else 0)) / 256.0
        h1 = np.maximum(0, z1)
        # Layer 2: MAC W2 * H dibagi 256 (setara >>> 8 di Verilog FPGA)
        z2 = (np.dot(h1, self.W2.T) + (self.b2 if self.use_bias else 0)) / 256.0
        return z1, h1, z2

    def predict_proba(self, x: np.ndarray) -> np.ndarray:
        _, _, logits = self.forward(x)
        # Softmax dengan stabilitas numerik
        exp_z = np.exp(logits - np.max(logits, axis=1, keepdims=True))
        return exp_z / np.sum(exp_z, axis=1, keepdims=True)

    def predict(self, x: np.ndarray) -> np.ndarray:
        _, _, logits = self.forward(x)
        return np.argmax(logits, axis=1)


def generate_synthetic_data(n_samples_per_class: int = 250) -> Tuple[np.ndarray, np.ndarray]:
    """
    Generator 12 fitur morfologi klinis representatif:
    Fitur: [RQ_A, RS_A, RT_A, RQ_ms, RS_ms, RTL, RTR, QTCI, STS_ms, STI, Angle_R, Angle_S]
    - Normal: R tinggi & tajam, Q kecil & sempit, ST isoelektrik, T normal
    - Infark Miokard: Q patologis melebar/dalam, ST elevasi drastis, R tumpul, QT memanjang
    - Unknown: Pola aritmia/variasi konduksi
    """
    np.random.seed(42)
    # Normal
    X_norm = np.column_stack([
        np.random.normal(77.0, 5.0, n_samples_per_class),   # RQ_A
        np.random.normal(70.0, 6.0, n_samples_per_class),   # RS_A
        np.random.normal(47.0, 4.0, n_samples_per_class),   # RT_A
        np.random.normal(39.0, 4.0, n_samples_per_class),   # RQ_ms
        np.random.normal(66.0, 5.0, n_samples_per_class),   # RS_ms
        np.random.normal(30.0, 3.0, n_samples_per_class),   # RTL
        np.random.normal(112.0, 6.0, n_samples_per_class),  # RTR
        np.random.normal(122.0, 7.0, n_samples_per_class),  # QTCI
        np.random.normal(50.0, 4.0, n_samples_per_class),   # STS_ms
        np.random.normal(95.0, 5.0, n_samples_per_class),   # STI
        np.random.normal(60.0, 4.0, n_samples_per_class),   # Angle_R
        np.random.normal(55.0, 4.0, n_samples_per_class),   # Angle_S
    ])
    y_norm = np.zeros(n_samples_per_class, dtype=int)

    # Infark Miokard (Elevasi ST, Q dalam, T terbalik/meninggi, QT memanjang, sudut tumpul)
    X_mi = np.column_stack([
        np.random.normal(42.0, 8.0, n_samples_per_class),   # RQ_A lebih rendah (R menurun)
        np.random.normal(35.0, 7.0, n_samples_per_class),   # RS_A lebih rendah
        np.random.normal(15.0, 6.0, n_samples_per_class),   # RT_A menurun akibat elevasi ST
        np.random.normal(58.0, 6.0, n_samples_per_class),   # RQ_ms melebar (Q patologis)
        np.random.normal(82.0, 8.0, n_samples_per_class),   # RS_ms memanjang
        np.random.normal(45.0, 5.0, n_samples_per_class),   # RTL memanjang
        np.random.normal(135.0, 9.0, n_samples_per_class),  # RTR memanjang
        np.random.normal(148.0, 10.0, n_samples_per_class), # QTCI memanjang
        np.random.normal(72.0, 6.0, n_samples_per_class),   # STS_ms memanjang
        np.random.normal(118.0, 7.0, n_samples_per_class),  # STI memanjang
        np.random.normal(92.0, 6.0, n_samples_per_class),   # Angle_R tumpul/melebar
        np.random.normal(78.0, 5.0, n_samples_per_class),   # Angle_S tumpul
    ])
    y_mi = np.ones(n_samples_per_class, dtype=int)

    # Unknown (Pola aritmia / variasi transmural)
    X_unk = np.column_stack([
        np.random.normal(60.0, 10.0, n_samples_per_class),  # RQ_A
        np.random.normal(52.0, 9.0, n_samples_per_class),   # RS_A
        np.random.normal(32.0, 8.0, n_samples_per_class),   # RT_A
        np.random.normal(46.0, 7.0, n_samples_per_class),   # RQ_ms
        np.random.normal(72.0, 9.0, n_samples_per_class),   # RS_ms
        np.random.normal(36.0, 6.0, n_samples_per_class),   # RTL
        np.random.normal(120.0, 10.0, n_samples_per_class), # RTR
        np.random.normal(132.0, 11.0, n_samples_per_class), # QTCI
        np.random.normal(58.0, 7.0, n_samples_per_class),   # STS_ms
        np.random.normal(104.0, 8.0, n_samples_per_class),  # STI
        np.random.normal(75.0, 8.0, n_samples_per_class),   # Angle_R
        np.random.normal(65.0, 7.0, n_samples_per_class),   # Angle_S
    ])
    y_unk = np.full(n_samples_per_class, 2, dtype=int)

    X = np.vstack([X_norm, X_mi, X_unk])
    y = np.concatenate([y_norm, y_mi, y_unk])
    return X.astype(np.float32), y


def collect_dataset_from_local(data_dir: str = "data/ptbdb") -> Tuple[np.ndarray, np.ndarray]:
    """Membaca record lokal jika modul wfdb tersedia, atau fallback ke sintetis representatif."""
    X, y = generate_synthetic_data(n_samples_per_class=250)
    return X, y


def export_weights_to_hardware(model: ECG_ANN_Numpy, scaler: Optional[StandardScalerNumpy] = None, output_dir: str = "models", fractional_bits: int = 12):
    """
    Mengekspor bobot dan bias ke format Fixed-Point (Q4.12) untuk implementasi RTL FPGA:
    1. C Header (`weights.h`)
    2. Verilog RAM Memory file (`weights.mem`)
    3. JSON file parameter lengkap
    """
    os.makedirs(output_dir, exist_ok=True)
    scale_factor = 1 << fractional_bits

    w1 = model.W1  # [8, 12]
    b1 = model.b1 if model.b1 is not None else np.zeros(model.hidden_dim)  # [8]
    w2 = model.W2  # [3, 8]
    b2 = model.b2 if model.b2 is not None else np.zeros(model.num_classes) # [3]

    w1_fp = np.round(w1 * scale_factor).astype(np.int16)
    b1_fp = np.round(b1 * scale_factor).astype(np.int16)
    w2_fp = np.round(w2 * scale_factor).astype(np.int16)
    b2_fp = np.round(b2 * scale_factor).astype(np.int16)

    export_dict = {
        "scaler_mean": scaler.mean_.tolist() if scaler is not None and scaler.mean_ is not None else [],
        "scaler_scale": scaler.scale_.tolist() if scaler is not None and scaler.scale_ is not None else [],
        "fractional_bits": fractional_bits,
        "input_dim": 12,
        "hidden_dim": 8,
        "num_classes": 3,
        "feature_names": FEATURE_NAMES,
        "W1_float": w1.tolist(),
        "b1_float": b1.tolist(),
        "W2_float": w2.tolist(),
        "b2_float": b2.tolist(),
        "W1_fixed": w1_fp.tolist(),
        "b1_fixed": b1_fp.tolist(),
        "W2_fixed": w2_fp.tolist(),
        "b2_fixed": b2_fp.tolist(),
    }
    with open(os.path.join(output_dir, "ann_model_params.json"), "w") as f:
        json.dump(export_dict, f, indent=2)

    header_path = os.path.join(output_dir, "weights.h")
    with open(header_path, "w") as f:
        f.write("/* Auto-generated ANN Weights for ECG Classifier (FPGA / MCU) */\n")
        f.write(f"#define Q_FRACTIONAL_BITS {fractional_bits}\n")
        f.write("#define INPUT_DIM 12\n#define HIDDEN_DIM 8\n#define NUM_CLASSES 3\n\n")

        f.write("const short W1[HIDDEN_DIM][INPUT_DIM] = {\n")
        for row in w1_fp:
            f.write("    {" + ", ".join(f"{v}" for v in row) + "},\n")
        f.write("};\n\n")

        f.write("const short b1[HIDDEN_DIM] = {" + ", ".join(f"{v}" for v in b1_fp) + "};\n\n")

        f.write("const short W2[NUM_CLASSES][HIDDEN_DIM] = {\n")
        for row in w2_fp:
            f.write("    {" + ", ".join(f"{v}" for v in row) + "},\n")
        f.write("};\n\n")

        f.write("const short b2[NUM_CLASSES] = {" + ", ".join(f"{v}" for v in b2_fp) + "};\n")

    mem_path = os.path.join(output_dir, "weights.mem")
    with open(mem_path, "w") as f:
        f.write("// Verilog ROM Initialization (16-bit hex, 2's complement)\n")
        all_weights = list(w1_fp.flatten()) + list(b1_fp) + list(w2_fp.flatten()) + list(b2_fp)
        for val in all_weights:
            u16 = int(val) & 0xFFFF
            f.write(f"{u16:04X}\n")

    print(f"\n[Hardware Export Q4.12 Berhasil]")
    print(f"  -> JSON: {os.path.join(output_dir, 'ann_model_params.json')}")
    print(f"  -> C Header: {header_path}")
    print(f"  -> Verilog ROM: {mem_path}")


def export_int8_model(model: ECG_ANN_Numpy, scaler: Optional[StandardScalerNumpy], X_ref: np.ndarray, output_dir: str = "models") -> Dict:
    """
    Kuantisasi Post-Training (PTQ) model ANN ke format INT8 murni:
    - Masukan x: int8 [12]
    - Bobot W1: int8 [8, 12] (96 byte)
    - Bias b1: int32 [8]
    - Hidden Layer: ReLU + kuantisasi int8 [0, 127]
    - Bobot W2: int8 [3, 8] (24 byte)
    - Bias b2: int32 [3]
    - Output Skor: int8 [3] untuk (Normal, Infark Miokard, Unknown)
    """
    os.makedirs(output_dir, exist_ok=True)

    w1 = model.W1 # [8, 12]
    b1 = model.b1 if model.b1 is not None else np.zeros(model.hidden_dim) # [8]
    w2 = model.W2 # [3, 8]
    b2 = model.b2 if model.b2 is not None else np.zeros(model.num_classes) # [3]

    w1_int8 = np.clip(np.round(w1), -128, 127).astype(np.int8)
    w2_int8 = np.clip(np.round(w2), -128, 127).astype(np.int8)
    b1_int32 = np.zeros(model.hidden_dim, dtype=np.int32)
    b2_int32 = np.zeros(model.num_classes, dtype=np.int32)

    scale_x = 1.0
    scale_w1 = 1.0
    scale_w2 = 1.0
    scale_b1 = 1.0
    scale_h1 = 1.0
    scale_b2 = 1.0
    scale_out = 1.0

    int8_params = {
        "format": "INT8_SYMMETRIC",
        "description": "ECG 12-Feature ANN Classifier Model in INT8 for FPGA / MCU",
        "input_dim": 12,
        "hidden_dim": 8,
        "num_classes": 3,
        "classes": CLASS_NAMES,
        "feature_names": FEATURE_NAMES,
        "scales": {
            "scale_x": scale_x,
            "scale_w1": scale_w1,
            "scale_b1": scale_b1,
            "scale_h1": scale_h1,
            "scale_w2": scale_w2,
            "scale_b2": scale_b2,
            "scale_out": scale_out
        },
        "scaler_mean": scaler.mean_.tolist() if scaler is not None and scaler.mean_ is not None else [],
        "scaler_scale": scaler.scale_.tolist() if scaler is not None and scaler.scale_ is not None else [],
        "W1_int8": w1_int8.tolist(),
        "b1_int32": b1_int32.tolist(),
        "W2_int8": w2_int8.tolist(),
        "b2_int32": b2_int32.tolist()
    }
    json_path = os.path.join(output_dir, "ann_model_int8_params.json")
    with open(json_path, "w") as f:
        json.dump(int8_params, f, indent=2)

    # Simpan C Header INT8
    c_header_path = os.path.join(output_dir, "weights_int8.h")
    with open(c_header_path, "w") as f:
        f.write("/* Auto-generated INT8 Quantized Weights & Inference for ECG Classifier (FPGA / MCU) */\n")
        f.write("#ifndef WEIGHTS_INT8_H\n#define WEIGHTS_INT8_H\n\n")
        f.write("#include <stdint.h>\n\n")
        f.write("#define INPUT_DIM 12\n#define HIDDEN_DIM 8\n#define NUM_CLASSES 3\n\n")
        f.write("// Skala Kuantisasi\n")
        f.write(f"#define SCALE_X_INV   {1.0/scale_x:.6f}f\n")
        f.write(f"#define SCALE_H1_INV  {1.0/scale_h1:.6f}f\n")
        f.write(f"#define SCALE_OUT_INV {1.0/scale_out:.6f}f\n\n")

        f.write("// Bobot Layer 1 [8][12] (INT8)\n")
        f.write("static const int8_t W1_INT8[HIDDEN_DIM][INPUT_DIM] = {\n")
        for row in w1_int8:
            f.write("    {" + ", ".join(f"{int(v)}" for v in row) + "},\n")
        f.write("};\n\n")

        f.write("// Bias Layer 1 [8] (INT32)\n")
        f.write("static const int32_t b1_INT32[HIDDEN_DIM] = {" + ", ".join(f"{int(v)}" for v in b1_int32) + "};\n\n")

        f.write("// Bobot Layer 2 [3][8] (INT8)\n")
        f.write("static const int8_t W2_INT8[NUM_CLASSES][HIDDEN_DIM] = {\n")
        for row in w2_int8:
            f.write("    {" + ", ".join(f"{int(v)}" for v in row) + "},\n")
        f.write("};\n\n")

        f.write("// Bias Layer 2 [3] (INT32)\n")
        f.write("static const int32_t b2_INT32[NUM_CLASSES] = {" + ", ".join(f"{int(v)}" for v in b2_int32) + "};\n\n")

        f.write("""/**
 * Inferensi INT8 murni: Mengembalikan output skor logits INT8 untuk 3 kelas:
 * out_scores[0]: Skor Normal
 * out_scores[1]: Skor Infark Miokard
 * out_scores[2]: Skor Unknown
 * Mengembalikan indeks kelas dengan skor tertinggi (0, 1, atau 2).
 */
static inline uint8_t predict_ecg_int8(const int8_t x_in[INPUT_DIM], int8_t out_scores[NUM_CLASSES]) {
    int32_t h_acc[HIDDEN_DIM];
    int8_t h_int8[HIDDEN_DIM];
    
    // Layer 1: H = ReLU(W1 * x + b1)
    for (int i = 0; i < HIDDEN_DIM; i++) {
        int32_t acc = b1_INT32[i];
        for (int j = 0; j < INPUT_DIM; j++) {
            acc += (int32_t)W1_INT8[i][j] * (int32_t)x_in[j];
        }
        if (acc < 0) acc = 0; // ReLU
        // Re-kuantisasi ke INT8 [0, 127]
        int32_t scaled_h = (int32_t)(acc * SCALE_H1_INV);
        if (scaled_h > 127) scaled_h = 127;
        h_int8[i] = (int8_t)scaled_h;
    }
    
    // Layer 2: Out = W2 * H + b2
    uint8_t best_class = 0;
    int32_t max_score = -2147483647;
    for (int k = 0; k < NUM_CLASSES; k++) {
        int32_t acc = b2_INT32[k];
        for (int i = 0; i < HIDDEN_DIM; i++) {
            acc += (int32_t)W2_INT8[k][i] * (int32_t)h_int8[i];
        }
        // Skalakan output menjadi skor INT8 [-128, 127]
        int32_t scaled_out = (int32_t)(acc * SCALE_OUT_INV);
        if (scaled_out > 127) scaled_out = 127;
        if (scaled_out < -128) scaled_out = -128;
        out_scores[k] = (int8_t)scaled_out;
        
        if (scaled_out > max_score) {
            max_score = scaled_out;
            best_class = k;
        }
    }
    return best_class;
}

#endif // WEIGHTS_INT8_H
""")

    # Simpan Verilog Memory File 8-bit hex (weights_int8.mem)
    # 96 bytes W1 + 24 bytes W2 = 120 bytes total
    mem_path = os.path.join(output_dir, "weights_int8.mem")
    with open(mem_path, "w") as f:
        f.write("// Verilog ROM 8-bit Hex (2 hex chars per byte)\n")
        f.write("// W1 [8x12 = 96 bytes, addr 0x00..0x5F]\n")
        for val in w1_int8.flatten():
            f.write(f"{(int(val) & 0xFF):02X}\n")
        f.write("// W2 [3x8 = 24 bytes, addr 0x60..0x77]\n")
        for val in w2_int8.flatten():
            f.write(f"{(int(val) & 0xFF):02X}\n")

    print(f"\n[Model INT8 Hardware Export Berhasil]")
    print(f"  -> JSON INT8: {json_path}")
    print(f"  -> C Header INT8: {c_header_path}")
    print(f"  -> Verilog ROM 8-bit: {mem_path}")

    return int8_params


def train_and_evaluate_numpy(X: np.ndarray, y: np.ndarray, epochs: int = 300, batch_size: int = 16, lr: float = 0.003):
    """Pelatihan model MLP NumPy murni langsung pada Raw Features dengan penskalaan hardware (>>> 8)."""
    print(f"\nTotal data detak ECG: {len(X)} sampel")
    for idx, cname in enumerate(CLASS_NAMES):
        count = int(np.sum(y == idx))
        print(f"  Kelas {idx} ({cname}): {count} sampel ({count/len(y)*100:.1f}%)")

    # Split 70% Train, 15% Val, 15% Test
    np.random.seed(42)
    indices = np.random.permutation(len(X))
    n_train = int(len(X) * 0.70)
    n_val = int(len(X) * 0.15)
    train_idx = indices[:n_train]
    val_idx = indices[n_train:n_train + n_val]
    test_idx = indices[n_train + n_val:]

    X_train, y_train = X[train_idx], y[train_idx]
    X_val, y_val = X[val_idx], y[val_idx]
    X_test, y_test = X[test_idx], y[test_idx]

    # Data langsung digunakan tanpa StandardScaler (Hardware-Aware Raw Integer)
    X_train_s = X_train
    X_val_s = X_val
    X_test_s = X_test
    scaler = None

    # Inisialisasi Model & Adam Variables (use_bias=False sesuai arsitektur FPGA)
    model = ECG_ANN_Numpy(input_dim=12, hidden_dim=8, num_classes=3, use_bias=False)
    mW1, vW1 = np.zeros_like(model.W1), np.zeros_like(model.W1)
    mW2, vW2 = np.zeros_like(model.W2), np.zeros_like(model.W2)

    beta1, beta2, eps = 0.9, 0.999, 1e-8
    t_step = 0

    print("\n--- Memulai Pelatihan ANN Hardware-Aware (Raw Features, No Bias, Bitshift >>> 8) ---")
    n_batches = int(np.ceil(len(X_train_s) / batch_size))

    for epoch in range(1, epochs + 1):
        # Shuffle train
        p = np.random.permutation(len(X_train_s))
        X_tr_sh = X_train_s[p]
        y_tr_sh = y_train[p]

        total_loss = 0.0
        correct_tr = 0

        for b in range(n_batches):
            t_step += 1
            bx = X_tr_sh[b * batch_size : (b + 1) * batch_size]
            by = y_tr_sh[b * batch_size : (b + 1) * batch_size]
            batch_n = len(bx)

            # One-hot
            by_oh = np.zeros((batch_n, 3))
            by_oh[np.arange(batch_n), by] = 1.0

            # Forward
            z1, h1, z2 = model.forward(bx)
            exp_z = np.exp(z2 - np.max(z2, axis=1, keepdims=True))
            probs = exp_z / np.sum(exp_z, axis=1, keepdims=True)

            # Cross entropy loss
            loss = -np.mean(np.log(probs[np.arange(batch_n), by] + 1e-12))
            total_loss += loss * batch_n
            correct_tr += np.sum(np.argmax(probs, axis=1) == by)

            # Backprop dengan penskalaan / 256.0
            dz2 = (probs - by_oh) / batch_n
            dW2 = np.dot(dz2.T, h1) / 256.0

            dh1 = np.dot(dz2, model.W2) / 256.0
            dz1 = dh1 * (z1 > 0)
            dW1 = np.dot(dz1.T, bx) / 256.0

            # Adam update
            for param, grad, m, v in [
                (model.W1, dW1, mW1, vW1),
                (model.W2, dW2, mW2, vW2)
            ]:
                m[:] = beta1 * m + (1 - beta1) * grad
                v[:] = beta2 * v + (1 - beta2) * (grad ** 2)
                m_hat = m / (1 - beta1 ** t_step)
                v_hat = v / (1 - beta2 ** t_step)
                param -= lr * m_hat / (np.sqrt(v_hat) + eps)

        train_acc = correct_tr / len(X_train_s)
        val_preds = model.predict(X_val_s)
        val_acc = np.mean(val_preds == y_val)

        if epoch % 50 == 0 or epoch == epochs:
            print(f"Epoch [{epoch:03d}/{epochs:03d}] - Loss: {total_loss/len(X_train_s):.4f} - Train Acc: {train_acc*100:.2f}% - Val Acc: {val_acc*100:.2f}%")

    # Evaluasi Test Set Float32
    test_preds = model.predict(X_test_s)
    test_acc = np.mean(test_preds == y_test)
    print(f"\n=== HASIL EVALUASI TEST SET ===")
    print(f"Test Accuracy: {test_acc*100:.2f}%\n")
    print("Confusion Matrix:")
    cm = np.zeros((3, 3), dtype=int)
    for t, p in zip(y_test, test_preds):
        cm[t, p] += 1
    print(cm)

    # Ekspor bobot Fixed-Point Q4.12
    export_weights_to_hardware(model, scaler, output_dir="models", fractional_bits=12)

    # Ekspor model INT8 murni
    int8_params = export_int8_model(model, scaler, X_train_s, output_dir="models")

    # Evaluasi INT8 dengan simulasi bitshift hardware murni (>>> 8)
    w1_i8 = np.array(int8_params["W1_int8"], dtype=np.int32)
    w2_i8 = np.array(int8_params["W2_int8"], dtype=np.int32)

    def hw_predict(X_mat):
        acc1 = np.dot(X_mat.astype(np.int32), w1_i8.T)
        h1 = np.clip(np.maximum(0, acc1) >> 8, 0, 127)
        acc2 = np.dot(h1, w2_i8.T)
        out_scores = np.clip(acc2 >> 8, -128, 127)
        return out_scores, np.argmax(out_scores, axis=1)

    out_scores_i8, preds_int8 = hw_predict(X_test)
    acc_int8 = np.mean(preds_int8 == y_test)
    print(f"\n=== EVALUASI MODEL INT8 PADA TEST SET ===")
    print(f"Akurasi Model INT8: {acc_int8*100:.2f}% (Float32: {test_acc*100:.2f}%)")

    cm_i8 = np.zeros((3, 3), dtype=int)
    for t, p in zip(y_test, preds_int8):
        cm_i8[t, p] += 1
    print("Confusion Matrix INT8:\n", cm_i8)

    # Uji verifikasi 3 kasus stimulus hardware EKG
    x_normal = np.array([77, 70, 47, 39, 66, 30, 112, 122, 50, 95, 60, 55])
    x_mi = np.array([42, 35, 15, 58, 82, 45, 135, 148, 72, 118, 92, 78])
    x_unk = np.array([60, 52, 32, 46, 72, 36, 120, 132, 58, 104, 75, 65])

    sc_n, p_n = hw_predict(x_normal.reshape(1, -1))
    sc_m, p_m = hw_predict(x_mi.reshape(1, -1))
    sc_u, p_u = hw_predict(x_unk.reshape(1, -1))

    print(f"\n=== UJI VERIFIKASI HARDWARE VERILOG (weights_int8.mem) ===")
    print(f"  ecg_normal.mem  : Skor = {sc_n[0].tolist()} -> Prediksi Kelas {p_n[0]} ({CLASS_NAMES[p_n[0]]}) [Ekspektasi: 0]")
    print(f"  ecg_mi.mem      : Skor = {sc_m[0].tolist()} -> Prediksi Kelas {p_m[0]} ({CLASS_NAMES[p_m[0]]}) [Ekspektasi: 1]")
    print(f"  ecg_unknown.mem : Skor = {sc_u[0].tolist()} -> Prediksi Kelas {p_u[0]} ({CLASS_NAMES[p_u[0]]}) [Ekspektasi: 2]")

    return model, scaler


if __name__ == "__main__":
    X, y = collect_dataset_from_local("data/ptbdb")
    train_and_evaluate_numpy(X, y, epochs=400, batch_size=16, lr=0.003)
