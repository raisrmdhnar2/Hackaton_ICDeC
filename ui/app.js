/**
 * ==============================================================================
 * ENGINE JAVASCRIPT: DIICES ECG MONITOR & FPGA CONTROLLER
 * Proyek: Indonesia Chip Hackathon Challenge 2026 (DIICES UB)
 * Fitur:
 * 1. Player Data Klinis Asli PhysioNet PTB Database (Lead II Raw Signed INT16)
 * 2. Infinite Loop Auto-Replay (Mulus memutar kembali dari awal saat data habis)
 * 3. Dynamic Tracking pada Mode Mixed (Normal -> MI -> Unknown)
 * 4. Dual Oscilloscope Canvas:
 *    - Main Hero Canvas (Left, 8 Cols): FPGA Output (Filtered ECG + Colored QRST Markers)
 *    - Mini Canvas (Top-Right, 4 Cols): Raw Sensor Input Stream (Unfiltered Transducer)
 * 5. Emulasi Dummy Filter Hardware FPGA (DC-Blocker IIR + 21-Tap Symmetrical FIR + QRST FSM)
 * 6. Native Web Serial API untuk streaming UART hardware fisik FPGA
 * ==============================================================================
 */

// Inisialisasi ikon Lucide
lucide.createIcons();

// ==============================================================================
// 1. ENGINE SLIDING PILL / SEGMENTED CONTROLS
// ==============================================================================
function slideIndicator(trackId, gliderId, activeBtn) {
  const track = document.getElementById(trackId);
  const glider = document.getElementById(gliderId);
  if (!track || !glider || !activeBtn) return;

  const trackRect = track.getBoundingClientRect();
  const btnRect = activeBtn.getBoundingClientRect();

  const left = btnRect.left - trackRect.left;
  const width = btnRect.width;

  glider.style.left = `${left}px`;
  glider.style.width = `${width}px`;
}

function initAllGliders() {
  const gainButtons = document.querySelectorAll('#gainSegmentTrack button');
  if (gainButtons.length > 1) {
    slideIndicator('gainSegmentTrack', 'gainGlider', gainButtons[1]); // Default 1.0x
  }
  slideIndicator('anomSegmentTrack', 'anomGlider', document.getElementById('btnAnomNormal'));
  slideIndicator('classSegmentTrack', 'classGlider', document.getElementById('btnClass0'));
}

window.addEventListener('load', () => setTimeout(initAllGliders, 150));
window.addEventListener('resize', initAllGliders);

// ==============================================================================
// 2. STATE GLOBAL CONTROLLER
// ==============================================================================
let isConnected = false;
let isStreamingRunning = true;
let isPaused = false;
let audioEnabled = true;

let currentAnomaly = 'normal'; // 'normal', 'mi', 'unknown', 'mixed'
let currentGain = 1.0;

// Web Serial References
let serialPort = null;
let serialReader = null;
let serialWriter = null;

// Audio Context (Sintesis Beep Medis QRS)
let audioCtx = null;
function playBeep() {
  if (!audioEnabled || isPaused) return;
  try {
    if (!audioCtx) audioCtx = new (window.AudioContext || window.webkitAudioContext)();
    const osc = audioCtx.createOscillator();
    const gainNode = audioCtx.createGain();
    osc.type = "sine";
    osc.frequency.setValueAtTime(880, audioCtx.currentTime);
    gainNode.gain.setValueAtTime(0.08, audioCtx.currentTime);
    gainNode.gain.exponentialRampToValueAtTime(0.001, audioCtx.currentTime + 0.08);
    osc.connect(gainNode);
    gainNode.connect(audioCtx.destination);
    osc.start();
    osc.stop(audioCtx.currentTime + 0.08);
  } catch (e) {
    console.warn("Audio error:", e);
  }
}

// ==============================================================================
// 3. CANVAS OSCILLOSCOPE DENGAN MEDICAL GRID & QRST FIDUCIAL MARKERS
// ==============================================================================
// Output Canvas (Hero Card Utama - 900x260)
const outputCanvas = document.getElementById("outputCanvas");
const outputCtx = outputCanvas ? outputCanvas.getContext("2d") : null;

// Raw Input Canvas (Mini Card Top-Right - 450x125)
const rawInputCanvas = document.getElementById("rawInputCanvas");
const rawCtx = rawInputCanvas ? rawInputCanvas.getContext("2d") : null;

// Buffer Titik Tampilan
const MAX_OUTPUT_POINTS = 600; // ~2.4 detik tampilan sweep
const MAX_RAW_POINTS = 300;    // ~1.2 detik tampilan sweep

let outputBuffer = new Array(MAX_OUTPUT_POINTS).fill(null).map(() => ({ val: 0, marker: null }));
let rawBuffer = new Array(MAX_RAW_POINTS).fill(0);

let sampleCount = 0;
let rPeakCount = 0;
let lastPeakTime = 0;
let runningRPeakAvg = 1000;
let bpmSmoothed = 75;

