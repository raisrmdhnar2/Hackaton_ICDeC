"""
Modul Pemrosesan Sinyal ECG & Ekstraksi 12 Fitur Morfologi Klinis QRST
Sesuai Arsitektur FPGA (feature_extractor_12.v) & Paper PTB Myocardial Infarction 2023.

Fitur yang diekstrak (12 Fitur INT8):
1.  x1: RQ_A  = (R_amp - Q_amp) / 32
2.  x2: RS_A  = (R_amp - S_amp) / 32
3.  x3: RT_A  = (R_amp - T_amp) / 32
4.  x4: RQ    = t_R - t_Q (ms)
5.  x5: RS    = t_S - t_R (ms)
6.  x6: RTL   = (t_Ton - t_R) / 4
7.  x7: RTR   = (t_Toff - t_R) / 4
8.  x8: QTCI  = (t_Toff - t_Q) / 4
9.  x9: STS   = t_Ton - t_Soff (ms)
10. x10: STI  = (t_Toff - t_Soff) / 4
11. x11: ∠R   = Sudut ketajaman puncak R (Q-R-S via LUT/CORDIC)
12. x12: ∠S   = Sudut ketajaman lembah S (R-S-T via LUT/CORDIC)
"""

import numpy as np
try:
    import scipy.signal as signal
    HAS_SCIPY = True
except ImportError:
    HAS_SCIPY = False
import os
from typing import Tuple, List, Dict, Optional


def parse_diagnosis_from_header(header_file: str) -> str:
    """Membaca alasan admisi / diagnosis medis dari komentar di file .hea."""
    if not os.path.exists(header_file):
        return "Unknown"
    with open(header_file, "r", encoding="utf-8", errors="ignore") as f:
        for line in f:
            if "Reason for admission:" in line:
                diag = line.split(":", 1)[1].strip()
                return diag
    return "Unknown"


def map_diagnosis_to_class(diagnosis: str) -> str:
    """Memetakan diagnosis medis ke 3 kelas target: Normal, Infark Miokard, Unknown."""
    d_lower = diagnosis.lower()
    if "healthy" in d_lower or "control" in d_lower:
        return "Normal"
    elif "myocardial infarction" in d_lower or "infarction" in d_lower:
        return "Infark Miokard"
    else:
        return "Unknown"


def bandpass_filter(data: np.ndarray, fs: float = 1000.0, lowcut: float = 0.5, highcut: float = 45.0, order: int = 3) -> np.ndarray:
    """
    Butterworth Bandpass Filter untuk menghilangkan baseline wander (drift frekuensi rendah)
    dan derau frekuensi tinggi (powerline 50/60 Hz & EMG).
    Jika scipy tidak tersedia, menggunakan baseline removal & moving average berbasis numpy.
    """
    if HAS_SCIPY:
        nyq = 0.5 * fs
        low = lowcut / nyq
        high = highcut / nyq
        b, a = signal.butter(order, [low, high], btype='band')
        filtered = signal.filtfilt(b, a, data)
        return filtered
    else:
        # Fallback numpy murni: Baseline wander removal + smoothing
        w_baseline = int(fs * 0.2)
        baseline = np.convolve(data, np.ones(w_baseline)/w_baseline, mode='same')
        detrended = data - baseline
        w_smooth = 5
        filtered = np.convolve(detrended, np.ones(w_smooth)/w_smooth, mode='same')
        return filtered


def detect_r_peaks(ecg_signal: np.ndarray, fs: float = 1000.0) -> np.ndarray:
    """
    Deteksi puncak R (R-peak) terinspirasi Pan-Tompkins:
    1. Diferensiasi (turunan)
    2. Kuadrat amplitudo
    3. Moving window integrator
    4. Deteksi puncak lokal dengan refractory period (~250-300 ms).
    """
    diff = np.diff(ecg_signal, prepend=ecg_signal[0])
    squared = diff ** 2
    
    win_size = int(0.15 * fs)
    kernel = np.ones(win_size) / win_size
    integrated = np.convolve(squared, kernel, mode='same')
    
    threshold = 0.35 * np.max(integrated)
    min_dist = int(0.4 * fs)  # minimal jarak antar R-peak (~400 ms, maks 150 bpm)

    if HAS_SCIPY:
        peaks, _ = signal.find_peaks(integrated, height=threshold, distance=min_dist)
    else:
        # Fallback NumPy murni: cari puncak lokal di atas threshold dengan jarak minimum
        peaks = []
        for i in range(1, len(integrated) - 1):
            if integrated[i] > threshold and integrated[i] > integrated[i - 1] and integrated[i] >= integrated[i + 1]:
                if len(peaks) == 0 or (i - peaks[-1]) >= min_dist:
                    peaks.append(i)
    
    corrected_r_peaks = []
    search_win = int(0.06 * fs)
    for p in peaks:
        left = max(0, p - search_win)
        right = min(len(ecg_signal), p + search_win)
        if right > left:
            true_r = left + np.argmax(ecg_signal[left:right])
            corrected_r_peaks.append(true_r)
            
    return np.array(corrected_r_peaks, dtype=int)


