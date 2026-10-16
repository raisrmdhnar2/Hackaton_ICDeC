`timescale 1ns / 1ns
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: Antigravity AI
// 
// Create Date: 14.10.2026
// Design Name: Complete ECG Infarction Classifier System
// Module Name: top_ecg_system
// Project Name: Hackathon ICDeC
// Target Devices: Artix-7 / Spartan-7 FPGA
// Tool Versions: Vivado 2024.1 / 2025.1
// Description:
//   Top-Level Integration System untuk Klasifikasi Infark Miokard Real-Time:
//   1. Submodul 1: top_qrst_detector (Filter, Deteksi Puncak R, Fidusial Q, S, T)
//   2. Submodul 2: feature_extractor_12 (Kalkulasi 12 Fitur Morfologi Klinis INT8)
//   3. Submodul 3: mlp_accelerator_int8 (Akselerator Inferensi Jaringan Syaraf INT8)
//   
//   Standar Implementasi:
//   - Header Port: Seluruh output bertipe 'output wire' dengan bus bit eksplisit.
//   - Bebas dari 'output reg' dan bebas dari unpacked array pada port.
//   - Registrasi hasil diagnosis menggunakan konvensi Moore _ps/_ns.
//////////////////////////////////////////////////////////////////////////////////

module top_ecg_system #(
    parameter integer BUFFER_DEPTH    = 64,
    parameter integer R_THRESH_INIT   = 350,
    parameter integer REFRACTORY_SAMP = 250,
    parameter         WEIGHTS_FILE    = "weights_int8.mem"
)(
    // Clock & Kontrol Global
    input  wire                      clk,
    input  wire                      rst_n,
    input  wire                      ce,

    // Masukan Sampel Sinyal EKG Analog / Digital (Signed 16-Bit Q15)
    input  wire signed [15:0]        sample_in,
    input  wire                      sample_valid_i,

    // =========================================================================
    // KELUARAN DIAGNOSIS AKHIR (HASIL KLASIFIKASI MLP INT8)
    // =========================================================================
    output wire [1:0]                diagnosis_class_o,   // 00: Normal, 01: Infark Miokard, 10: Unknown
    output wire signed [7:0]         score_normal_o,      // Skor Logits INT8 Kelas Normal
    output wire signed [7:0]         score_mi_o,          // Skor Logits INT8 Kelas Infark Miokard
    output wire signed [7:0]         score_unknown_o,     // Skor Logits INT8 Kelas Unknown
    output wire                      diagnosis_valid_o,   // Pulsa 1-clk ketika inferensi selesai

    // =========================================================================
    // TELEMETRI & STATUS SISTEM EKG
    // =========================================================================
    output wire [7:0]                heart_rate_bpm_o,    // Denyut Jantung (BPM)
    output wire                      r_peak_pulse_o,      // Pulsa deteksi puncak R (1-clk)
    output wire                      t_q_pulse_o,         // Pulsa deteksi lembah Q (1-clk)
    output wire                      t_s_pulse_o,         // Pulsa deteksi lembah S (1-clk)
    output wire                      t_t_pulse_o,         // Pulsa deteksi puncak T (1-clk)
    output wire                      qrst_done_o,         // Pulsa deteksi fidusial QRST selesai (1-clk)
    output wire [7:0]                qrst_marker_o,       // Status Marker FSM Detektor
    output wire                      feat_valid_o,        // Pulsa ekstraksi 12 fitur valid (1-clk)

    // =========================================================================
    // 12 FITUR MORFOLOGI KLINIS TERHITUNG (INT8 SIGNED WIRE)
    // =========================================================================
    output wire signed [7:0]         feat_x1_o,           // RQ_A  = (R_amp - Q_amp) / 32
    output wire signed [7:0]         feat_x2_o,           // RS_A  = (R_amp - S_amp) / 32
    output wire signed [7:0]         feat_x3_o,           // RT_A  = (R_amp - T_amp) / 32
    output wire signed [7:0]         feat_x4_o,           // RQ_ms = t_R - t_Q
    output wire signed [7:0]         feat_x5_o,           // RS_ms = t_S - t_R
    output wire signed [7:0]         feat_x6_o,           // RTL   = (t_Ton - t_R) / 4
    output wire signed [7:0]         feat_x7_o,           // RTR   = (t_Toff - t_R) / 4
    output wire signed [7:0]         feat_x8_o,           // QTCI  = (t_Toff - t_Q) / 4
    output wire signed [7:0]         feat_x9_o,           // STS   = t_Ton - t_Soff
    output wire signed [7:0]         feat_x10_o,          // STI   = (t_Toff - t_Soff) / 4
    output wire signed [7:0]         feat_x11_o,          // ∠R    = Sudut puncak R via CORDIC
    output wire signed [7:0]         feat_x12_o,          // ∠S    = Sudut lembah S via CORDIC

    // =========================================================================
    // SINYAL MONITOR HASIL FILTER BANDPASS (0.5 Hz - 45 Hz)
    // =========================================================================
    output wire signed [15:0]        filtered_sample_o,   // Sinyal EKG setelah BPF 0.5 - 45 Hz
    output wire                      filtered_valid_o     // Strobe valid sampel terfilter
);

    // =========================================================================
    // KABEL INTERKONEKSI SUBMODUL 1 -> SUBMODUL 2 (QRST DETECTOR KE FITUR)
    // =========================================================================
    wire        w_t_q_pulse;
    wire        w_t_r_pulse;
    wire        w_t_s_pulse;
    wire        w_t_t_pulse;
    wire        w_t_on_pulse;
    wire        w_t_off_pulse;
    wire        w_s_off_pulse;
    wire        w_qrst_done;

    wire [15:0] w_t_q_val;
    wire [15:0] w_t_r_val;
    wire [15:0] w_t_s_val;
    wire [15:0] w_t_on_val;
    wire [15:0] w_t_off_val;
    wire [15:0] w_s_off_val;

    wire signed [15:0] w_q_amp;
    wire signed [15:0] w_r_amp;
    wire signed [15:0] w_s_amp;
    wire signed [15:0] w_t_amp;
    wire signed [15:0] w_st_elev;
    wire signed [15:0] w_iso_base;

    wire [7:0] w_qrst_marker;
    wire [7:0] w_heart_rate_bpm;

    // =========================================================================
    // KABEL INTERKONEKSI SUBMODUL 2 -> SUBMODUL 3 (FITUR KE MLP AKSELERATOR)
    // =========================================================================
    wire        w_feat_valid;
    wire        w_feat_busy;

    wire signed [7:0] w_fx1;
    wire signed [7:0] w_fx2;
    wire signed [7:0] w_fx3;
    wire signed [7:0] w_fx4;
    wire signed [7:0] w_fx5;
    wire signed [7:0] w_fx6;
    wire signed [7:0] w_fx7;
    wire signed [7:0] w_fx8;
    wire signed [7:0] w_fx9;
    wire signed [7:0] w_fx10;
    wire signed [7:0] w_fx11;
    wire signed [7:0] w_fx12;

    // =========================================================================
    // KABEL OUTPUT SUBMODUL 3 (MLP AKSELERATOR)
    // =========================================================================
    wire signed [7:0] w_mlp_score_norm;
    wire signed [7:0] w_mlp_score_mi;
    wire signed [7:0] w_mlp_score_unk;
    wire [1:0]        w_mlp_class_pred;
    wire              w_mlp_done;

    // =========================================================================
    // KABEL INTERKONEKSI SUBMODUL 0 (BANDPASS FILTER KE QRST DETECTOR)
    // =========================================================================
    wire signed [15:0] w_filtered_sample;
    wire               w_filtered_valid;

    // =========================================================================
    // INSTANSIASI SUBMODUL 0: BANDPASS FILTER (0.5 Hz - 45 Hz)
    // =========================================================================
    ecg_bandpass_filter u_ecg_bpf (
        .clk               (clk),
        .rst_n             (rst_n),
        .ce                (ce),
        .sample_in         (sample_in),
        .sample_valid_i    (sample_valid_i),
        .filtered_sample_o (w_filtered_sample),
        .filtered_valid_o  (w_filtered_valid)
    );

    // =========================================================================
    // INSTANSIASI SUBMODUL 1: TOP QRST DETECTOR
    // =========================================================================
    top_qrst_detector #(
        .BUFFER_DEPTH    (BUFFER_DEPTH),
        .R_THRESH_INIT   (R_THRESH_INIT),
        .REFRACTORY_SAMP (REFRACTORY_SAMP)
    ) u_qrst_detector (
        .clk              (clk),
        .rst_n            (rst_n),
        .ce               (ce),
        .sample_in        (w_filtered_sample),
        .sample_valid_i   (w_filtered_valid),
        .t_q_o            (w_t_q_pulse),
        .t_r_o            (w_t_r_pulse),
        .t_s_o            (w_t_s_pulse),
        .t_t_o            (w_t_t_pulse),
        .t_on_o           (w_t_on_pulse),
        .t_off_o          (w_t_off_pulse),
        .s_off_o          (w_s_off_pulse),
        .qrst_done_o      (w_qrst_done),
        .t_q_val_o        (w_t_q_val),
        .t_r_val_o        (w_t_r_val),
        .t_s_val_o        (w_t_s_val),
        .t_on_val_o       (w_t_on_val),
        .t_off_val_o      (w_t_off_val),
        .s_off_val_o      (w_s_off_val),
        .q_amp_o          (w_q_amp),
        .r_amp_o          (w_r_amp),
        .s_amp_o          (w_s_amp),
        .t_amp_o          (w_t_amp),
        .st_elev_o        (w_st_elev),
        .iso_base_o       (w_iso_base),
        .qrst_marker_o    (w_qrst_marker),
        .heart_rate_bpm_o (w_heart_rate_bpm)
    );

    // =========================================================================
    // INSTANSIASI SUBMODUL 2: FEATURE EXTRACTOR 12
    // =========================================================================
    feature_extractor_12 #(
        .AMP_SHIFT_SCALE  (5),   // Pembagi amplitudo: 32
        .TIME_SHIFT_SCALE (2)    // Pembagi durasi besar: 4
    ) u_feat_extractor (
        .clk              (clk),
        .rst_n            (rst_n),
        .ce               (ce),
        .features_ready_i (w_qrst_done),
        .q_amp_i          (w_q_amp),
        .r_amp_i          (w_r_amp),
        .s_amp_i          (w_s_amp),
        .t_amp_i          (w_t_amp),
        .t_q_i            (w_t_q_val),
        .t_r_i            (w_t_r_val),
        .t_s_i            (w_t_s_val),
        .t_on_i           (w_t_on_val),
        .t_off_i          (w_t_off_val),
        .s_off_i          (w_s_off_val),
        .feat_valid_o     (w_feat_valid),
        .feat_busy_o      (w_feat_busy),
        .feat_x1_o        (w_fx1),
        .feat_x2_o        (w_fx2),
        .feat_x3_o        (w_fx3),
        .feat_x4_o        (w_fx4),
        .feat_x5_o        (w_fx5),
        .feat_x6_o        (w_fx6),
        .feat_x7_o        (w_fx7),
        .feat_x8_o        (w_fx8),
        .feat_x9_o        (w_fx9),
        .feat_x10_o       (w_fx10),
        .feat_x11_o       (w_fx11),
        .feat_x12_o       (w_fx12)
    );

    // =========================================================================
    // INSTANSIASI SUBMODUL 3: MLP ACCELERATOR INT8 (12 -> 8 -> 3)
    // =========================================================================
    mlp_accelerator_int8 #(
        .WEIGHTS_FILE     (WEIGHTS_FILE)
    ) u_mlp_accelerator (
        .clk              (clk),
        .rst_n            (rst_n),
        .ce               (ce),
        .start_i          (w_feat_valid),
        .in_x1_i          (w_fx1),
        .in_x2_i          (w_fx2),
        .in_x3_i          (w_fx3),
        .in_x4_i          (w_fx4),
        .in_x5_i          (w_fx5),
        .in_x6_i          (w_fx6),
        .in_x7_i          (w_fx7),
        .in_x8_i          (w_fx8),
        .in_x9_i          (w_fx9),
        .in_x10_i         (w_fx10),
        .in_x11_i         (w_fx11),
        .in_x12_i         (w_fx12),
        .score_normal_o   (w_mlp_score_norm),
        .score_mi_o       (w_mlp_score_mi),
        .score_unknown_o  (w_mlp_score_unk),
        .class_pred_o     (w_mlp_class_pred),
        .done_o           (w_mlp_done)
    );

    // =========================================================================
    // REGISTER PENYIMPAN HASIL DIAGNOSIS AKHIR (MOORE FSM REGISTER PATTERN)
    // Menyimpan diagnosis terkunci agar terbaca stabil hingga detak berikutnya.
    // =========================================================================
    reg [1:0]        diag_class_ps,  diag_class_ns;
    reg signed [7:0] score_norm_ps,  score_norm_ns;
    reg signed [7:0] score_mi_ps,    score_mi_ns;
    reg signed [7:0] score_unk_ps,   score_unk_ns;
    reg              diag_valid_ps,  diag_valid_ns;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            diag_class_ps <= 2'b00;
            score_norm_ps <= 8'sd0;
            score_mi_ps   <= 8'sd0;
            score_unk_ps  <= 8'sd0;
            diag_valid_ps <= 1'b0;
        end else if (ce) begin
            diag_class_ps <= diag_class_ns;
            score_norm_ps <= score_norm_ns;
            score_mi_ps   <= score_mi_ns;
            score_unk_ps  <= score_unk_ns;
            diag_valid_ps <= diag_valid_ns;
        end
    end

    always @(*) begin
        // Anti-Latch Default Assignment
        diag_class_ns = diag_class_ps;
        score_norm_ns = score_norm_ps;
        score_mi_ns   = score_mi_ps;
        score_unk_ns  = score_unk_ps;
        diag_valid_ns = 1'b0;

        // Latch hasil ketika MLP inferensi selesai
        if (w_mlp_done) begin
            diag_class_ns = w_mlp_class_pred;
            score_norm_ns = w_mlp_score_norm;
            score_mi_ns   = w_mlp_score_mi;
            score_unk_ns  = w_mlp_score_unk;
            diag_valid_ns = 1'b1;
        end
    end

    // =========================================================================
    // PENUGASAN PORT OUTPUT DARI PRESENT STATE & WIRE INTERNAL
    // Sesuai standar docs/FSM_Moore.md: assign <port> = <signal>_ps;
    // =========================================================================
    assign diagnosis_class_o = diag_class_ps;
    assign score_normal_o    = score_norm_ps;
    assign score_mi_o        = score_mi_ps;
    assign score_unknown_o   = score_unk_ps;
    assign diagnosis_valid_o = diag_valid_ps;

    // Telemetri Sinyal EKG
    assign heart_rate_bpm_o  = w_heart_rate_bpm;
    assign r_peak_pulse_o    = w_t_r_pulse;
    assign t_q_pulse_o       = w_t_q_pulse;
    assign t_s_pulse_o       = w_t_s_pulse;
    assign t_t_pulse_o       = w_t_t_pulse;
    assign qrst_done_o       = w_qrst_done;
    assign qrst_marker_o     = w_qrst_marker;
    assign feat_valid_o      = w_feat_valid;

    // 12 Fitur Morfologi
    assign feat_x1_o         = w_fx1;
    assign feat_x2_o         = w_fx2;
    assign feat_x3_o         = w_fx3;
    assign feat_x4_o         = w_fx4;
    assign feat_x5_o         = w_fx5;
    assign feat_x6_o         = w_fx6;
    assign feat_x7_o         = w_fx7;
    assign feat_x8_o         = w_fx8;
    assign feat_x9_o         = w_fx9;
    assign feat_x10_o        = w_fx10;
    assign feat_x11_o        = w_fx11;
    assign feat_x12_o        = w_fx12;

    // Sinyal Terfilter (0.5 Hz - 45 Hz)
    assign filtered_sample_o = w_filtered_sample;
    assign filtered_valid_o  = w_filtered_valid;

endmodule

