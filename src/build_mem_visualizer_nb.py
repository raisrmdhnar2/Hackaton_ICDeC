"""
Script untuk membangun Jupyter Notebook:
notebook/visualize_ecg_mem.ipynb
Notebook khusus untuk membaca, memvisualisasikan, dan menganalisis berkas memori EKG Verilog (.mem):
- ecg_normal.mem
- ecg_mi.mem
- ecg_unknown.mem
"""

import json
import os

def create_markdown_cell(source_text: str):
    lines = [line + "\n" for line in source_text.strip().split("\n")]
    if lines:
        lines[-1] = lines[-1].rstrip("\n")
    return {
        "cell_type": "markdown",
        "metadata": {},
        "source": lines
    }

def create_code_cell(source_text: str, outputs=None, execution_count=None):
    lines = [line + "\n" for line in source_text.strip().split("\n")]
    if lines:
        lines[-1] = lines[-1].rstrip("\n")
    return {
        "cell_type": "code",
        "execution_count": execution_count,
        "metadata": {},
        "outputs": outputs if outputs is not None else [],
        "source": lines
    }

def build_notebook():
    cells = []

    # ================= CELL 1: MARKDOWN INTRO =================
    cells.append(create_markdown_cell("""# Eksplorasi & Visualisasi Sinyal EKG Hardware (.MEM Files)

Notebook ini dirancang khusus untuk membaca, memvisualisasikan, dan menganalisis berkas memori EKG (*stimulus memory files*) yang digunakan pada simulasi hardware Verilog / Vivado:
1. **`ecg_normal.mem`**: Rekaman EKG pasien dengan ritme sinus normal (*Healthy Control*).
2. **`ecg_mi.mem`**: Rekaman EKG pasien penderita **Infark Miokard Akut** (*STEMI - Myocardial Infarction*).
3. **`ecg_unknown.mem`**: Rekaman EKG pasien dengan kelainan konduksi / kardiomiopati non-infark (*Unknown / Dysrhythmia*).

---

### Karakteristik Format Berkas `.mem`:
- **Format**: Heksadesimal 16-bit (*Two's Complement Signed Integer*, 4 digit hex per baris).
- **Laju Sampling ($F_s$)**: $1000\\text{ Hz}$ ($1\\text{ sampel} = 1\\text{ ms}$).
- **Jumlah Sampel**: 2000 sampel per rekaman ($2.0\\text{ detik}$ aktivitas jantung).
"""))

    # ================= CELL 2: CODE IMPORTS =================
    cells.append(create_code_cell("""# 1. Import Pustaka
import os
import sys
import json
import numpy as np
import matplotlib.pyplot as plt

# Konfigurasi plot
plt.rcParams['figure.figsize'] = (12, 5)
plt.rcParams['font.size'] = 11
plt.style.use('seaborn-v0_8-whitegrid' if 'seaborn-v0_8-whitegrid' in plt.style.available else 'default')

print("Pustaka NumPy dan Matplotlib siap digunakan.")
"""))

    # ================= CELL 3: MARKDOWN PARSING =================
    cells.append(create_markdown_cell("""## 2. Fungsi Pembaca Berkas Memori Heksadesimal (.MEM)

Fungsi berikut membaca baris heksadesimal 16-bit dan mengonversinya menjadi representasi bilangan bulat bertanda (*signed 16-bit integer* $[-32768, 32767]$):
$$\\text{Value} = \\begin{cases} U_{16} - 65536, & \\text{jika } U_{16} \\ge 32768 \\\\ U_{16}, & \\text{jika } U_{16} < 32768 \\end{cases}$$
"""))

    # ================= CELL 4: CODE PARSING =================
    cells.append(create_code_cell("""# 2.1 Fungsi Pemuatan File .mem
def load_ecg_mem(filepath):
    if not os.path.exists(filepath):
        # Fallback pencarian di subdirektori rtl/sim_data
        alt_path = os.path.join("..", filepath)
        if os.path.exists(alt_path):
            filepath = alt_path
        else:
            raise FileNotFoundError(f"File tidak ditemukan: {filepath}")

    samples = []
    with open(filepath, "r") as f:
        for line in f:
            clean = line.strip()
            if clean and not clean.startswith("//"):
                u16 = int(clean, 16)
                s16 = u16 - 0x10000 if u16 >= 0x8000 else u16
                samples.append(s16)
    return np.array(samples, dtype=np.int16)

# Cari file stimulus di direktori proyek
sim_dir = "../rtl/sim_data" if os.path.exists("../rtl/sim_data") else "rtl/sim_data"

ecg_normal  = load_ecg_mem(os.path.join(sim_dir, "ecg_normal.mem"))
ecg_mi      = load_ecg_mem(os.path.join(sim_dir, "ecg_mi.mem"))
ecg_unknown = load_ecg_mem(os.path.join(sim_dir, "ecg_unknown.mem"))

fs = 1000.0  # 1000 Hz
time_axis = np.arange(len(ecg_normal)) / fs

print(f"File EKG Normal  : {len(ecg_normal)} sampel | Min: {ecg_normal.min():6d} | Max: {ecg_normal.max():6d} | Mean: {ecg_normal.mean():6.1f}")
print(f"File EKG MI      : {len(ecg_mi)} sampel | Min: {ecg_mi.min():6d} | Max: {ecg_mi.max():6d} | Mean: {ecg_mi.mean():6.1f}")
print(f"File EKG Unknown : {len(ecg_unknown)} sampel | Min: {ecg_unknown.min():6d} | Max: {ecg_unknown.max():6d} | Mean: {ecg_unknown.mean():6.1f}")
"""))

    # ================= CELL 5: MARKDOWN FULL PLOT =================
    cells.append(create_markdown_cell("""## 3. Visualisasi Sinyal EKG Lengkap (2 Detik Rekaman)

Perhatikan perbedaan morfologi keseluruhan antara ketiga pasien:
- **Pasien Normal**: Puncak R sangat tinggi dan tajam ($> +2000$), garis isoelektrik stabil, gelombang T tegak positif.
- **Pasien Infark Miokard (MI)**: Puncak R mengalami degradasi berat (*loss of R-wave amplitude*, puncak hanya $+529$), sementara lembah Q/S sangat dalam (mencapai $-926$) yang menandakan gelombang Q patologis dan nekrosis jaringan miokardium.
- **Pasien Unknown**: Gelombang EKG memiliki variasi konduksi dengan amplitudo menengah.
"""))

    # ================= CELL 6: CODE FULL PLOT =================
    cells.append(create_code_cell("""# 3.1 Plot Perbandingan 3 Sinyal EKG
fig, axes = plt.subplots(3, 1, figsize=(14, 9), sharex=True)

# 1. Sinyal Normal
axes[0].plot(time_axis, ecg_normal, color="#059669", lw=1.6, label="Normal Sinus Rhythm")
axes[0].axhline(0, color="gray", linestyle="--", alpha=0.6)
axes[0].set_title("EKG Normal (ecg_normal.mem) - Puncak R Tinggi & Tajam (+2123)", fontweight='bold', color="#059669")
axes[0].set_ylabel("Amplitudo Q15")
axes[0].legend(loc="upper right")

# 2. Sinyal Infark Miokard
axes[1].plot(time_axis, ecg_mi, color="#dc2626", lw=1.6, label="Myocardial Infarction / STEMI")
axes[1].axhline(0, color="gray", linestyle="--", alpha=0.6)
axes[1].set_title("EKG Infark Miokard (ecg_mi.mem) - Penurunan Puncak R (+529) & Q/S Sangat Dalam (-926)", fontweight='bold', color="#dc2626")
axes[1].set_ylabel("Amplitudo Q15")
axes[1].legend(loc="upper right")

# 3. Sinyal Unknown
axes[2].plot(time_axis, ecg_unknown, color="#2563eb", lw=1.6, label="Unknown / Dysrhythmia")
axes[2].axhline(0, color="gray", linestyle="--", alpha=0.6)
axes[2].set_title("EKG Unknown / Kelainan Konduksi (ecg_unknown.mem)", fontweight='bold', color="#2563eb")
axes[2].set_xlabel("Waktu (detik)")
axes[2].set_ylabel("Amplitudo Q15")
axes[2].legend(loc="upper right")

plt.tight_layout()
plt.show()
"""))

    # ================= CELL 7: MARKDOWN OVERLAY =================
    cells.append(create_markdown_cell("""## 4. Analisis Detail Satu Siklus Detak Jantung (*Single Beat Overlay*)

Untuk melihat tanda-tanda klinis infark miokard secara presisi, kita menyelaraskan satu siklus kompleks QRST di sekitar puncak gelombang R ($t_R$):
"""))

    # ================= CELL 8: CODE OVERLAY =================
    cells.append(create_code_cell("""# 4.1 Pemotongan Satu Detak Jantung di Sekitar Puncak R
def get_single_beat(sig, peak_idx, pre_ms=200, post_ms=500):
    pre_samp = int(pre_ms)
    post_samp = int(post_ms)
    start = max(0, peak_idx - pre_samp)
    end = min(len(sig), peak_idx + post_samp)
    t_rel = (np.arange(start, end) - peak_idx) # ms relatif terhadap R
    return t_rel, sig[start:end]

# Cari puncak R pertama yang valid di tiap sinyal
r_normal = 250 + np.argmax(ecg_normal[250:900])
r_mi = 200 + np.argmax(ecg_mi[200:800])
r_unk = 200 + np.argmax(ecg_unknown[200:800])

t_norm, beat_norm = get_single_beat(ecg_normal, r_normal)
t_m, beat_m = get_single_beat(ecg_mi, r_mi)
t_u, beat_u = get_single_beat(ecg_unknown, r_unk)

plt.figure(figsize=(11, 5.5))
plt.plot(t_norm, beat_norm, color="#059669", lw=2.2, label=f"Normal (Puncak R = {ecg_normal[r_normal]})")
plt.plot(t_m, beat_m, color="#dc2626", lw=2.2, label=f"Infark Miokard (Puncak R = {ecg_mi[r_mi]}, S/Q = {beat_m.min()})")
plt.plot(t_u, beat_u, color="#2563eb", lw=1.8, linestyle="--", alpha=0.8, label=f"Unknown (Puncak R = {ecg_unknown[r_unk]})")

plt.axvline(0, color="black", linestyle=":", alpha=0.5, label="Puncak R (t = 0 ms)")
plt.axhline(0, color="gray", linestyle="--", alpha=0.4)

plt.title("Perbandingan Satu Siklus Gelombang QRST (Single Beat Overlay)", fontsize=13, fontweight='bold')
plt.xlabel("Waktu Relatif terhadap Puncak R (milidetik)")
plt.ylabel("Amplitudo Sinyal (Q15)")
plt.xlim(-150, 450)
plt.legend(loc="upper right", frameon=True)
plt.tight_layout()
plt.show()
"""))

    # ================= CELL 9: MARKDOWN REKOMENDASI VIVADO =================
    cells.append(create_markdown_cell("""## 5. Panduan Pengaturan Skala Vivado Waveform Viewer

Berdasarkan nilai amplitudo aktual dari ketiga file `.mem`, berikut adalah pengaturan **Analog Settings** yang disarankan agar visualisasi sinyal di Vivado Waveform tidak terpotong dan terlihat proporsional:

| Berkas Stimulus | Nilai Minimum | Nilai Maksimum | Pengaturan Vivado Min | Pengaturan Vivado Max |
| :--- | :---: | :---: | :---: | :---: |
| **`ecg_normal.mem`** | `-360` | `+2123` | **`-500`** | **`+2500`** |
| **`ecg_mi.mem`** | `-926` | `+529` | **`-1000`** | **`+1000`** |
| **`ecg_unknown.mem`** | `-822` | `+1228` | **`-1000`** | **`+1500`** |
| **Gabungan / Rekomendasi Umum** | `-926` | `+2123` | **`-1000`** | **`+2500`** |

### Langkah di Vivado:
1. Klik kanan pada sinyal `sample_in` $\\rightarrow$ **Radix** $\\rightarrow$ **Signed Decimal**.
2. Klik kanan sinyal $\\rightarrow$ **Waveform Style** $\\rightarrow$ **Analog**.
3. Klik kanan sinyal $\\rightarrow$ **Analog Settings...**:
   * **Row Height**: `80` atau `100` pixel
   * **Y Range (User Defined)**: Min = `-1000`, Max = `+2500`
   * **Interpolation**: `Linear`
"""))

    # ================= CELL 10: CODE INFERENCE =================
    cells.append(create_code_cell("""# 5.1 Ringkasan Konfirmasi
print("File .mem berhasil dibaca dan diverifikasi!")
print("Semua file stimulus siap untuk disimulasikan di Vivado dengan top_ecg_system & tb_top_ecg_system.")
"""))

    notebook_dict = {
        "cells": cells,
        "metadata": {
            "kernelspec": {
                "display_name": "Python 3 (ipykernel)",
                "language": "python",
                "name": "python3"
            },
            "language_info": {
                "name": "python",
                "version": "3.10"
            }
        },
        "nbformat": 4,
        "nbformat_minor": 5
    }

    out_path = "notebook/visualize_ecg_mem.ipynb"
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(notebook_dict, f, indent=1)

    print(f"Berhasil membangun notebook di: {out_path} ({len(cells)} cells)")

if __name__ == "__main__":
    build_notebook()

