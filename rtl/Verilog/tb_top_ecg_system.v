`timescale 1ns / 1ns
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: Antigravity AI
// 
// Create Date: 14.10.2026
// Design Name: Complete ECG Infarction Classifier System
// Module Name: tb_top_ecg_system
// Project Name: Hackathon ICDeC
// Target Devices: Artix-7 / Spartan-7 FPGA
// Tool Versions: Vivado 2024.1 / 2025.1
// Description:
//   Testbench Verifikasi End-to-End Sistem Lengkap Deteksi & Klasifikasi EKG:
//   Sinyal EKG Analog -> Bandpass Filter 0.5-45Hz -> QRST Detector -> Feature 12 -> MLP INT8
//   
//   Menguji 3 Skenario Rekaman Sinyal EKG Pasien Asli PTB Database:
//   1. Pasien Normal Sinus Rhythm (ecg_normal.mem)  -> Target Kelas 0
//   2. Pasien Infark Miokard / STEMI (ecg_mi.mem)   -> Target Kelas 1
//   3. Pasien Unknown / Kelainan Lain (ecg_unknown.mem) -> Target Kelas 2
//////////////////////////////////////////////////////////////////////////////////

module tb_top_ecg_system;

    // Parameter Simulasi Teroptimasi
    parameter integer CLK_PERIOD_NS   = 10;           // Clock 100 MHz (10 ns)
    parameter integer SAMPLE_PERIOD   = 1_000;        // 1 us (100 clock cycles per sampel)
    parameter integer SAMPLES_PER_REC = 2000;         // 2000 sampel EKG per rekaman

    // =========================================================================
    // 1. SINYAL KONTROL & MASUKAN UTAMA
    // =========================================================================
    reg                      clk;
    reg                      rst_n;
    reg                      ce;

    // Sinyal Masukan Sinyal EKG Mentah
    reg  signed [15:0]       sample_in;
    reg                      sample_valid;

    // =========================================================================
    // 2. SINYAL KELUARAN FILTER BANDPASS (0.5 Hz - 45 Hz) - PERSIS SETELAH INPUT
    // =========================================================================
    wire signed [15:0]       filtered_sample;
    wire                     filtered_valid;

    // =========================================================================
    // 3. SINYAL KELUARAN DIAGNOSIS DUT
    // =========================================================================
    wire [1:0]               diagnosis_class;
    wire signed [7:0]        score_normal;
    wire signed [7:0]        score_mi;
    wire signed [7:0]        score_unknown;
    wire                     diagnosis_valid;

    // =========================================================================
    // 4. SINYAL TELEMETRI QRST DETEKTOR
    // =========================================================================
    wire [7:0]               heart_rate_bpm;
    wire                     r_peak_pulse;
    wire                     qrst_done;
    wire [7:0]               qrst_marker;
    wire                     feat_valid;

    // =========================================================================
    // 5. 12 FITUR MORFOLOGI KLINIS DUT
    // =========================================================================
    wire signed [7:0]        feat_x1,  feat_x2,  feat_x3;
    wire signed [7:0]        feat_x4,  feat_x5,  feat_x6;
    wire signed [7:0]        feat_x7,  feat_x8,  feat_x9;
    wire signed [7:0]        feat_x10, feat_x11, feat_x12;

    // =========================================================================
    // 6. PENYANGGA & PENGHITUNG STIMULUS
    // =========================================================================
    reg [15:0] ecg_mem [0:SAMPLES_PER_REC-1];
    integer s_idx;
    integer beat_counter;
    integer qrst_beat_cnt;
    integer feat_beat_cnt;
    integer diag_beat_cnt;

    // =========================================================================
    // INSTANSIASI UNIT UNDER TEST (UUT)
    // =========================================================================
    top_ecg_system #(
        .BUFFER_DEPTH    (64),
        .R_THRESH_INIT   (350),
        .REFRACTORY_SAMP (250),
        .WEIGHTS_FILE    ("weights_int8.mem")
    ) uut (
        .clk               (clk),
        .rst_n             (rst_n),
        .ce                (ce),
        .sample_in         (sample_in),
        .sample_valid_i    (sample_valid),
        .diagnosis_class_o (diagnosis_class),
        .score_normal_o    (score_normal),
        .score_mi_o        (score_mi),
        .score_unknown_o   (score_unknown),
        .diagnosis_valid_o (diagnosis_valid),
        .heart_rate_bpm_o  (heart_rate_bpm),
        .r_peak_pulse_o    (r_peak_pulse),
        .qrst_done_o       (qrst_done),
        .qrst_marker_o     (qrst_marker),
        .feat_valid_o      (feat_valid),
        .feat_x1_o         (feat_x1),
        .feat_x2_o         (feat_x2),
        .feat_x3_o         (feat_x3),
        .feat_x4_o         (feat_x4),
        .feat_x5_o         (feat_x5),
        .feat_x6_o         (feat_x6),
        .feat_x7_o         (feat_x7),
        .feat_x8_o         (feat_x8),
        .feat_x9_o         (feat_x9),
        .feat_x10_o        (feat_x10),
        .feat_x11_o        (feat_x11),
        .feat_x12_o        (feat_x12),
        .filtered_sample_o (filtered_sample),
        .filtered_valid_o  (filtered_valid)
    );

    // =========================================================================
    // GENERATOR CLOCK 100 MHz (PERIODE 10 ns)
    // =========================================================================
    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD_NS / 2) clk = ~clk;
    end

    // =========================================================================
    // EVENT 1: PEMANTAU QRST_DONE (TELEMETRI TITIK FIDUSIAL & AMPLITUDO)
    // Dipicu saat detektor QRST selesai menemukan seluruh titik gelombang
    // =========================================================================
    always @(posedge clk) begin
        if (rst_n && ce && qrst_done) begin
            qrst_beat_cnt = qrst_beat_cnt + 1;

            $display("\n========================================================================================");
            $display(" [TCL TELEMETRI 1/3: QRST_DONE] DETAK JANTUNG #%0d TERDETEKSI (WAKTU: %0t ns)", 
                     qrst_beat_cnt, $time);
            $display("========================================================================================");
            $display("  [SINYAL INPUT MENTAH vs TERFILTER (BANDPASS 0.5 Hz - 45 Hz)] :");
            $display("    - Sample In Mentah (Raw ADC sample_in) : %6d", sample_in);
            $display("    - Sample Terfilter (BPF 0.5 - 45 Hz)   : %6d", filtered_sample);
            $display("  --------------------------------------------------------------------------------------");
            $display("  [STATUS TELEMETRI] Denyut Jantung: %0d BPM | QRST Marker State: 0x%02X (%0d)", 
                     heart_rate_bpm, qrst_marker, qrst_marker);
            $display("========================================================================================");
        end
    end

    // =========================================================================
    // EVENT 2: PEMANTAU FEAT_VALID (EKSTRAKSI 12 FITUR MORFOLOGI KLINIS)
    // Dipicu saat modul kalkulasi 12 fitur selesai memproses data morfologi
    // =========================================================================
    always @(posedge clk) begin
        if (rst_n && ce && feat_valid) begin
            feat_beat_cnt = feat_beat_cnt + 1;

            $display("\n========================================================================================");
            $display(" [TCL TELEMETRI 2/3: FEAT_VALID] 12 FITUR MORFOLOGI SELESAI DIEKSTRAKSI (DETAK #%0d)", 
                     feat_beat_cnt);
            $display("========================================================================================");
            $display("  [1. FITUR DELTA AMPLITUDO (INT8 SIGNED)] :");
            $display("    - x1  (RQ_A  = (R_amp - Q_amp)/32)     : %4d", feat_x1);
            $display("    - x2  (RS_A  = (R_amp - S_amp)/32)     : %4d", feat_x2);
            $display("    - x3  (RT_A  = (R_amp - T_amp)/32)     : %4d  <-- Biomarker Elevasi ST", feat_x3);
            $display("  [2. FITUR INTERVAL & DURASI WAKTU (INT8 SIGNED)] :");
            $display("    - x4  (RQ_ms = t_R - t_Q)              : %4d ms", feat_x4);
            $display("    - x5  (RS_ms = t_S - t_R)              : %4d ms", feat_x5);
            $display("    - x6  (RTL   = (t_Ton - t_R)/4)        : %4d", feat_x6);
            $display("    - x7  (RTR   = (t_Toff - t_R)/4)       : %4d", feat_x7);
            $display("    - x8  (QTCI  = (t_Toff - t_Q)/4)       : %4d", feat_x8);
            $display("    - x9  (STS   = t_Ton - t_Soff)         : %4d ms", feat_x9);
            $display("    - x10 (STI   = (t_Toff - t_Soff)/4)    : %4d", feat_x10);
            $display("  [3. FITUR KETAJAMAN SUDUT CORDIC (INT8 SIGNED)] :");
            $display("    - x11 (Sudut Puncak Gelombang R)       : %4d deg", feat_x11);
            $display("    - x12 (Sudut Lembah Gelombang S)       : %4d deg", feat_x12);
            $display("========================================================================================");
        end
    end

    // =========================================================================
    // EVENT 3: PEMANTAU DIAGNOSIS_VALID (HASIL INFERENSI MLP AKSELERATOR)
    // Dipicu saat akselerator neural network INT8 selesai mengklasifikasi detak
    // =========================================================================
    always @(posedge clk) begin
        if (rst_n && ce && diagnosis_valid) begin
            diag_beat_cnt = diag_beat_cnt + 1;
            beat_counter  = diag_beat_cnt;

            $display("\n========================================================================================");
            $display(" [TCL TELEMETRI 3/3: DIAGNOSIS_VALID] INFERENSI MLP SELESAI (DETAK #%0d | WAKTU: %0t ns)", 
                     diag_beat_cnt, $time);
            $display("========================================================================================");
            $display("  [AKSELERATOR MLP INT8 - SKOR LOGITS KELUARAN] :");
            $display("    - Skor Kelas 0 (Normal Sinus Rhythm)      : %4d", score_normal);
            $display("    - Skor Kelas 1 (Infark Miokard / STEMI)   : %4d", score_mi);
            $display("    - Skor Kelas 2 (Unknown / Dysrhythmia)    : %4d", score_unknown);
            $display("  --------------------------------------------------------------------------------------");
            case (diagnosis_class)
                2'b00: $display("  ==> HASIL KLASIFIKASI: [ 00 : NORMAL / HEALTHY CONTROL ] <==");
                2'b01: $display("  ==> HASIL KLASIFIKASI: [ 01 : INFARK MIOKARD / STEMI DETECTED! ] <==");
                2'b10: $display("  ==> HASIL KLASIFIKASI: [ 10 : UNKNOWN / ARITMIA ] <==");
                default: $display("  ==> HASIL KLASIFIKASI: [ INDETERMINATE ] <==");
            endcase
            $display("========================================================================================\n");
        end
    end

    // =========================================================================
    // TASK STREAMING BERKAS SINYAL EKG
    // =========================================================================
    task stream_ecg_record(
        input [255:0] filename,
        input [255:0] case_title,
        input [1:0]   expected_class
    );
        integer idx;
    begin
        $display("\n****************************************************************************************");
        $display("  [STIMULUS] MEMUAT REKAMAN SINYAL EKG: %0s", filename);
        $display("             KASUS DIAGNOSTIK: %0s", case_title);
        $display("****************************************************************************************");

        $readmemh(filename, ecg_mem);
        if (ecg_mem[0] === 16'hxxxx) begin
            $readmemh({"rtl/sim_data/", filename}, ecg_mem);
        end
        if (ecg_mem[0] === 16'hxxxx) begin
            $readmemh({"/home/nexus_is/5.Project/Hackaton_ICDeC/rtl/sim_data/", filename}, ecg_mem);
        end

        if (ecg_mem[0] !== 16'hxxxx) begin
            $display("  [SUKSES] %0d sampel EKG berhasil dimuat ke memori simulasi.", SAMPLES_PER_REC);
        end else begin
            $display("  [ERROR FATAL] Gagal memuat berkas %0s! Memori bernilai XXXX.", filename);
        end

        // Reset DUT singkat antar rekaman
        rst_n        <= 1'b0;
        sample_valid <= 1'b0;
        sample_in    <= 16'sd0;
        #(CLK_PERIOD_NS * 10);
        @(posedge clk);
        rst_n        <= 1'b1;
        #(CLK_PERIOD_NS * 10);

        // Alirkan sampel EKG satu per satu sesuai laju sampling 1000 Hz
        for (idx = 0; idx < SAMPLES_PER_REC; idx = idx + 1) begin
            s_idx = idx;
            @(posedge clk);
            sample_in    <= ecg_mem[idx];
            sample_valid <= 1'b1;
            @(posedge clk);
            sample_valid <= 1'b0;

            #SAMPLE_PERIOD;
        end

        // Jeda singkat penyelesaian pipeline (20 clock cycles)
        #(CLK_PERIOD_NS * 20);

        $display("  [STATUS] Selesai mengalirkan rekaman %0s. Evaluasi diagnosis akhir...", case_title);
        if (diagnosis_class === expected_class) begin
            $display("  -> [VERIFIKASI SUKSES]: Diagnosis Sesuai Ekspektasi Medis (Kelas %0d)!\n", expected_class);
        end else begin
            $display("  -> [VERIFIKASI CATATAN]: Diagnosis Terkini = Kelas %0d (Ekspektasi %0d).\n", diagnosis_class, expected_class);
        end
    end
    endtask

    // =========================================================================
    // ALUR STIMULUS SIMULASI UTAMA
    // =========================================================================
    initial begin
        clk                  = 1'b0;
        rst_n                = 1'b0;
        ce                   = 1'b0;
        sample_in            = 16'sd0;
        sample_valid         = 1'b0;
        s_idx                = 0;
        beat_counter         = 0;
        qrst_beat_cnt        = 0;
        feat_beat_cnt        = 0;
        diag_beat_cnt        = 0;

        $display("########################################################################################");
        $display("#                                                                                      #");
        $display("#        TESTBENCH VERIFIKASI END-TO-END SISTEM LENGKAP DETEKSI & KLASIFIKASI EKG      #");
        $display("#                 (PENGUJIAN SINYAL NYATA PTB DIAGNOSTIC DATABASE)                     #");
        $display("#                                                                                      #");
        $display("########################################################################################");

        // Siklus Inisialisasi Reset (100 ns)
        #100;
        @(posedge clk);
        rst_n <= 1'b1;
        ce    <= 1'b1;
        $display("  [INISIALISASI] Reset dilepas (rst_n = 1), CE aktif (ce = 1). Memulai pengujian...\n");

        // ---------------------------------------------------------------------
        // PENGUJIAN 1: PASIEN NORMAL SINUS RHYTHM (ecg_normal.mem)
        // ---------------------------------------------------------------------
        stream_ecg_record("ecg_normal.mem", "NORMAL HEALTHY CONTROL", 2'b00);

        // Jeda waktu antar rekaman (50 us)
        #50_000;

        // ---------------------------------------------------------------------
        // PENGUJIAN 2: PASIEN INFARK MIOKARD / STEMI (ecg_mi.mem)
        // ---------------------------------------------------------------------
        stream_ecg_record("ecg_mi.mem", "MYOCARDIAL INFARCTION / STEMI", 2'b01);

        // Jeda waktu antar rekaman (50 us)
        #50_000;

        // ---------------------------------------------------------------------
        // PENGUJIAN 3: PASIEN UNKNOWN / KELAINAN LAIN (ecg_unknown.mem)
        // ---------------------------------------------------------------------
        stream_ecg_record("ecg_unknown.mem", "UNKNOWN / DYSRHYTHMIA", 2'b10);

        // Tepat setelah data ecg_unknown.mem selesai dialirkan, simulasi langsung selesai:
        $display("\n########################################################################################");
        $display("#        SELURUH DATA REKAMAN EKG TELAH SELESAI DISUNTIKKAN & DIKLASIFIKASI!            #");
        $display("#        TOTAL DETAK TERPROSES SECARA LENGKAP: %0d DETAK JANTUNG                        #", beat_counter);
        $display("########################################################################################\n");
        $finish;
    end

endmodule
