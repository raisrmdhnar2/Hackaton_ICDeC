#!/usr/bin/env python3
"""
================================================================================
SCRIPT EKSTRAKSI RAW TEST DATASET EKG UNTUK UI GENERATOR & FPGA STREAMING
================================================================================
Proyek : Indonesia Chip Hackathon Challenge 2026 (DIICES UB)
Fungsi : Membaca seluruh data biner (.dat/.hea) PhysioNet PTB Database,
         mengekstrak sinyal mentah (Lead II) dalam format signed 16-bit integer (int16),
         dan menyusunnya ke dalam 4 kelompok:
         1. normal   : Seluruh rekaman pasien uji Normal (Healthy Control)
         2. mi       : Seluruh rekaman pasien uji Infark Miokard (STEMI)
         3. unknown  : Seluruh rekaman pasien uji Unknown (Aritmia / Gagal Jantung)
         4. mixed    : Rangkaian kontinyu (Normal -> MI -> Unknown -> Auto Loop)
         
Output : ui/dataset_test_raw.js (Zero-Dependency Browser Module)
================================================================================
"""

import os
import csv
import json
import numpy as np


def read_ptb_record(data_dir: str, record_rel_path: str, lead_idx: int = 1) -> tuple:
    """Membaca rekaman PTB mentah format little-endian signed 16-bit (<i2)."""
    dat_path = os.path.join(data_dir, f"{record_rel_path}.dat")
    hea_path = os.path.join(data_dir, f"{record_rel_path}.hea")

    if not os.path.exists(dat_path) or not os.path.exists(hea_path):
        raise FileNotFoundError(f"Berkas rekaman tidak ditemukan: {dat_path} atau {hea_path}")

    with open(hea_path, "r", encoding="utf-8", errors="ignore") as f:
        header_lines = [l.strip().split() for l in f if l.strip() and not l.startswith("#")]

    first_line = header_lines[0]
    fs = int(first_line[2])

    dat_filename = os.path.basename(dat_path)
    dat_channels = [l for l in header_lines[1:] if l[0] == dat_filename or l[0].endswith(".dat")]
    n_channels = len(dat_channels) if len(dat_channels) > 0 else int(first_line[1])

    with open(dat_path, "rb") as f:
        raw_buffer = f.read()

    raw_int16 = np.frombuffer(raw_buffer, dtype="<i2")
    n_frames = len(raw_int16) // n_channels
    signals = raw_int16[:n_frames * n_channels].reshape(-1, n_channels)

    lead_signal = signals[:, lead_idx].astype(np.int32)
    return lead_signal, fs


