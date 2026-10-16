`timescale 1ns / 1ns
//////////////////////////////////////////////////////////////////////////////////
// Modul: top_qrst_detector.v
// Proyek: Indonesia Chip Hackathon Challenge 2026 (DIICES UB)
// Deskripsi: Top Wrapper struktural yang mengintegrasikan tiga modul utama
//            pendeteksi morfologi gelombang QRST berbasis Sliding Window
//            Shift Register dan FSM Moore:
//            1. shift_reg_buffer.v  - Master Sliding Window & History RAM
//            2. r_peak_detector.v    - 3-Tap Peak R Extrema & Thresholding
//            3. qst_detector_fsm.v   - Sekuensial Controller Q -> S -> T
//
// Standar Desain:
// - Seluruh port output bertipe 'output wire' (bukan output reg).
// - Port kontrol 1-bit wire dan bus data numerik bertipe wire [lebar:0].
// - Seluruh submodul mematuhi konvensi register _ps, _ns, dan assign dari _ps.
//////////////////////////////////////////////////////////////////////////////////

module top_qrst_detector #(
    parameter integer BUFFER_DEPTH    = 64,
    parameter integer R_THRESH_INIT   = 350,
    parameter integer REFRACTORY_SAMP = 250
)(
    // Clock & Reset Global
    input  wire                      clk,
    input  wire                      rst_n,
    input  wire                      ce,

    // Masukan Data EKG (Signed 16-Bit Q15)
    input  wire signed [15:0]        sample_in,
    input  wire                      sample_valid_i,

    // Sinyal Tanda QRST Real-Time (1-Bit Wire Pulse)
    output wire                      t_q_o,
    output wire                      t_r_o,
    output wire                      t_s_o,
    output wire                      t_t_o,
    output wire                      t_on_o,
    output wire                      t_off_o,
    output wire                      s_off_o,
    output wire                      qrst_done_o,

    // Sinyal Koordinat Waktu Timestamp Numerik Terkunci (16-Bit Wire)
    output wire        [15:0]        t_q_val_o,
    output wire        [15:0]        t_r_val_o,
    output wire        [15:0]        t_s_val_o,
    output wire        [15:0]        t_on_val_o,
    output wire        [15:0]        t_off_val_o,
    output wire        [15:0]        s_off_val_o,

    // Metrik Amplitudo Terkunci (Signed 16-Bit Q15 Wire)
    output wire signed [15:0]        q_amp_o,
    output wire signed [15:0]        r_amp_o,
    output wire signed [15:0]        s_amp_o,
    output wire signed [15:0]        t_amp_o,
    output wire signed [15:0]        st_elev_o,
    output wire signed [15:0]        iso_base_o,

    // Telemetri Marker & Denyut Jantung Wire
    output wire        [7:0]         qrst_marker_o,
    output wire        [7:0]         heart_rate_bpm_o
);

    // =========================================================================
    // JALUR KABEL INTERKONEKSI ANTAR SUBMODUL
    // =========================================================================
    wire buffer_ready_w;
    wire signed [15:0] tap0_w;
    wire signed [15:0] tap1_w;
    wire signed [15:0] tap2_w;
    wire signed [15:0] delayed_sample_w;
    wire        [15:0] sample_cnt_w;

    wire [5:0] read_addr_w;
    wire t_r_w;
    wire signed [15:0] r_amp_w;

    // Hubungkan tanda pulsa R dan amplitudo R langsung ke output
    assign t_r_o   = t_r_w;
    assign r_amp_o = r_amp_w;

    // =========================================================================
    // 1. INSTANSIASI SUBMODUL 1: SHIFT REGISTER BUFFER
    // =========================================================================
    shift_reg_buffer #(
        .DEPTH(BUFFER_DEPTH)
    ) u_shift_reg_buffer (
        .clk              (clk),
        .rst_n            (rst_n),
        .ce               (ce),
        .sample_in        (sample_in),
        .sample_valid_i   (sample_valid_i),
        .read_addr_i      (read_addr_w),
        .buffer_ready_o   (buffer_ready_w),
        .tap0_o           (tap0_w),
        .tap1_o           (tap1_w),
        .tap2_o           (tap2_w),
        .delayed_sample_o (delayed_sample_w),
        .sample_cnt_o     (sample_cnt_w)
    );

    // =========================================================================
    // 2. INSTANSIASI SUBMODUL 2: R-PEAK DETECTOR
    // =========================================================================
    r_peak_detector #(
        .R_THRESH_INIT   (R_THRESH_INIT),
        .REFRACTORY_SAMP (REFRACTORY_SAMP)
    ) u_r_peak_detector (
        .clk            (clk),
        .rst_n          (rst_n),
        .ce             (ce),
        .tap0_i         (tap0_w),
        .tap1_i         (tap1_w),
        .tap2_i         (tap2_w),
        .sample_cnt_i   (sample_cnt_w),
        .sample_valid_i (sample_valid_i),
        .t_r_o          (t_r_w),
        .r_amp_o        (r_amp_w)
    );

    // =========================================================================
    // 3. INSTANSIASI SUBMODUL 3: QST DETECTOR FSM
    // =========================================================================
    qst_detector_fsm u_qst_detector_fsm (
        .clk              (clk),
        .rst_n            (rst_n),
        .ce               (ce),
        .t_r_i            (t_r_w),
        .r_amp_i          (r_amp_w),
        .delayed_sample_i (delayed_sample_w),
        .sample_raw_i     (tap0_w),
        .sample_cnt_i     (sample_cnt_w),
        .sample_valid_i   (sample_valid_i),
        .read_addr_o      (read_addr_w),
        .t_q_o            (t_q_o),
        .t_s_o            (t_s_o),
        .t_t_o            (t_t_o),
        .t_on_o           (t_on_o),
        .t_off_o          (t_off_o),
        .s_off_o          (s_off_o),
        .qrst_done_o      (qrst_done_o),
        .t_q_val_o        (t_q_val_o),
        .t_r_val_o        (t_r_val_o),
        .t_s_val_o        (t_s_val_o),
        .t_on_val_o       (t_on_val_o),
        .t_off_val_o      (t_off_val_o),
        .s_off_val_o      (s_off_val_o),
        .q_amp_o          (q_amp_o),
        .s_amp_o          (s_amp_o),
        .t_amp_o          (t_amp_o),
        .st_elev_o        (st_elev_o),
        .iso_base_o       (iso_base_o),
        .qrst_marker_o    (qrst_marker_o),
        .heart_rate_bpm_o (heart_rate_bpm_o)
    );

endmodule
