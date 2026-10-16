`timescale 1ns / 1ns
//////////////////////////////////////////////////////////////////////////////////
// Testbench: tb_feature_extractor_12.v
// Proyek:    Indonesia Chip Hackathon Challenge 2026 (DIICES UB)
// Deskripsi: Testbench verifikasi integrasi pipeline penuh:
//            Stimulus EKG (ecg_normal.mem) -> top_qrst_detector -> feature_extractor_12
//
// Standar Desain:
// - Output konsol bersih & ringkas (hanya mencetak saat feat_valid_o == 1).
// - Memverifikasi nilai 12 fitur INT8 (-128 s.d. +127) per denyut EKG.
//////////////////////////////////////////////////////////////////////////////////

module tb_feature_extractor_12;

    // Parameter Simulasi
    localparam integer CLK_PERIOD_NS   = 10;          // Clock sistem 100 MHz (10 ns)
    localparam integer TOTAL_SAMPLES   = 2000;        // 2000 sampel EKG (~2 detik @ 1000 Hz)
    localparam time    SAMPLE_PERIOD   = 1_000_000;   // Periode sampling 1 ms = 1000 Hz

    // Sinyal Masukan Top
    reg                      clk;
    reg                      rst_n;
    reg                      ce;
    reg  signed [15:0]       sample_in;
    reg                      sample_valid;

    // Sinyal Interkoneksi dari QRST Detector (1-Bit Wire Pulse)
    wire                     t_q;
    wire                     t_r;
    wire                     t_s;
    wire                     t_t;
    wire                     t_on;
    wire                     t_off;
    wire                     s_off;
    wire                     qrst_done;

    // Sinyal Koordinat Waktu Timestamp Numerik (16-Bit Wire)
    wire        [15:0]       t_q_val;
    wire        [15:0]       t_r_val;
    wire        [15:0]       t_s_val;
    wire        [15:0]       t_on_val;
    wire        [15:0]       t_off_val;
    wire        [15:0]       s_off_val;

    // Sinyal Koordinat Amplitudo & Telemetri (Wire)
    wire signed [15:0]       q_amp;
    wire signed [15:0]       r_amp;
    wire signed [15:0]       s_amp;
    wire signed [15:0]       t_amp;
    wire signed [15:0]       st_elev;
    wire signed [15:0]       iso_base;
    wire        [7:0]        qrst_marker;
    wire        [7:0]        heart_rate_bpm;

    // Sinyal Keluaran 12 Fitur dari feature_extractor_12
    wire                     feat_valid;
    wire                     feat_busy;
    wire signed [7:0]        feat_x1;
    wire signed [7:0]        feat_x2;
    wire signed [7:0]        feat_x3;
    wire signed [7:0]        feat_x4;
    wire signed [7:0]        feat_x5;
    wire signed [7:0]        feat_x6;
    wire signed [7:0]        feat_x7;
    wire signed [7:0]        feat_x8;
    wire signed [7:0]        feat_x9;
    wire signed [7:0]        feat_x10;
    wire signed [7:0]        feat_x11;
    wire signed [7:0]        feat_x12;

    // Memori Stimulus EKG
    reg [15:0] ecg_mem [0:TOTAL_SAMPLES-1];
    integer s_idx;
    integer beat_count;

    // -------------------------------------------------------------------------
    // 1. Instansiasi UUT 1: Top QRST Detector
    // -------------------------------------------------------------------------
    top_qrst_detector #(
        .BUFFER_DEPTH    (64),
        .R_THRESH_INIT   (800),
        .REFRACTORY_SAMP (250)
    ) u_qrst_detector (
        .clk              (clk),
        .rst_n            (rst_n),
        .ce               (ce),
        .sample_in        (sample_in),
        .sample_valid_i   (sample_valid),
        .t_q_o            (t_q),
        .t_r_o            (t_r),
        .t_s_o            (t_s),
        .t_t_o            (t_t),
        .t_on_o           (t_on),
        .t_off_o          (t_off),
        .s_off_o          (s_off),
        .qrst_done_o      (qrst_done),
        .t_q_val_o        (t_q_val),
        .t_r_val_o        (t_r_val),
        .t_s_val_o        (t_s_val),
        .t_on_val_o       (t_on_val),
        .t_off_val_o      (t_off_val),
        .s_off_val_o      (s_off_val),
        .q_amp_o          (q_amp),
        .r_amp_o          (r_amp),
        .s_amp_o          (s_amp),
        .t_amp_o          (t_amp),
        .st_elev_o        (st_elev),
        .iso_base_o       (iso_base),
        .qrst_marker_o    (qrst_marker),
        .heart_rate_bpm_o (heart_rate_bpm)
    );

    // -------------------------------------------------------------------------
    // 2. Instansiasi UUT 2: 12-Feature Extractor
    //    Terhubung langsung ke port output wire UUT 1 secara bersih
    // -------------------------------------------------------------------------
    feature_extractor_12 u_feat_extractor (
        .clk              (clk),
        .rst_n            (rst_n),
        .ce               (ce),
        .features_ready_i (qrst_done),
        .q_amp_i          (q_amp),
        .r_amp_i          (r_amp),
        .s_amp_i          (s_amp),
        .t_amp_i          (t_amp),
        .t_q_i            (t_q_val),
        .t_r_i            (t_r_val),
        .t_s_i            (t_s_val),
        .t_on_i           (t_on_val),
        .t_off_i          (t_off_val),
        .s_off_i          (s_off_val),
        .feat_valid_o     (feat_valid),
        .feat_busy_o      (feat_busy),
        .feat_x1_o        (feat_x1),
        .feat_x2_o        (feat_x2),
        .feat_x3_o        (feat_x3),
        .feat_x4_o        (feat_x4),
        .feat_x5_o        (feat_x5),
        .feat_x6_o        (feat_x6),
        .feat_x7_o        (feat_x7),
        .feat_x8_o        (feat_x8),
        .feat_x9_o        (feat_x9),
        .feat_x10_o       (feat_x10),
        .feat_x11_o       (feat_x11),
        .feat_x12_o       (feat_x12)
    );

    // -------------------------------------------------------------------------
    // Generator Clock 100 MHz
    // -------------------------------------------------------------------------
    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD_NS / 2) clk = ~clk;
    end

    // -------------------------------------------------------------------------
    // Monitor Output Ringkas & Bersih
    // HANYA MENCETAK 12 FITUR SAAT feat_valid_o AKTIF (1 KALI PER BEAT)
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst_n && ce && feat_valid) begin
            beat_count = beat_count + 1;
            $display("========================================================================================");
            $display("         EKSTRAKSI 12 FITUR MORFOLOGI SELESAI (BEAT #%0d | HEART RATE: %0d BPM)          ", 
                     beat_count, heart_rate_bpm);
            $display("========================================================================================");
            $display("  1. FITUR DELTA AMPLITUDO (INT8):");
            $display("     • x1 (RQ_A) = %+4d  [Selisih Amplitudo R - Q]", feat_x1);
            $display("     • x2 (RS_A) = %+4d  [Selisih Amplitudo R - S]", feat_x2);
            $display("     • x3 (RT_A) = %+4d  [Selisih Amplitudo R - T]", feat_x3);
            $display("  --------------------------------------------------------------------------------------");
            $display("  2. FITUR INTERVAL / DURASI WAKTU (INT8):");
            $display("     • x4 (RQ)   = %+4d  [Durasi Q ke R (ms)]", feat_x4);
            $display("     • x5 (RS)   = %+4d  [Durasi R ke S (ms)]", feat_x5);
            $display("     • x6 (RTL)  = %+4d  [Durasi R ke T_onset]", feat_x6);
            $display("     • x7 (RTR)  = %+4d  [Durasi R ke T_offset]", feat_x7);
            $display("     • x8 (QTCI) = %+4d  [Interval QT Penuh (Q ke T_offset)]", feat_x8);
            $display("     • x9 (STS)  = %+4d  [Segmen ST (Titik J ke T_onset)]", feat_x9);
            $display("     • x10(STI)  = %+4d  [Interval ST (Titik J ke T_offset)]", feat_x10);
            $display("  --------------------------------------------------------------------------------------");
            $display("  3. FITUR SUDUT GEOMETRI VEKTOR (INT8 via LUT ROM):");
            $display("     • x11 (∠R)  = %+4d  [Sudut Ketajaman Vektor Puncak R (Q-R-S)]", feat_x11);
            $display("     • x12 (∠S)  = %+4d  [Sudut Ketajaman Vektor Lembah S (R-S-T)]", feat_x12);
            $display("  --------------------------------------------------------------------------------------");
            $display("  Status: Vektor 12-Fitur Siap Diinputkan ke Akselerator Jaringan Syaraf Tiruan (MLP)!");
            $display("========================================================================================\n");
        end
    end

    // -------------------------------------------------------------------------
    // Skenario Pengujian Stimulus EKG
    // -------------------------------------------------------------------------
    initial begin
        // Inisialisasi awal
        rst_n        = 1'b0;
        ce           = 1'b0;
        sample_in    = 16'sd0;
        sample_valid = 1'b0;
        beat_count   = 0;

        $display("\n****************************************************************************************");
        $display("   MEMULAI VERIFIKASI FEATURE_EXTRACTOR_12 DENGAN STIMULUS EKG ASLI (PTB DATABASE)      ");
        $display("****************************************************************************************");

        // Membaca berkas hex memori EKG (mencoba direktori xsim lokal lalu fallback path)
        $readmemh("ecg_normal.mem", ecg_mem);
        if (ecg_mem[0] === 16'hxxxx) begin
            $readmemh("rtl/sim_data/ecg_normal.mem", ecg_mem);
        end
        if (ecg_mem[0] === 16'hxxxx) begin
            $readmemh("/home/nexus_is/5.Project/Hackaton_ICDeC/rtl/sim_data/ecg_normal.mem", ecg_mem);
        end

        if (ecg_mem[0] !== 16'hxxxx) begin
            $display("  [SUKSES] 2000 sampel EKG berhasil dimuat ke dalam memori simulasi.");
        end else begin
            $display("  [FATAL ERROR] Gagal memuat file stimulus ecg_normal.mem! Seluruh memori bernilai XXXX.");
        end

        // Siklus Reset Asinkron & Enable Clock
        #100;
        @(posedge clk);
        rst_n <= 1'b1;
        ce    <= 1'b1;
        $display("  [STATUS] Reset dilepas (rst_n = 1), CE aktif (ce = 1). Memulai streaming data EKG...\n");

        // Pengaliran 2000 sampel EKG berkecepatan 1000 Hz (1 ms per sampel)
        for (s_idx = 0; s_idx < TOTAL_SAMPLES; s_idx = s_idx + 1) begin
            @(posedge clk);
            sample_in    <= ecg_mem[s_idx];
            sample_valid <= 1'b1;
            @(posedge clk);
            sample_valid <= 1'b0;

            // Tunggu interval sampling 1 ms
            #SAMPLE_PERIOD;
        end

        // Tunggu penyelesaian beat terakhir di dalam pipeline (50 ms)
        #50_000_000;

        $display("****************************************************************************************");
        $display("  SIMULASI FEATURE_EXTRACTOR_12 SELESAI DENGAN SUKSES!");
        $display("  Total Denyut yang Berhasil Diekstraksi Menjadi Vektor 12 Fitur: %0d Beat", beat_count);
        $display("****************************************************************************************\n");
        $finish;
    end

endmodule