// Fungsi Grid Medis Standar (25 mm/s)
function drawMedicalGrid(ctx, w, h) {
  ctx.fillStyle = "#020617";
  ctx.fillRect(0, 0, w, h);

  // Grid Kecil (Minor 15px)
  ctx.strokeStyle = "rgba(16, 185, 129, 0.08)";
  ctx.lineWidth = 1;
  ctx.beginPath();
  for (let x = 0; x < w; x += 15) { ctx.moveTo(x, 0); ctx.lineTo(x, h); }
  for (let y = 0; y < h; y += 15) { ctx.moveTo(0, y); ctx.lineTo(w, y); }
  ctx.stroke();

  // Grid Besar (Major 75px)
  ctx.strokeStyle = "rgba(16, 185, 129, 0.20)";
  ctx.beginPath();
  for (let x = 0; x < w; x += 75) { ctx.moveTo(x, 0); ctx.lineTo(x, h); }
  for (let y = 0; y < h; y += 75) { ctx.moveTo(0, y); ctx.lineTo(w, y); }
  ctx.stroke();
}

function renderCanvases() {
  // ----------------------------------------------------------------------------
  // A. RENDER OUTPUT CANVAS (TERFILTER + TITIK-TITIK QRST BERWARNA)
  // ----------------------------------------------------------------------------
  if (outputCanvas && outputCtx) {
    const ow = outputCanvas.width;
    const oh = outputCanvas.height;
    drawMedicalGrid(outputCtx, ow, oh);

    // Garis Isoelektrik Tengah (Baseline 0V)
    outputCtx.strokeStyle = "rgba(255, 255, 255, 0.16)";
    outputCtx.setLineDash([4, 4]);
    outputCtx.beginPath();
    outputCtx.moveTo(0, oh / 2);
    outputCtx.lineTo(ow, oh / 2);
    outputCtx.stroke();
    outputCtx.setLineDash([]);

    // 1. Gambar Trace Sinyal Terfilter EKG (Warna Emerald Hijau Neon)
    outputCtx.strokeStyle = "#00ff88";
    outputCtx.shadowColor = "#00ff88";
    outputCtx.shadowBlur = 8;
    outputCtx.lineWidth = 2.2;
    outputCtx.beginPath();

    const oStep = ow / (MAX_OUTPUT_POINTS - 1);
    for (let i = 0; i < MAX_OUTPUT_POINTS; i++) {
      const val = outputBuffer[i].val;
      const norm = val / 2400.0;
      const y = (oh / 2) - (norm * (oh * 0.42) * currentGain);
      const x = i * oStep;
      if (i === 0) outputCtx.moveTo(x, y);
      else outputCtx.lineTo(x, y);
    }
    outputCtx.stroke();
    outputCtx.shadowBlur = 0;

    // 2. Gambar Titik-Titik Fidusial QRST Berwarna Sesuai Legenda
    for (let i = 0; i < MAX_OUTPUT_POINTS; i++) {
      const marker = outputBuffer[i].marker;
      if (!marker) continue;

      const val = outputBuffer[i].val;
      const norm = val / 2400.0;
      const y = (oh / 2) - (norm * (oh * 0.42) * currentGain);
      const x = i * oStep;

      let color = "#ef4444";
      let radius = 5;
      let textY = y - 13;

      if (marker === 'Q') {
        color = "#06b6d4"; // Cyan
        radius = 4.5;
        textY = y + 16;   // Di bawah lembah Q
      } else if (marker === 'R') {
        color = "#ef4444"; // Red / Rose
        radius = 5.5;
        textY = y - 14;   // Di atas puncak R
      } else if (marker === 'S') {
        color = "#c084fc"; // Purple
        radius = 4.5;
        textY = y + 16;   // Di bawah lembah S
      } else if (marker === 'T') {
        color = "#f59e0b"; // Amber / Orange
        radius = 4.5;
        textY = y - 13;   // Di atas puncak gelombang T
      }

      // Halo berpendar (Glowing outer ring)
      outputCtx.beginPath();
      outputCtx.arc(x, y, radius + 3, 0, Math.PI * 2);
      outputCtx.fillStyle = color + "40";
      outputCtx.fill();

      // Titik Fidusial Solid
      outputCtx.beginPath();
      outputCtx.arc(x, y, radius, 0, Math.PI * 2);
      outputCtx.fillStyle = color;
      outputCtx.shadowColor = color;
      outputCtx.shadowBlur = 8;
      outputCtx.fill();
      outputCtx.shadowBlur = 0;

      // Label Teks Huruf ("Q", "R", "S", "T")
      outputCtx.font = "bold 11px 'JetBrains Mono', monospace";
      outputCtx.textAlign = "center";
      outputCtx.textBaseline = "middle";

      // Chip latar gelap di belakang huruf agar terbaca jelas melewati grid
      outputCtx.fillStyle = "rgba(2, 6, 23, 0.75)";
      outputCtx.fillRect(x - 7, textY - 7, 14, 14);

      outputCtx.fillStyle = color;
      outputCtx.fillText(marker, x, textY);
    }
  }

  // ----------------------------------------------------------------------------
  // B. RENDER RAW SENSOR INPUT CANVAS (GELOMBANG MENTAH SEBELUM FILTER FPGA)
  // ----------------------------------------------------------------------------
  if (rawInputCanvas && rawCtx) {
    const rw = rawInputCanvas.width;
    const rh = rawInputCanvas.height;

    rawCtx.fillStyle = "#020617";
    rawCtx.fillRect(0, 0, rw, rh);

    // Grid Halus Sky Blue
    rawCtx.strokeStyle = "rgba(56, 189, 248, 0.08)";
    rawCtx.lineWidth = 1;
    rawCtx.beginPath();
    for (let x = 0; x < rw; x += 15) { rawCtx.moveTo(x, 0); rawCtx.lineTo(x, rh); }
    for (let y = 0; y < rh; y += 15) { rawCtx.moveTo(0, y); rawCtx.lineTo(rw, y); }
    rawCtx.stroke();

    // Garis Tengah Isoelektrik
    rawCtx.strokeStyle = "rgba(255, 255, 255, 0.15)";
    rawCtx.setLineDash([3, 3]);
    rawCtx.beginPath();
    rawCtx.moveTo(0, rh / 2);
    rawCtx.lineTo(rw, rh / 2);
    rawCtx.stroke();
    rawCtx.setLineDash([]);

    // Plot Gelombang EKG Mentah Langsung dari Dataset Sensor
    rawCtx.strokeStyle = "#38bdf8";
    rawCtx.shadowColor = "#38bdf8";
    rawCtx.shadowBlur = 6;
    rawCtx.lineWidth = 1.8;
    rawCtx.beginPath();

    const rStep = rw / (MAX_RAW_POINTS - 1);
    for (let i = 0; i < MAX_RAW_POINTS; i++) {
      const rawVal = rawBuffer[i];
      const rNorm = rawVal / 2500.0;
      const y = (rh / 2) - (rNorm * (rh * 0.40) * currentGain);
      const x = i * rStep;
      if (i === 0) rawCtx.moveTo(x, y);
      else rawCtx.lineTo(x, y);
    }
    rawCtx.stroke();
    rawCtx.shadowBlur = 0;
  }

  requestAnimationFrame(renderCanvases);
}
requestAnimationFrame(renderCanvases);

