#!/usr/bin/env python3
"""
================================================================================
SCRIPT EKSPOR STIMULUS EKG UNTUK SIMULASI VIVADO FPGA
================================================================================
Proyek : Indonesia Chip Hackathon Challenge 2026 (DIICES UB)
Fungsi : Mengonversi data sinyal EKG klinis PhysioNet PTB Database (format .dat/.hea)
         menjadi berkas memori heksadesimal 16-bit (.mem) yang siap di-load oleh
         Testbench Vivado Simulator menggunakan $readmemh("file.mem", mem).
================================================================================
"""

import os
import argparse
import numpy as np

# Daftar rekaman representatif dari data/ptbdb/
DEFAULT_RECORDS = {
    "normal": {
        "record": "patient104/s0306lre",
        "label": "Normal (Healthy Control)",
        "output_file": "ecg_normal.mem"
    },
    "mi": {
        "record": "patient001/s0010_re",
        "label": "Infark Miokard (Myocardial Infarction)",
        "output_file": "ecg_mi.mem"
    },
    "unknown": {
        "record": "patient118/s0183_re",
        "label": "Unknown (Heart Failure / Non-Target Arrhythmia)",
        "output_file": "ecg_unknown.mem"
    }
}


def read_ptb_record(data_dir: str, record_rel_path: str, lead_idx: int = 1) -> tuple:
    """
    Membaca berkas .hea dan .dat PTB Database langsung menggunakan NumPy
    tanpa memerlukan dependensi pustaka pihak ketiga yang berat (seperti wfdb).
    
    Format PTB PhysioNet:
    - Format 16: Little-endian signed 16-bit integer (<i2)
    - 15 kanal (Kanal 0: Lead I, Kanal 1: Lead II, dsb.)
    - Frekuensi sampling: 1000 Hz
    - Resolusi: 2000 ADC units / mV
    """
    dat_path = os.path.join(data_dir, f"{record_rel_path}.dat")
    hea_path = os.path.join(data_dir, f"{record_rel_path}.hea")

    if not os.path.exists(dat_path) or not os.path.exists(hea_path):
        raise FileNotFoundError(f"Berkas rekaman tidak ditemukan: {dat_path} atau {hea_path}")

    # 1. Parse header (.hea) untuk menentukan jumlah kanal spesifik di file .dat
    with open(hea_path, "r", encoding="utf-8", errors="ignore") as f:
        header_lines = [line.strip().split() for line in f if line.strip() and not line.startswith("#")]

    first_line = header_lines[0]
    record_name = first_line[0]
    fs = int(first_line[2])

    # Hitung kanal khusus yang berada di file .dat (biasanya 12 kanal untuk 12-lead ECG)
    dat_filename = os.path.basename(dat_path)
    dat_channels = [l for l in header_lines[1:] if l[0] == dat_filename or l[0].endswith(".dat")]
    n_channels = len(dat_channels) if len(dat_channels) > 0 else int(first_line[1])

    # 2. Baca biner data (.dat)
    with open(dat_path, "rb") as f:
        raw_buffer = f.read()

    raw_int16 = np.frombuffer(raw_buffer, dtype="<i2")
    n_frames = len(raw_int16) // n_channels
    signals = raw_int16[:n_frames * n_channels].reshape(-1, n_channels)

    # Ambil kanal target (default Lead II = index 1)
    lead_signal = signals[:, lead_idx].astype(np.int32)
    # Pusatkan baseline di sekitar 0 (hilangkan DC offset transduser ADC)
    median_val = int(np.median(lead_signal[:5000]))
    lead_signal_centered = lead_signal - median_val
    return lead_signal_centered, fs, n_channels


def to_hex16(value: int) -> str:
    """
    Mengonversi nilai integer signed 16-bit (-32768 s.d. 32767)
    menjadi representasi heksadesimal two's complement 4-karakter (0000 s.d. FFFF).
    """
    val_clamped = max(-32768, min(32767, int(value)))
    return f"{val_clamped & 0xFFFF:04X}"


def export_record_to_mem(signal: np.ndarray, output_path: str, n_samples: int = 2000, start_offset: int = 0):
    """
    Menyimpan segmen sinyal ke berkas teks .mem format heksadesimal
    untuk dibaca oleh Verilog $readmemh.
    """
    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    
    seg = signal[start_offset:start_offset + n_samples]
    with open(output_path, "w", encoding="utf-8") as f:
        for val in seg:
            f.write(f"{to_hex16(val)}\n")

    print(f"  [OK] Tersimpan: {output_path}")
    print(f"       Jumlah Sampel : {len(seg)}")
    print(f"       Rentang Nilai : Min = {seg.min():+d} (0x{to_hex16(seg.min())}), "
          f"Max = {seg.max():+d} (0x{to_hex16(seg.max())})")


def main():
    parser = argparse.ArgumentParser(description="Ekspor data EKG PTB-DB ke format .mem Vivado Testbench")
    parser.add_argument("--data-dir", default="data/ptbdb", help="Direktori root database PTB")
    parser.add_argument("--out-dir", default="rtl/sim_data", help="Direktori output untuk file .mem")
    parser.add_argument("--samples", type=int, default=2000, help="Jumlah sampel per file (default: 2000 sampel = 2 detik @ 1000 Hz)")
    parser.add_argument("--offset", type=int, default=500, help="Offset awal sampel untuk menghindari artifak inisiasi awal")
    parser.add_argument("--lead", type=int, default=1, help="Indeks lead (0: Lead I, 1: Lead II)")
    args = parser.parse_args()

    print("================================================================================")
    print("           EKSPORTIR STIMULUS EKG KE BERKAS MEMORI VIVADO (.MEM)               ")
    print("================================================================================")
    print(f"Direktori Data   : {args.data_dir}")
    print(f"Direktori Output : {args.out_dir}")
    print(f"Jumlah Sampel    : {args.samples} sampel")
    print(f"Kanal Lead EKG   : Kanal {args.lead} (Lead II)")
    print("--------------------------------------------------------------------------------")

    for cat_key, cat_info in DEFAULT_RECORDS.items():
        print(f"\nMemproses Kategori [{cat_key.upper()}]: {cat_info['label']}")
        rec_path = cat_info["record"]
        out_mem = os.path.join(args.out_dir, cat_info["output_file"])
        
        try:
            signal, fs, n_ch = read_ptb_record(args.data_dir, rec_path, lead_idx=args.lead)
            print(f"  Informasi File: Fs = {fs} Hz, Total Sinyal = {len(signal)} sampel ({len(signal)/fs:.1f} detik)")
            export_record_to_mem(signal, out_mem, n_samples=args.samples, start_offset=args.offset)
        except Exception as e:
            print(f"  [ERROR] Gagal memproses {rec_path}: {e}")

    print("\n--------------------------------------------------------------------------------")
    print("Selesai! Berkas .mem siap digunakan pada Testbench Vivado:")
    print("  1. rtl/sim_data/ecg_normal.mem")
    print("  2. rtl/sim_data/ecg_mi.mem")
    print("  3. rtl/sim_data/ecg_unknown.mem")
    print("================================================================================")


if __name__ == "__main__":
    main()