def main():
    data_dir = "data/ptbdb"
    manifest_path = os.path.join(data_dir, "records_manifest.csv")
    out_js_path = "ui/dataset_test_raw.js"

    print("================================================================================")
    print("      EKSTRAKTOR DATASET TEST MENTAH EKG UNTUK UI & STREAMING FPGA             ")
    print("================================================================================")

    if not os.path.exists(manifest_path):
        raise FileNotFoundError(f"Manifest tidak ditemukan di {manifest_path}")

    with open(manifest_path, "r", encoding="utf-8") as f:
        records = list(csv.DictReader(f))

    by_class = {
        "Normal": [],
        "Infark Miokard": [],
        "Unknown": []
    }

    for r in records:
        lbl = r["label"]
        if lbl in by_class:
            by_class[lbl].append(r)

    samples_per_record = 2000
    start_offset = 500

    dataset_dict = {
        "metadata": {
            "title": "PTB Diagnostic Database - Raw ECG Test Set (16-bit signed)",
            "fs": 1000,
            "samples_per_record": samples_per_record,
            "classes": ["Normal", "Infark Miokard", "Unknown"]
        },
        "normal": {
            "samples": [],
            "records": []
        },
        "mi": {
            "samples": [],
            "records": []
        },
        "unknown": {
            "samples": [],
            "records": []
        },
        "mixed": {
            "samples": [],
            "segments": []
        }
    }

    class_key_map = {
        "Normal": "normal",
        "Infark Miokard": "mi",
        "Unknown": "unknown"
    }

    # 1. Ekstraksi Tiap Kategori
    for cname, rec_list in by_class.items():
        ckey = class_key_map[cname]
        print(f"\n--- Memproses Kategori: {cname.upper()} ({len(rec_list)} Rekaman Pasien) ---")
        
        current_offset = 0
        for r in rec_list:
            rec_id = r["record"]
            diag = r["raw_diagnosis"]
            sig, fs = read_ptb_record(data_dir, rec_id, lead_idx=1)
            
            # Ambil segmen sampel
            seg = sig[start_offset:start_offset + samples_per_record]
            
            # Baseline centering sederhana (menghilangkan DC offset transduser)
            med = int(np.median(seg[:500]))
            seg_centered = seg - med
            seg_int = [int(v) for v in seg_centered]

            start_idx = len(dataset_dict[ckey]["samples"])
            dataset_dict[ckey]["samples"].extend(seg_int)
            end_idx = len(dataset_dict[ckey]["samples"])

            dataset_dict[ckey]["records"].append({
                "record": rec_id,
                "diagnosis": diag,
                "start": start_idx,
                "end": end_idx
            })
            print(f"  [+] {rec_id:20s} : {len(seg_int)} sampel | Min={min(seg_int):+5d}, Max={max(seg_int):+5d}")

        print(f"  Total sampel {cname}: {len(dataset_dict[ckey]['samples'])} sampel")

    # 2. Susun Sekuens Campuran (Mixed Stream: Normal -> MI -> Unknown)
    print("\n--- Menyusun Sekuens Campuran (Mixed Stream) ---")
    norm_samples = dataset_dict["normal"]["samples"]
    mi_samples = dataset_dict["mi"]["samples"]
    unk_samples = dataset_dict["unknown"]["samples"]

    mixed_samples = []
    
    # Segmen 1: Normal
    seg1_start = len(mixed_samples)
    mixed_samples.extend(norm_samples)
    seg1_end = len(mixed_samples)
    dataset_dict["mixed"]["segments"].append({
        "classId": 0,
        "name": "Normal",
        "description": "Normal Sinus Rhythm (Pasien Kontrol Sehat)",
        "start": seg1_start,
        "end": seg1_end
    })

    # Segmen 2: Infark Miokard
    seg2_start = len(mixed_samples)
    mixed_samples.extend(mi_samples)
    seg2_end = len(mixed_samples)
    dataset_dict["mixed"]["segments"].append({
        "classId": 1,
        "name": "Infark Miokard",
        "description": "STEMI (ST-Elevation Myocardial Infarction)",
        "start": seg2_start,
        "end": seg2_end
    })

    # Segmen 3: Unknown
    seg3_start = len(mixed_samples)
    mixed_samples.extend(unk_samples)
    seg3_end = len(mixed_samples)
    dataset_dict["mixed"]["segments"].append({
        "classId": 2,
        "name": "Unknown",
        "description": "Heart Failure / Non-Target Dysrhythmia",
        "start": seg3_start,
        "end": seg3_end
    })

    dataset_dict["mixed"]["samples"] = mixed_samples
    print(f"  Total sampel Mixed Stream: {len(mixed_samples)} sampel (Normal: {len(norm_samples)}, MI: {len(mi_samples)}, Unknown: {len(unk_samples)})")

    # 3. Tulis ke ui/dataset_test_raw.js
    os.makedirs(os.path.dirname(out_js_path), exist_ok=True)
    with open(out_js_path, "w", encoding="utf-8") as f:
        f.write("/**\n")
        f.write(" * DATASET TEST MENTAH EKG (PHYSIONET PTB DIAGNOSTIC DATABASE)\n")
        f.write(" * Format: 16-bit Signed Integer (Raw ADC Counts)\n")
        f.write(" * Auto-generated by src/build_test_dataset_raw.py\n")
        f.write(" */\n")
        f.write("const RAW_ECG_DATASETS = ")
        json.dump(dataset_dict, f, separators=(',', ':'))
        f.write(";\n")

    file_size_kb = os.path.getsize(out_js_path) / 1024
    print(f"\n[SUKSES] File dataset berhasil diekspor ke: {out_js_path} ({file_size_kb:.1f} KB)")
    print("================================================================================")


if __name__ == "__main__":
    main()