// ==============================================================================
// 4. EMULATOR DUMMY FILTER HARDWARE FPGA (DC-BLOCKER + 21-TAP FIR)
//    Mencerminkan Arsitektur Verilog ecg_bandpass_filter.v
// ==============================================================================
let prevRawSample = 0;
let hpfAcc = 0;
const FIR_COEFFS = [1, 3, 7, 14, 27, 44, 63, 83, 100, 112, 116, 112, 100, 83, 63, 44, 27, 14, 7, 3, 1];
let firTaps = new Array(21).fill(0);

function emulateFpgaFilter(rawSample) {
  // Tahap 1: DC-Blocker IIR 1-Pole (~0.5 Hz)
  // y_hpf[n] = x[n] - x[n-1] + y_hpf[n-1] - (y_hpf[n-1] >>> 9)
  const diff = rawSample - prevRawSample;
  prevRawSample = rawSample;
  hpfAcc = hpfAcc + diff - Math.floor(hpfAcc / 512);

  // Tahap 2: 21-Tap Linear Phase Symmetrical FIR (~45 Hz LPF)
  firTaps.unshift(hpfAcc);
  firTaps.pop();

  let sum = 0;
  for (let i = 0; i < 21; i++) {
    sum += FIR_COEFFS[i] * firTaps[i];
  }
  const filtered = Math.round(sum / 1024);
  return filtered;
}

// ==============================================================================
// 5. DATA BUFFER PUSHER & DETEKTOR REAL-TIME TITIK FIDUSIAL QRST
// ==============================================================================
let lastRPeakStep = -999;
let totalSteps = 0;