def extract_qrst_fiducials(ecg_signal: np.ndarray, r_peak: int, fs: float = 1000.0) -> Dict[str, int]:
    """
    Menemukan titik fidusial Q, R, S, T, T_on, T_off, dan S_off (titik J)
    untuk sebuah detak jantung (beat).
    """
    # 1. Detektor Q: minimum sebelum R (20 ms s.d. 80 ms sebelum R)
    q_search_start = max(0, r_peak - int(0.08 * fs))
    q_search_end = max(0, r_peak - int(0.01 * fs))
    if q_search_end > q_search_start:
        q_idx = q_search_start + np.argmin(ecg_signal[q_search_start:q_search_end])
    else:
        q_idx = max(0, r_peak - int(0.03 * fs))
        
    # 2. Detektor S: minimum setelah R (15 ms s.d. 90 ms setelah R)
    s_search_start = min(len(ecg_signal), r_peak + int(0.015 * fs))
    s_search_end = min(len(ecg_signal), r_peak + int(0.09 * fs))
    if s_search_end > s_search_start:
        s_idx = s_search_start + np.argmin(ecg_signal[s_search_start:s_search_end])
    else:
        s_idx = min(len(ecg_signal) - 1, r_peak + int(0.03 * fs))
        
    # 3. Titik J / S_offset: saat kurva mulai kembali naik dari lembah S
    s_off_idx = min(len(ecg_signal) - 1, s_idx + int(0.01 * fs))
    for k in range(s_idx, min(len(ecg_signal) - 1, s_idx + int(0.04 * fs))):
        if ecg_signal[k] >= ecg_signal[s_idx] + 0.05 * (ecg_signal[r_peak] - ecg_signal[s_idx]):
            s_off_idx = k
            break
            
    # 4. Detektor T: puncak gelombang T setelah S
    t_search_start = min(len(ecg_signal), s_idx + int(0.08 * fs))
    t_search_end = min(len(ecg_signal), s_idx + int(0.40 * fs))
    if t_search_end > t_search_start:
        window_t = ecg_signal[t_search_start:t_search_end]
        max_t = np.max(window_t)
        min_t = np.min(window_t)
        if abs(max_t) >= abs(min_t):
            t_idx = t_search_start + np.argmax(window_t)
        else:
            t_idx = t_search_start + np.argmin(window_t)
    else:
        t_idx = min(len(ecg_signal) - 1, s_idx + int(0.20 * fs))

    # Baseline isoelektrik (segmen PR sebelum Q)
    pr_start = max(0, q_idx - int(0.08 * fs))
    pr_end = max(0, q_idx - int(0.02 * fs))
    v_iso = np.median(ecg_signal[pr_start:pr_end]) if pr_end > pr_start else ecg_signal[max(0, q_idx - 10)]

    # 5. T_onset: awal kenaikan gelombang T
    t_on_idx = max(s_off_idx + 5, t_idx - int(0.12 * fs))
    for k in range(s_off_idx, t_idx):
        if abs(ecg_signal[k] - v_iso) > 0.15 * abs(ecg_signal[t_idx] - v_iso):
            t_on_idx = k
            break

    # 6. T_offset: titik kembali ke baseline
    t_off_idx = min(len(ecg_signal) - 1, t_idx + int(0.15 * fs))
    for k in range(t_idx, min(len(ecg_signal) - 1, t_idx + int(0.25 * fs))):
        if abs(ecg_signal[k] - v_iso) <= 0.10 * abs(ecg_signal[t_idx] - v_iso):
            t_off_idx = k
            break

    return {
        "Q": int(q_idx),
        "R": int(r_peak),
        "S": int(s_idx),
        "T": int(t_idx),
        "S_off": int(s_off_idx),
        "T_on": int(t_on_idx),
        "T_off": int(t_off_idx),
        "V_iso": float(v_iso)
    }


