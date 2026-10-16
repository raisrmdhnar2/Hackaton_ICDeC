`timescale 1ns / 1ns
//////////////////////////////////////////////////////////////////////////////////
// Modul: feature_extractor_12.v
// Proyek: Indonesia Chip Hackathon Challenge 2026 (DIICES UB)
// Deskripsi: On-Chip 12-Feature Extraction Engine berbasis FSM Moore.
//
// Standar Desain:
// - Header modul: output port TIDAK BOLEH dalam bentuk array.
// - Output kontroler murni 1-bit wire (output wire feat_valid_o, feat_busy_o).
// - Output 12 data fitur klinis INT8 berupa port eksplisit (output wire signed [7:0] feat_x1_o ... feat_x12_o).
// - Semua data output disimpan oleh register internal skalar _ps dan _ns.
// - Blok sequential meng-update register internal _ps <= _ns.
// - Blok kombinatorial FSM mengolah _ns dengan pencegahan inferensi latch.
// - Penugasan akhir konsisten menggunakan 'assign <port> = <signal>_ps;'.
//////////////////////////////////////////////////////////////////////////////////

module feature_extractor_12 #(
    parameter integer AMP_SHIFT_SCALE  = 5,    // Pembagi amplitudo: 2^5 = 32
    parameter integer TIME_SHIFT_SCALE = 2     // Pembagi durasi besar: 2^2 = 4
)(
    // Clock & Kontrol Utama
    input  wire                      clk,
    input  wire                      rst_n,
    input  wire                      ce,

    // Sinyal Pemicu dari QRST Detector
    input  wire                      features_ready_i,    // Pulsa qrst_done_o (1-clk)

    // Koordinat Amplitudo Masukan Terkunci (Signed 16-Bit Q15)
    input  wire signed [15:0]        q_amp_i,
    input  wire signed [15:0]        r_amp_i,
    input  wire signed [15:0]        s_amp_i,
    input  wire signed [15:0]        t_amp_i,

    // Koordinat Waktu Masukan Terkunci (16-Bit Indeks Sampel ms)
    input  wire        [15:0]        t_q_i,
    input  wire        [15:0]        t_r_i,
    input  wire        [15:0]        t_s_i,
    input  wire        [15:0]        t_on_i,
    input  wire        [15:0]        t_off_i,
    input  wire        [15:0]        s_off_i,

    // =========================================================================
    // PORT KELUARAN KONTROLER FSM (MURNI 1-BIT WIRE)
    // =========================================================================
    output wire                      feat_valid_o,        // Pulsa 1-clk tanda selesai ekstraksi
    output wire                      feat_busy_o,         // Flag status FSM sedang memproses

    // =========================================================================
    // PORT KELUARAN 12 FITUR MORFOLOGI (INT8 WIRE - BUKAN ARRAY)
    // =========================================================================
    // 1. Fitur Delta Amplitudo
    output wire signed [7:0]         feat_x1_o,           // RQ_A : Amplitudo R - Q
    output wire signed [7:0]         feat_x2_o,           // RS_A : Amplitudo R - S
    output wire signed [7:0]         feat_x3_o,           // RT_A : Amplitudo R - T
    // 2. Fitur Interval / Durasi Waktu
    output wire signed [7:0]         feat_x4_o,           // RQ   : Durasi Q ke R
    output wire signed [7:0]         feat_x5_o,           // RS   : Durasi R ke S
    output wire signed [7:0]         feat_x6_o,           // RTL  : Durasi R ke T_onset
    output wire signed [7:0]         feat_x7_o,           // RTR  : Durasi R ke T_offset
    output wire signed [7:0]         feat_x8_o,           // QTCI : Interval QT Penuh
    output wire signed [7:0]         feat_x9_o,           // STS  : Segmen ST (J ke T_onset)
    output wire signed [7:0]         feat_x10_o,          // STI  : Interval ST (J ke T_offset)
    // 3. Fitur Sudut Geometri Vektor (via LUT ROM)
    output wire signed [7:0]         feat_x11_o,          // ∠R   : Sudut Puncak R (QRS)
    output wire signed [7:0]         feat_x12_o           // ∠S   : Sudut Lembah S (RST)
);

    // =========================================================================
    // 1. STATE ENCODING (FSM MOORE 3-ALWAYS BLOCK)
    // =========================================================================
    localparam [1:0]
        S_IDLE   = 2'b00,
        S_CALC   = 2'b01,
        S_DONE   = 2'b10;

    reg [1:0] state_ps, state_ns;

    // Register kontroler 1-bit internal (_ps dan _ns)
    reg feat_valid_ps, feat_valid_ns;
    reg feat_busy_ps,  feat_busy_ns;

    // Register internal skalar 12 fitur INT8 (_ps dan _ns) - BUKAN ARRAY
    reg signed [7:0] feat_x1_ps,  feat_x1_ns;
    reg signed [7:0] feat_x2_ps,  feat_x2_ns;
    reg signed [7:0] feat_x3_ps,  feat_x3_ns;
    reg signed [7:0] feat_x4_ps,  feat_x4_ns;
    reg signed [7:0] feat_x5_ps,  feat_x5_ns;
    reg signed [7:0] feat_x6_ps,  feat_x6_ns;
    reg signed [7:0] feat_x7_ps,  feat_x7_ns;
    reg signed [7:0] feat_x8_ps,  feat_x8_ns;
    reg signed [7:0] feat_x9_ps,  feat_x9_ns;
    reg signed [7:0] feat_x10_ps, feat_x10_ns;
    reg signed [7:0] feat_x11_ps, feat_x11_ns;
    reg signed [7:0] feat_x12_ps, feat_x12_ns;

    // Kabel kalkulasi aritmetika selisih
    wire signed [16:0] diff_rq_a = $signed(r_amp_i) - $signed(q_amp_i);
    wire signed [16:0] diff_rs_a = $signed(r_amp_i) - $signed(s_amp_i);
    wire signed [16:0] diff_rt_a = $signed(r_amp_i) - $signed(t_amp_i);

    wire        [15:0] dur_rq    = (t_r_i >= t_q_i)     ? (t_r_i - t_q_i)     : 16'd0;
    wire        [15:0] dur_rs    = (t_s_i >= t_r_i)     ? (t_s_i - t_r_i)     : 16'd0;
    wire        [15:0] dur_rtl   = (t_on_i >= t_r_i)    ? (t_on_i - t_r_i)    : 16'd0;
    wire        [15:0] dur_rtr   = (t_off_i >= t_r_i)   ? (t_off_i - t_r_i)   : 16'd0;
    wire        [15:0] dur_qtci  = (t_off_i >= t_q_i)   ? (t_off_i - t_q_i)   : 16'd0;
    wire        [15:0] dur_sts   = (t_on_i >= s_off_i)  ? (t_on_i - s_off_i)  : 16'd0;
    wire        [15:0] dur_sti   = (t_off_i >= s_off_i) ? (t_off_i - s_off_i) : 16'd0;

    // =========================================================================
    // FUNGSI SATURASI / CLIPPING INT8 (-128 s.d. +127)
    // =========================================================================
    function signed [7:0] sat_int8(input signed [16:0] val);
        begin
            if (val > 17'sd127)
                sat_int8 = 8'sd127;
            else if (val < -17'sd128)
                sat_int8 = -8'sd128;
            else
                sat_int8 = val[7:0];
        end
    endfunction

    // =========================================================================
    // LOOK-UP TABLE (LUT ROM) APROKSIMASI SUDUT VEKTOR (DIVIDER-FREE)
    // =========================================================================
    function signed [7:0] calc_angle_r(input [15:0] dur_qrs_w, input signed [16:0] amp_rs_w);
        begin
            if (amp_rs_w > 17'sd2500) begin
                if (dur_qrs_w < 16'd70)       calc_angle_r = 8'sd25; // ~50 derajat (runcing)
                else if (dur_qrs_w < 16'd100) calc_angle_r = 8'sd35; // ~70 derajat
                else                          calc_angle_r = 8'sd50; // ~100 derajat
            end else if (amp_rs_w > 17'sd1200) begin
                if (dur_qrs_w < 16'd70)       calc_angle_r = 8'sd35;
                else if (dur_qrs_w < 16'd100) calc_angle_r = 8'sd45;
                else                          calc_angle_r = 8'sd60;
            end else begin
                calc_angle_r = 8'sd70; // ~140 derajat (tumpul / infark)
            end
        end
    endfunction

    function signed [7:0] calc_angle_s(input [15:0] dur_st_w, input signed [16:0] amp_rs_w);
        begin
            if (amp_rs_w > 17'sd2000) begin
                if (dur_st_w < 16'd120)       calc_angle_s = 8'sd30;
                else if (dur_st_w < 16'd200)  calc_angle_s = 8'sd45;
                else                          calc_angle_s = 8'sd55;
            end else begin
                calc_angle_s = 8'sd65;
            end
        end
    endfunction

    // =========================================================================
    // 2. BLOK 1: SEKUENSIAL SINKRON (CLOCK & ASYNC RESET)
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_ps      <= S_IDLE;
            feat_valid_ps <= 1'b0;
            feat_busy_ps  <= 1'b0;

            feat_x1_ps    <= 8'sd0;
            feat_x2_ps    <= 8'sd0;
            feat_x3_ps    <= 8'sd0;
            feat_x4_ps    <= 8'sd0;
            feat_x5_ps    <= 8'sd0;
            feat_x6_ps    <= 8'sd0;
            feat_x7_ps    <= 8'sd0;
            feat_x8_ps    <= 8'sd0;
            feat_x9_ps    <= 8'sd0;
            feat_x10_ps   <= 8'sd0;
            feat_x11_ps   <= 8'sd0;
            feat_x12_ps   <= 8'sd0;
        end else if (ce) begin
            state_ps      <= state_ns;
            feat_valid_ps <= feat_valid_ns;
            feat_busy_ps  <= feat_busy_ns;

            feat_x1_ps    <= feat_x1_ns;
            feat_x2_ps    <= feat_x2_ns;
            feat_x3_ps    <= feat_x3_ns;
            feat_x4_ps    <= feat_x4_ns;
            feat_x5_ps    <= feat_x5_ns;
            feat_x6_ps    <= feat_x6_ns;
            feat_x7_ps    <= feat_x7_ns;
            feat_x8_ps    <= feat_x8_ns;
            feat_x9_ps    <= feat_x9_ns;
            feat_x10_ps   <= feat_x10_ns;
            feat_x11_ps   <= feat_x11_ns;
            feat_x12_ps   <= feat_x12_ns;
        end
    end

    // =========================================================================
    // 3. BLOK 2: LOGIKA KOMBINASIONAL NEXT-STATE & PERHITUNGAN FITUR (_ns)
    // =========================================================================
    always @(*) begin
        // Nilai default untuk mencegah inferensi latch
        state_ns      = state_ps;
        feat_valid_ns = 1'b0; // Default pulsa 1-clk
        feat_busy_ns  = feat_busy_ps;

        feat_x1_ns    = feat_x1_ps;
        feat_x2_ns    = feat_x2_ps;
        feat_x3_ns    = feat_x3_ps;
        feat_x4_ns    = feat_x4_ps;
        feat_x5_ns    = feat_x5_ps;
        feat_x6_ns    = feat_x6_ps;
        feat_x7_ns    = feat_x7_ps;
        feat_x8_ns    = feat_x8_ps;
        feat_x9_ns    = feat_x9_ps;
        feat_x10_ns   = feat_x10_ps;
        feat_x11_ns   = feat_x11_ps;
        feat_x12_ns   = feat_x12_ps;

        case (state_ps)
            // -----------------------------------------------------------------
            // S_IDLE: Menunggu pulsa pemicu qrst_done_o
            // -----------------------------------------------------------------
            S_IDLE: begin
                feat_busy_ns = 1'b0;
                if (features_ready_i) begin
                    state_ns     = S_CALC;
                    feat_busy_ns = 1'b1;
                end
            end

            // -----------------------------------------------------------------
            // S_CALC: Eksekusi komputasi 12 fitur dan simpan ke reg internal _ns
            // -----------------------------------------------------------------
            S_CALC: begin
                feat_busy_ns = 1'b1;

                // 1. Ekstraksi 3 Fitur Amplitudo
                feat_x1_ns = sat_int8(diff_rq_a >>> AMP_SHIFT_SCALE); // x1: RQ_A
                feat_x2_ns = sat_int8(diff_rs_a >>> AMP_SHIFT_SCALE); // x2: RS_A
                feat_x3_ns = sat_int8(diff_rt_a >>> AMP_SHIFT_SCALE); // x3: RT_A

                // 2. Ekstraksi 7 Fitur Interval Durasi Waktu
                feat_x4_ns = sat_int8({1'b0, dur_rq});                  // x4: RQ
                feat_x5_ns = sat_int8({1'b0, dur_rs});                  // x5: RS
                feat_x6_ns = sat_int8({1'b0, dur_rtl >>> TIME_SHIFT_SCALE}); // x6: RTL
                feat_x7_ns = sat_int8({1'b0, dur_rtr >>> TIME_SHIFT_SCALE}); // x7: RTR
                feat_x8_ns = sat_int8({1'b0, dur_qtci >>> TIME_SHIFT_SCALE});// x8: QTCI
                feat_x9_ns = sat_int8({1'b0, dur_sts});                 // x9: STS
                feat_x10_ns = sat_int8({1'b0, dur_sti >>> TIME_SHIFT_SCALE}); // x10: STI

                // 3. Ekstraksi 2 Fitur Sudut Geometri Vektor
                feat_x11_ns = calc_angle_r(dur_rq + dur_rs, diff_rs_a); // x11: Angle R
                feat_x12_ns = calc_angle_s(dur_sti, diff_rs_a);        // x12: Angle S

                state_ns = S_DONE;
            end

            // -----------------------------------------------------------------
            // S_DONE: Pancarkan pulsa feat_valid_o selama 1 clock cycle
            // -----------------------------------------------------------------
            S_DONE: begin
                feat_valid_ns = 1'b1;
                feat_busy_ns  = 1'b0;
                state_ns      = S_IDLE;
            end

            default: begin
                state_ns      = S_IDLE;
                feat_valid_ns = 1'b0;
                feat_busy_ns  = 1'b0;
            end
        endcase
    end

    // =========================================================================
    // 4. BLOK 3: PENUGASAN PORT OUTPUT (ASSIGN EKSPLISIT DARI _ps)
    // =========================================================================
    // Output kontroler FSM murni 1-bit
    assign feat_valid_o = feat_valid_ps;
    assign feat_busy_o  = feat_busy_ps;

    // Output 12 fitur individual dari register internal _ps
    assign feat_x1_o    = feat_x1_ps;
    assign feat_x2_o    = feat_x2_ps;
    assign feat_x3_o    = feat_x3_ps;
    assign feat_x4_o    = feat_x4_ps;
    assign feat_x5_o    = feat_x5_ps;
    assign feat_x6_o    = feat_x6_ps;
    assign feat_x7_o    = feat_x7_ps;
    assign feat_x8_o    = feat_x8_ps;
    assign feat_x9_o    = feat_x9_ps;
    assign feat_x10_o   = feat_x10_ps;
    assign feat_x11_o   = feat_x11_ps;
    assign feat_x12_o   = feat_x12_ps;

endmodule