function pushProcessedSamples(rawSample, filteredSample) {
  if (isPaused) return;

  // 1. Masukkan ke buffer input mentah (Mini Canvas)
  rawBuffer.shift();
  rawBuffer.push(rawSample);

  // 2. Masukkan ke buffer output terfilter (Main Canvas)
  outputBuffer.shift();
  outputBuffer.push({ val: filteredSample, marker: null });

  totalSteps++;
  sampleCount++;
  const scText = document.getElementById("sampleCountText");
  if (scText) scText.innerText = "SAMPLES: " + sampleCount;

  // 3. Deteksi Morfologi QRST Berbasis Sliding Window
  // Kita amati titik kandidat pada cand = MAX_OUTPUT_POINTS - 75
  // Memberikan lookahead waktu ~300 ms untuk menyelesaikan gelombang S dan T
  const cand = MAX_OUTPUT_POINTS - 75;
  const candVal = outputBuffer[cand].val;

  // Threshold adaptif melacak rerata puncak R (Dual-Threshold FPGA)
  const adaptiveThreshold = Math.max(240, runningRPeakAvg * 0.48);

  if (candVal > adaptiveThreshold) {
    let isLocalMax = true;
    for (let offset = -12; offset <= 12; offset++) {
      if (outputBuffer[cand + offset].val > candVal) {
        isLocalMax = false;
        break;
      }
    }

    if (isLocalMax && (totalSteps - lastRPeakStep) >= 65) {
      // PERIODE REFRAKTORI TERPENUHI -> PUNCAK R TERKONFIRMASI!
      const rrSteps = totalSteps - lastRPeakStep;
      lastRPeakStep = totalSteps;
      rPeakCount++;
      runningRPeakAvg = runningRPeakAvg * 0.8 + candVal * 0.2;

      // Update UI Counter R-Peak
      const rValElem = document.getElementById('rPeakVal');
      if (rValElem) rValElem.innerText = rPeakCount;

      // Hitung Heart Rate (BPM)
      const now = Date.now();
      if (lastPeakTime > 0) {
        const deltaMs = now - lastPeakTime;
        const instantBpm = Math.round(60000 / deltaMs);
        if (instantBpm >= 45 && instantBpm <= 180) {
          bpmSmoothed = Math.round(bpmSmoothed * 0.7 + instantBpm * 0.3);
          const bpmElem = document.getElementById("bpmVal");
          if (bpmElem && !isConnected) bpmElem.innerText = bpmSmoothed;
        }
      }
      lastPeakTime = now;
      playBeep();

      // Tandai Titik R
      outputBuffer[cand].marker = 'R';

      // 4. Cari Lembah Q (Minimum lokal sebelum R: 16 ms s.d. 80 ms sebelum R)
      let minQVal = Infinity;
      let minQIdx = cand - 8;
      for (let o = 4; o <= 22; o++) {
        const idx = cand - o;
        if (outputBuffer[idx] && outputBuffer[idx].val < minQVal) {
          minQVal = outputBuffer[idx].val;
          minQIdx = idx;
        }
      }
      if (outputBuffer[minQIdx]) outputBuffer[minQIdx].marker = 'Q';

      // 5. Cari Lembah S (Minimum lokal setelah R: 16 ms s.d. 80 ms setelah R)
      let minSVal = Infinity;
      let minSIdx = cand + 8;
      for (let o = 4; o <= 22; o++) {
        const idx = cand + o;
        if (outputBuffer[idx] && outputBuffer[idx].val < minSVal) {
          minSVal = outputBuffer[idx].val;
          minSIdx = idx;
        }
      }
      if (outputBuffer[minSIdx]) outputBuffer[minSIdx].marker = 'S';

      // 6. Cari Puncak Gelombang T (Maksimum setelah S: 60 ms s.d. 260 ms setelah S)
      let maxTVal = -Infinity;
      let maxTIdx = minSIdx + 25;
      const tEnd = Math.min(MAX_OUTPUT_POINTS - 5, cand + 65);
      for (let idx = minSIdx + 12; idx <= tEnd; idx++) {
        if (outputBuffer[idx] && outputBuffer[idx].val > maxTVal) {
          maxTVal = outputBuffer[idx].val;
          maxTIdx = idx;
        }
      }
      if (outputBuffer[maxTIdx]) outputBuffer[maxTIdx].marker = 'T';
    }
  }
}

// ==============================================================================
// 6. KLASIFIKASI & INTERAKTIF DIAGNOSIS UI
// ==============================================================================
const resultBox = document.getElementById("classResultContainer");
const resultTitle = document.getElementById("classResultTitle");
const resultDesc = document.getElementById("classResultDesc");
const confVal = document.getElementById("confidenceVal");
const bpmVal = document.getElementById("bpmVal");
const classTag = document.getElementById("classTagId");

