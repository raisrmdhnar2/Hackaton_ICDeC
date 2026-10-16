# PANDUAN KONSEP SISTEM: AKSELERATOR EKG FPGA UNTUK DETEKSI INFARK MIOKARD
**Proyek:** Indonesia Chip Hackathon Challenge 2026  
**Tim:** DIICES UB  
**Target Utama:** Desain Sirkuit Terpadu Digital (FPGA IP-Core) Pemroses EKG Mandiri Real-Time  

---

## 1. Masalah dan Tujuan Desain
Infark miokard (serangan jantung) akut membutuhkan diagnosis seketika di fase pra-rumah sakit. Solusi portabel berbasis mikrokontroler konvensional mengalami kendala latensi dan *jitter* instruksi perangkat lunak, sementara akselerator AI penuh (1D-CNN) di FPGA sangat boros memori (BRAM) dan blok DSP.

Tujuan proyek ini adalah merancang **akselerator EKG mandiri pada FPGA** yang mengekstraksi fitur gelombang jantung dan menjalankan klasifikasi (Normal, Infark Miokard, Unknown) secara langsung di perangkat keras (*on-chip*) dengan konsumsi gerbang logika yang minimal.

---

## 2. Tiga Pilar Filosofi Hardware (Hardware-Friendly Co-Design)

1. **Pemisahan Jalur Data (Data Path) dan Kendali (Control Path):**
   Deteksi titik morfologi gelombang dikendalikan secara deterministik oleh mesin status berhingga (*Moore FSM*) tanpa siklus instruksi perangkat lunak.
2. **Bebas Modul Pembagi di Silikon (Divider-Free):**
   Seluruh fitur morfologi dihitung dalam format bilangan bulat mentah (*raw integers/fixed-point*). Tidak ada unit pembagi biner (*divider*) yang boros area gerbang logika (LUT).
3. **Penskalaan Normalisasi Terlipat (Weight Folding):**
   FPGA **tidak menjalankan normalisasi Z-score** (tidak membutuhkan buffer penghitung rata-rata, varians, atau akar kuadrat). Penskalaan fitur secara matematis diserap langsung ke dalam bobot dan bias lapisan pertama jaringan syaraf tiruan (MLP) saat model dikompilasi, sehingga inferensi perangkat keras tetap murni perkalian-penjumlahan integer.

---

## 3. Alur Kerja Sistem End-to-End
[ Input Generator ] ──(UART 115.2k)──► [ UART RX ]
│
▼
[ Bandpass Filter ] (1 - 45 Hz)
│
▼
[ Detektor R ]
│ (Pemicu Kontrol)
▼
[ Shift Register ] ──► [ Detektor Q (Mundur) ]
│
▼
[ Detektor S & T (Maju) ]
│
▼
[ Ekstraksi 12 Fitur Mentah ]
(Amplitudo, Durasi, Sudut Vektor)
│
▼
[ On-Chip MLP Core ] (Weight Folded)
│
▼
[ Klasifikasi: Normal / MI / Unknown ]
│
▼
[ GUI PC / Dashboard ] ◄──(UART TX)── [ Output Telemetri ]

### Tahapan Pemrosesan:
* **Tahap 1 - Ingesti Sinyal:** Sinyal EKG disintesis oleh generator sinyal dan dikirim secara serial (UART 115.200 bps) ke FPGA. Modul penerima menggunakan sinkronisasi ganda (double-stage synchronizer) untuk mencegah metastabilitas clock asinkron.
* **Tahap 2 - Penyaringan Digital:** Sinyal mentah dibersihkan dari derau baseline wander dan frekuensi tinggi menggunakan Bandpass Filter (1 Hz – 100 Hz) format fixed-point Q15.
* **Tahap 3 - Deteksi QRST & Ekstraksi Fitur:**
  * **Puncak R:** Dideteksi pertama kali sebagai patokan utama.
  * **Titik Q (Retrospektif):** Sinyal ditunda sementara di dalam Shift Register. Saat puncak R terdeteksi, kontrol FSM melacak mundur ke dalam buffer untuk mengunci lembah gelombang Q.
  * **Titik S dan T:** FSM melanjutkan pelacakan maju untuk menemukan lembah S dan gelombang repolarisasi T.
  * **12 Parameter Fitur:** Dihitung dari selisih register (3 fitur amplitudo relatif terhadap R, 7 fitur interval/durasi waktu, dan 2 fitur sudut geometri lintasan vektor).
* **Tahap 4 - Inferensi Jaringan Syaraf (MLP Core):** Vektor fitur mentah langsung diumpankan ke model Multilayer Perceptron terkuantisasi di dalam FPGA untuk menghasilkan keputusan: Normal, Infark Miokard, atau Unknown.
* **Tahap 5 - Visualisasi Host:** Fitur dan hasil klasifikasi dikirim kembali via UART ke antarmuka GUI pada komputer untuk visualisasi bentuk gelombang dan verifikasi hardware-in-the-loop.

---

## 4. Kaidah Dasar Penulisan Verilog (Instruksi Hardware untuk Antigravity)

* **Pola Moore 3-Always Block:**
  1. Blok sekuensial sinkron untuk state register (`ps <= ns;`).
  2. Blok kombinasional murni untuk transisi state berikutnya (`case (ps)` dengan default `ns = ps;`).
  3. Blok output logic murni yang hanya bergantung pada Present State (`ps`).
* **Aturan Port Output:** Deklarasi port output pada header modul dilarang menggunakan tipe `reg`. Nilai ditampung pada register internal (`reg nama_reg;`) lalu disambungkan ke port fisik menggunakan pernyataan eksplisit `assign nama_o = nama_reg;`.
* **Zero Latch & Eksplisit Bit-Width:** Seluruh percabangan wajib memiliki kondisi default dan seluruh konstanta angka harus memiliki lebar bit yang jelas (contoh: `16'd0`, `2'b00`).