def compute_12_qrst_features(ecg_signal: np.ndarray, fiducials: Dict[str, int], fs: float = 1000.0) -> np.ndarray:
    """
    Menghitung 12 Fitur Morfologi Klinis INT8 sesuai spesifikasi hardware feature_extractor_12.v:
    x1..x3: Delta Amplitudo (RQ_A, RS_A, RT_A)
    x4..x10: Interval Waktu (RQ, RS, RTL, RTR, QTCI, STS, STI)
    x11..x12: Sudut Geometri Vektor (∠R, ∠S)
    """
    q_i   = fiducials["Q"]
    r_i   = fiducials["R"]
    s_i   = fiducials["S"]
    t_i   = fiducials["T"]
    s_off = fiducials["S_off"]
    t_on  = fiducials["T_on"]
    t_off = fiducials["T_off"]

    # Amplitudo EKG (skala volt atau mV)
    r_amp = ecg_signal[r_i]
    q_amp = ecg_signal[q_i]
    s_amp = ecg_signal[s_i]
    t_amp = ecg_signal[t_i]

    # Durasi dalam milidetik (ms)
    ms_scale = 1000.0 / fs
    dur_rq   = max(0.0, (r_i - q_i) * ms_scale)
    dur_rs   = max(0.0, (s_i - r_i) * ms_scale)
    dur_rtl  = max(0.0, (t_on - r_i) * ms_scale)
    dur_rtr  = max(0.0, (t_off - r_i) * ms_scale)
    dur_qtci = max(0.0, (t_off - q_i) * ms_scale)
    dur_sts  = max(0.0, (t_on - s_off) * ms_scale)
    dur_sti  = max(0.0, (t_off - s_off) * ms_scale)

    diff_rq_a = r_amp - q_amp
    diff_rs_a = r_amp - s_amp
    diff_rt_a = r_amp - t_amp

    # Estimasi Sudut Vektor (Derajat)
    # ∠R: Sudut puncak Q-R-S
    if diff_rs_a > 1.2:
        if (dur_rq + dur_rs) < 70:    angle_r = 25.0
        elif (dur_rq + dur_rs) < 100: angle_r = 35.0
        else:                         angle_r = 50.0
    elif diff_rs_a > 0.6:
        if (dur_rq + dur_rs) < 70:    angle_r = 35.0
        elif (dur_rq + dur_rs) < 100: angle_r = 45.0
        else:                         angle_r = 60.0
    else:
        angle_r = 70.0

    # ∠S: Sudut lembah R-S-T
    if diff_rs_a > 1.0:
        if dur_sti < 120:   angle_s = 30.0
        elif dur_sti < 200: angle_s = 45.0
        else:               angle_s = 55.0
    else:
        angle_s = 65.0

    feats = np.array([
        diff_rq_a,  # x1: RQ_A
        diff_rs_a,  # x2: RS_A
        diff_rt_a,  # x3: RT_A
        dur_rq,     # x4: RQ (ms)
        dur_rs,     # x5: RS (ms)
        dur_rtl,    # x6: RTL (ms)
        dur_rtr,    # x7: RTR (ms)
        dur_qtci,   # x8: QTCI (ms)
        dur_sts,    # x9: STS (ms)
        dur_sti,    # x10: STI (ms)
        angle_r,    # x11: ∠R (derajat)
        angle_s     # x12: ∠S (derajat)
    ], dtype=np.float32)

    return feats


def process_lead_signal(ecg_raw: np.ndarray, fs: float = 1000.0) -> Tuple[np.ndarray, List[Dict[str, int]], np.ndarray]:
    """
    Pipeline lengkap dari sinyal mentah ke 12 fitur morfologi untuk setiap detak:
    1. Filter Bandpass
    2. Deteksi R-peaks
    3. Deteksi titik fidusial Q, R, S, T, S_off, T_on, T_off
    4. Ekstraksi matriks fitur [N_beats, 12]
    """
    filtered = bandpass_filter(ecg_raw, fs=fs)
    r_peaks = detect_r_peaks(filtered, fs=fs)
    
    fiducials_list = []
    features_list = []
    
    for r in r_peaks:
        # Pastikan margin beat cukup di awal dan akhir sinyal
        if r < int(0.2 * fs) or r > len(filtered) - int(0.5 * fs):
            continue
        fid = extract_qrst_fiducials(filtered, r, fs=fs)
        feats = compute_12_qrst_features(filtered, fid, fs=fs)
        fiducials_list.append(fid)
        features_list.append(feats)
        
    features_matrix = np.array(features_list, dtype=np.float32) if features_list else np.empty((0, 12), dtype=np.float32)
    return filtered, fiducials_list, features_matrix