function setClassification(classId, btnElem = null) {
  if (!btnElem) {
    const btnMap = [
      document.getElementById('btnClass0'),
      document.getElementById('btnClass1'),
      document.getElementById('btnClass2')
    ];
    btnElem = btnMap[classId];
  }

  // Geser capsule class indicator
  slideIndicator('classSegmentTrack', 'classGlider', btnElem);

  // Reset warna tombol
  ['btnClass0', 'btnClass1', 'btnClass2'].forEach(id => {
    const b = document.getElementById(id);
    if (b) {
      b.classList.remove('text-white');
      b.classList.add('text-slate-600');
    }
  });
  if (btnElem) {
    btnElem.classList.remove('text-slate-600');
    btnElem.classList.add('text-white');
  }

  if (classId === 0) {
    // NORMAL
    if (classTag) {
      classTag.innerText = "CLASS 0";
      classTag.className = "text-[10px] font-mono text-emerald-600 font-bold";
    }
    if (resultBox) resultBox.className = "my-3 bg-white rounded-[22px] p-4 text-center shadow-sm border-2 border-emerald-500 transition-all";
    if (resultTitle) {
      resultTitle.innerText = "NORMAL";
      resultTitle.className = "text-2xl font-display font-black text-emerald-600 tracking-tight my-1 uppercase";
    }
    if (resultDesc) resultDesc.innerText = "Normal Sinus Rhythm • Segmen ST isoelektrik stabil tanpa elevasi patologis.";
    if (confVal) {
      confVal.innerText = "99.4%";
      confVal.className = "text-2xl font-display font-black text-emerald-600";
    }
    if (bpmVal && !isConnected) bpmVal.innerText = "75";
  } else if (classId === 1) {
    // INFARK MIOKARD
    if (classTag) {
      classTag.innerText = "CLASS 1";
      classTag.className = "text-[10px] font-mono text-rose-600 font-bold";
    }
    if (resultBox) resultBox.className = "my-3 bg-white rounded-[22px] p-4 text-center shadow-sm border-2 border-rose-500 transition-all";
    if (resultTitle) {
      resultTitle.innerText = "INFARK MIOKARD";
      resultTitle.className = "text-2xl font-display font-black text-rose-600 tracking-tight my-1 uppercase";
    }
    if (resultDesc) resultDesc.innerText = "STEMI (ST-Elevation Myocardial Infarction) • Elevasi segmen ST patologis khas infark.";
    if (confVal) {
      confVal.innerText = "98.7%";
      confVal.className = "text-2xl font-display font-black text-rose-600";
    }
    if (bpmVal && !isConnected) bpmVal.innerText = "82";
  } else {
    // UNKNOWN
    if (classTag) {
      classTag.innerText = "CLASS 2";
      classTag.className = "text-[10px] font-mono text-amber-600 font-bold";
    }
    if (resultBox) resultBox.className = "my-3 bg-white rounded-[22px] p-4 text-center shadow-sm border-2 border-amber-500 transition-all";
    if (resultTitle) {
      resultTitle.innerText = "UNKNOWN";
      resultTitle.className = "text-2xl font-display font-black text-amber-600 tracking-tight my-1 uppercase";
    }
    if (resultDesc) resultDesc.innerText = "Heart Failure / Dysrhythmia • Variasi morfologi komplek QRS non-target.";
    if (confVal) {
      confVal.innerText = "88.5%";
      confVal.className = "text-2xl font-display font-black text-amber-600";
    }
    if (bpmVal && !isConnected) bpmVal.innerText = "64";
  }
}

window.forceClass = function(id, btn) {
  setClassification(id, btn);
  const modes = ['normal', 'mi', 'unknown'];
  const anomBtns = [
    document.getElementById('btnAnomNormal'),
    document.getElementById('btnAnomMI'),
    document.getElementById('btnAnomUnknown')
  ];
  if (anomBtns[id]) setAnomaly(modes[id], anomBtns[id]);
};

// ==============================================================================
// 7. MESIN PEMUTAR DATASET MENTAH (SEAMLESS INFINITE LOOP & AUTO-REPLAY)
// ==============================================================================
let playheadIndex = 0;
let loopCount = 1;

function getActiveData() {
  if (typeof RAW_ECG_DATASETS === 'undefined') return { samples: [], info: null };
  if (currentAnomaly === 'normal') return { samples: RAW_ECG_DATASETS.normal.samples, info: RAW_ECG_DATASETS.normal.records };
  if (currentAnomaly === 'mi') return { samples: RAW_ECG_DATASETS.mi.samples, info: RAW_ECG_DATASETS.mi.records };
  if (currentAnomaly === 'unknown') return { samples: RAW_ECG_DATASETS.unknown.samples, info: RAW_ECG_DATASETS.unknown.records };
  if (currentAnomaly === 'mixed') return { samples: RAW_ECG_DATASETS.mixed.samples, info: RAW_ECG_DATASETS.mixed.segments };
  return { samples: [], info: null };
}

function updatePlaybackStatusUI(totalLen) {
  const statusElem = document.getElementById("datasetProgressTag");
  if (statusElem) {
    statusElem.innerText = `POS: ${playheadIndex} / ${totalLen} • LOOP #${loopCount}`;
  }
}

// ==============================================================================
// 7. HIGH-PRECISION 1.0 MS STREAMING ENGINE (1000 Hz REAL-TIME PACING)
//    Mengirim tepat 1 sampel (4-byte: [0xAA, MSB, LSB, 0x55]) setiap 1 ms ke FPGA
//    Menggunakan Web Worker Blob agar bebas throttling latar belakang browser
// ==============================================================================
function processOneSample() {
  if (!isStreamingRunning) return;

  const dataObj = getActiveData();
  const samples = dataObj.samples;
  if (!samples || samples.length === 0) return;

  const rawVal = samples[playheadIndex];

  // Deteksi transisi segmen otomatis pada mode Mixed
  if (currentAnomaly === 'mixed' && RAW_ECG_DATASETS.mixed) {
    const segs = RAW_ECG_DATASETS.mixed.segments;
    for (let seg of segs) {
      if (playheadIndex >= seg.start && playheadIndex < seg.end) {
        setClassification(seg.classId);
        const segTag = document.getElementById("mixedSegmentTag");
        if (segTag) segTag.innerText = `SEGMEN: ${seg.name.toUpperCase()}`;
        break;
      }
    }
  }

  // Lewatkan ke filter emulasi jika offline
  const filteredVal = emulateFpgaFilter(rawVal);

  // KIRIM TEPAT 1 SAMPEL SETIAP 1.0 MS KE PORT SERIAL FPGA
  if (isConnected && serialWriter) {
    try {
      const u16 = rawVal & 0xFFFF;
      serialWriter.write(new Uint8Array([0xAA, (u16 >> 8) & 0xFF, u16 & 0xFF, 0x55])).catch(() => {});
    } catch (e) {}
  }

  // Decimation 4x (1000 Hz -> 250 Hz) untuk tampilan oscilloscope yang stabil
  if (playheadIndex % 4 === 0) {
    if (!isConnected) {
      // Mode Simulator / Emulasi Offline
      pushProcessedSamples(rawVal, filteredVal);
    } else {
      // Saat terhubung FPGA, mini canvas tetap menampilkan input raw yang dikirim
      rawBuffer.shift();
      rawBuffer.push(rawVal);
    }
  }

  // Majukan Playhead
  playheadIndex++;
  if (playheadIndex >= samples.length) {
    playheadIndex = 0;
    loopCount++;
    console.log(`[LOOP] Dataset ${currentAnomaly.toUpperCase()} selesai. Memutar ulang Loop #${loopCount}...`);
  }

  if (playheadIndex % 100 === 0) {
    updatePlaybackStatusUI(samples.length);
  }
}

// Inisialisasi Timer Worker 1.0 ms
let timerWorker = null;
try {
  const workerBlob = new Blob([`
    let timer = null;
    self.onmessage = function(e) {
      if (e.data === 'start') {
        if (timer) clearInterval(timer);
        timer = setInterval(() => {
          self.postMessage('tick');
        }, 1);
      } else if (e.data === 'stop') {
        if (timer) clearInterval(timer);
        timer = null;
      }
    };
  `], { type: 'application/javascript' });
  const workerUrl = URL.createObjectURL(workerBlob);
  timerWorker = new Worker(workerUrl);
  timerWorker.onmessage = function(e) {
    if (e.data === 'tick') {
      processOneSample();
    }
  };
  timerWorker.postMessage('start');
  console.log(">> [UI] Web Worker 1.0 ms (1000 Hz) Precision Pacer berhasil diaktifkan!");
} catch (err) {
  console.warn(">> [UI] Web Worker gagal, beralih ke interval fallback:", err);
  setInterval(processOneSample, 1);
}

// ==============================================================================
// 8. INTERACTIVE BUTTON DISPATCHERS
// ==============================================================================
window.setAnomaly = function(type, btnElem) {
  currentAnomaly = type;
  playheadIndex = 0; // Reset playhead ke awal kategori baru
  loopCount = 1;

  slideIndicator('anomSegmentTrack', 'anomGlider', btnElem);

  document.querySelectorAll('#anomSegmentTrack button').forEach(b => {
    b.classList.remove('text-slate-950');
    b.classList.add('text-white/80');
  });
  btnElem.classList.remove('text-white/80');
  btnElem.classList.add('text-slate-950');

  const mixedTag = document.getElementById("mixedSegmentTag");
  if (type === 'normal') {
    if (mixedTag) mixedTag.innerText = "";
    setClassification(0);
  } else if (type === 'mi') {
    if (mixedTag) mixedTag.innerText = "";
    setClassification(1);
  } else if (type === 'unknown') {
    if (mixedTag) mixedTag.innerText = "";
    setClassification(2);
  } else if (type === 'mixed') {
    if (mixedTag) mixedTag.innerText = "SEGMEN: NORMAL";
    setClassification(0);
  }
};

window.setGain = function(gain, btnElem) {
  currentGain = gain;
  slideIndicator('gainSegmentTrack', 'gainGlider', btnElem);

  document.querySelectorAll('#gainSegmentTrack button').forEach(b => {
    b.classList.remove('text-slate-950');
    b.classList.add('text-white');
  });
  btnElem.classList.remove('text-white');
  btnElem.classList.add('text-slate-950');
};

window.toggleAudio = function() {
  audioEnabled = !audioEnabled;
  const audioBtn = document.getElementById("audioToggleBtn");
  const audioIcon = document.getElementById("audioIcon");
  const audioText = document.getElementById("audioText");
  if (audioEnabled) {
    if (audioBtn) audioBtn.className = "flex items-center gap-1.5 px-3 py-1 rounded-lg bg-emerald-500/20 text-emerald-300 border border-emerald-500/30 text-[11px] font-bold active:scale-95 transition";
    if (audioIcon) audioIcon.setAttribute("data-lucide", "volume-2");
    if (audioText) audioText.innerText = "BEEP ON";
  } else {
    if (audioBtn) audioBtn.className = "flex items-center gap-1.5 px-3 py-1 rounded-lg bg-black/30 text-white/50 border border-white/10 text-[11px] font-bold active:scale-95 transition";
    if (audioIcon) audioIcon.setAttribute("data-lucide", "volume-x");
    if (audioText) audioText.innerText = "MUTE";
  }
  lucide.createIcons();
};

window.togglePause = function() {
  isPaused = !isPaused;
  const pauseBtn = document.getElementById("pauseToggleBtn");
  const pauseIcon = document.getElementById("pauseIcon");
  const pauseText = document.getElementById("pauseText");
  if (isPaused) {
    if (pauseBtn) pauseBtn.className = "flex items-center gap-1.5 px-3 py-1 rounded-lg bg-amber-500/20 text-amber-300 border border-amber-500/30 text-[11px] font-bold active:scale-95 transition";
    if (pauseIcon) pauseIcon.setAttribute("data-lucide", "play");
    if (pauseText) pauseText.innerText = "RESUME";
  } else {
    if (pauseBtn) pauseBtn.className = "flex items-center gap-1.5 px-3 py-1 rounded-lg bg-black/30 hover:bg-black/50 border border-white/10 text-white text-[11px] font-bold active:scale-95 transition";
    if (pauseIcon) pauseIcon.setAttribute("data-lucide", "pause");
    if (pauseText) pauseText.innerText = "FREEZE";
  }
  lucide.createIcons();
};

window.toggleStreamRunning = async function() {
  isStreamingRunning = !isStreamingRunning;
  const btn = document.getElementById("btnStreamCtrl");
  const text = document.getElementById("streamCtrlText");
  const icon = document.getElementById("streamCtrlIcon");
  if (isStreamingRunning) {
    if (timerWorker) timerWorker.postMessage('start');
    if (btn) btn.className = "flex items-center gap-2 bg-emerald-600 hover:bg-emerald-500 text-white px-4 py-2.5 rounded-full text-xs font-extrabold uppercase shadow-md transition-all active:scale-95";
    if (text) text.innerText = "STREAM: RUNNING";
    if (icon) icon.setAttribute("data-lucide", "play");
  } else {
    if (timerWorker) timerWorker.postMessage('stop');
    if (btn) btn.className = "flex items-center gap-2 bg-rose-600 hover:bg-rose-500 text-white px-4 py-2.5 rounded-full text-xs font-extrabold uppercase shadow-md transition-all active:scale-95";
    if (text) text.innerText = "STREAM: STOPPED";
    if (icon) icon.setAttribute("data-lucide", "square");
  }
  lucide.createIcons();
};

window.clearWaveform = function() {
  outputBuffer = new Array(MAX_OUTPUT_POINTS).fill(null).map(() => ({ val: 0, marker: null }));
  rawBuffer.fill(0);
  sampleCount = 0;
  rPeakCount = 0;
  playheadIndex = 0;
  loopCount = 1;
  const scText = document.getElementById("sampleCountText");
  if (scText) scText.innerText = "SAMPLES: 0";
  const rValElem = document.getElementById('rPeakVal');
  if (rValElem) rValElem.innerText = "0";
};

// ==============================================================================
// 9. NATIVE CHROME WEB SERIAL API (KONEKSI HARDWARE FPGA)
// ==============================================================================
window.toggleWebSerialConnection = async function() {
  if (!("serial" in navigator)) {
    alert("Web Serial API membutuhkan Google Chrome atau Microsoft Edge.\nBuka file ini menggunakan Chrome atau Edge untuk menghubungkan ke FPGA.");
    return;
  }

  const btnConnectCom = document.getElementById("btnConnectCom");
  const comBtnText = document.getElementById("comBtnText");
  const comIcon = document.getElementById("comIcon");
  const connLed = document.getElementById("connLed");
  const connText = document.getElementById("connText");
  const footerPortText = document.getElementById("footerPortText");
  const outputStreamBadge = document.getElementById("outputStreamBadge");

  if (isConnected) {
    try {
      if (serialWriter) {
        serialWriter.releaseLock();
        serialWriter = null;
      }
      if (serialReader) {
        await serialReader.cancel();
        serialReader = null;
      }
      if (serialPort) {
        await serialPort.close();
        serialPort = null;
      }
    } catch (e) {
      console.warn("Disconnect:", e);
    }

    isConnected = false;
    if (btnConnectCom) btnConnectCom.className = "flex items-center gap-2 bg-[#0a52dd] hover:bg-[#0840ad] text-white px-5 py-2.5 rounded-full text-xs font-extrabold tracking-wide uppercase shadow-md transition-all active:scale-95";
    if (comBtnText) comBtnText.innerText = "CONNECT FPGA";
    if (comIcon) comIcon.setAttribute("data-lucide", "plug");
    if (connLed) connLed.className = "w-2.5 h-2.5 rounded-full bg-slate-400";
    if (connText) connText.innerText = "SIMULATOR ACTIVE";
    if (footerPortText) footerPortText.innerText = "Port: Web Serial (OFFLINE)";
    if (outputStreamBadge) outputStreamBadge.innerText = "LIVE FILTERED STREAM (EMULATED FPGA)";
    lucide.createIcons();
    return;
  }

  try {
    serialPort = await navigator.serial.requestPort();
    await serialPort.open({ baudRate: 115200 });

    isConnected = true;
    if (btnConnectCom) btnConnectCom.className = "flex items-center gap-2 bg-rose-600 hover:bg-rose-500 text-white px-5 py-2.5 rounded-full text-xs font-extrabold tracking-wide uppercase shadow-md transition-all active:scale-95";
    if (comBtnText) comBtnText.innerText = "DISCONNECT";
    if (comIcon) comIcon.setAttribute("data-lucide", "power");
    if (connLed) connLed.className = "w-2.5 h-2.5 rounded-full bg-emerald-400 animate-pulse";
    if (connText) connText.innerText = "FPGA CONNECTED (115.2k)";
    if (footerPortText) footerPortText.innerText = "Port: Web Serial UART @ 115,200 bps (CONNECTED)";
    if (outputStreamBadge) outputStreamBadge.innerText = "LIVE FILTERED STREAM (FPGA HARDWARE)";
    lucide.createIcons();

    serialWriter = serialPort.writable.getWriter();
    readSerialLoop();
  } catch (err) {
    if (err.name !== "NotFoundError") {
      alert("Gagal membuka port FPGA:\n" + err.message);
    }
  }
};

async function readSerialLoop() {
  let rxBuf = [];
  let prevHwMarker = 0;
  let hwSampleDecimator = 0;
  let pendingHwMarker = null;

  const reader = serialPort.readable.getReader();
  serialReader = reader;

  try {
    while (isConnected) {
      const { value, done } = await reader.read();
      if (done) break;
      if (value) {
        for (let i = 0; i < value.length; i++) {
          rxBuf.push(value[i]);
          if (rxBuf.length > 64) rxBuf.shift();

          // Format Paket RX FPGA: [0xAA] [ECG_H] [ECG_L] [MARKER] [CONF] [CLASS] [BPM] [0x55] (8 byte)
          if (rxBuf.length >= 8) {
            if (rxBuf[0] === 0xAA && rxBuf[7] === 0x55) {
              const uEcg = (rxBuf[1] << 8) | rxBuf[2];
              // Konversi signed 16-bit
              const fpgaFilteredEcg = uEcg >= 32768 ? uEcg - 65536 : uEcg;
              const detMarker = rxBuf[3]; // QRST marker (1: Q, 2: R, 3: S, 4: T)
              const hwConf = rxBuf[4];    // Confidence %
              const classId = rxBuf[5];   // 0: Normal, 1: MI, 2: Unknown
              const hwBpm = rxBuf[6];     // Heart Rate BPM

              // 1. Tangkap pulsa event marker dari FPGA (1: Q, 2: R, 3: S, 4: T)
              if (detMarker === 1) {
                // FPGA mendeteksi lembah Q (retrospektif pada buffer sebelum R)
                let minQIdx = outputBuffer.length - 1;
                let minQVal = Infinity;
                for (let k = 2; k <= 22; k++) {
                  const idx = outputBuffer.length - 1 - k;
                  if (idx >= 0 && outputBuffer[idx].val < minQVal) {
                    minQVal = outputBuffer[idx].val;
                    minQIdx = idx;
                  }
                }
                if (outputBuffer[minQIdx]) outputBuffer[minQIdx].marker = 'Q';
              } else if (detMarker === 2) {
                pendingHwMarker = 'R';
                rPeakCount++;
                const rValElem = document.getElementById('rPeakVal');
                if (rValElem) rValElem.innerText = rPeakCount;
                playBeep();
              } else if (detMarker === 3) {
                pendingHwMarker = 'S';
              } else if (detMarker === 4) {
                pendingHwMarker = 'T';
              }

              // 2. Decimation 4x (1000 Hz FPGA -> 250 Hz Canvas)
              // Agar skala waktu sweep speed persis sama dengan mode simulator (2.4 detik / 600 titik)
              hwSampleDecimator++;
              if (hwSampleDecimator >= 4) {
                hwSampleDecimator = 0;
                outputBuffer.shift();
                outputBuffer.push({ val: fpgaFilteredEcg, marker: pendingHwMarker });
                pendingHwMarker = null;

                sampleCount += 4;
                const scText = document.getElementById("sampleCountText");
                if (scText) scText.innerText = "SAMPLES: " + sampleCount;
              }

              // 3. Update Status Telemetri Diagnosis Real-Time dari FPGA
              if (hwBpm > 0 && bpmVal) bpmVal.innerText = hwBpm;
              if (hwConf > 0 && confVal) confVal.innerText = hwConf + "%";
              setClassification(classId);

              // Konsumsi tepat 8 byte frame ini
              rxBuf.splice(0, 8);
            } else {
              // Jika byte terdepan bukan 0xAA atau framing salah, buang 1 byte untuk mencari 0xAA berikutnya
              rxBuf.shift();
            }
          }
        }
      }
    }
  } catch (err) {
    console.warn("Serial loop exit:", err);
  } finally {
    try { reader.releaseLock(); } catch (e) {}
  }
}
