`timescale 1ns / 1ns
//////////////////////////////////////////////////////////////////////////////////
// Modul: qst_detector_fsm.v
// Proyek: Indonesia Chip Hackathon Challenge 2026 (DIICES UB)
// Deskripsi: FSM Moore Controller untuk deteksi sekuensial Q, S, dan T (R -> Q -> S -> T)
//            berbasis Shift Register dan Divider-Free Heart Rate Calculator.
//
// Standar Desain:
// - FSM Moore dengan state_ps dan state_ns.
// - Register internal menggunakan konvensi _ps dan _ns.
// - Seluruh port output bertipe 'output wire' (tidak boleh output reg).
// - Port data amplitudo, timestamp, marker, dan BPM menggunakan bus wire [lebar:0].
// - Penugasan akhir konsisten menggunakan 'assign <port> = <signal>_ps;'.
//////////////////////////////////////////////////////////////////////////////////

module qst_detector_fsm (
    // Clock & Kontrol Utama
    input  wire                      clk,
    input  wire                      rst_n,
    input  wire                      ce,

    // Sinyal Pemicu dari R-Detector (1-Bit Pulse & Data)
    input  wire                      t_r_i,               // Pulsa tanda terdeteksi puncak R (1-clk)
    input  wire signed [15:0]        r_amp_i,             // Amplitudo puncak R terkunci

    // Masukan Data dari Shift Register Buffer & Jalur Sinyal
    input  wire signed [15:0]        delayed_sample_i,    // Sampel riwayat pada read_addr_o
    input  wire signed [15:0]        sample_raw_i,        // Sampel terfilter terkini x[n]
    input  wire        [15:0]        sample_cnt_i,        // Timestamp sampel global
    input  wire                      sample_valid_i,

    // Port Kontrol Pembacaan Shift Register
    output wire        [5:0]         read_addr_o,         // Alamat offset scan buffer Q

    // Sinyal Tanda Waktu Gelombang QRST (1-Bit Wire Pulse)
    output wire                      t_q_o,               // Pulsa tanda gelombang Q
    output wire                      t_s_o,               // Pulsa tanda gelombang S (di lembah akhir)
    output wire                      t_t_o,               // Pulsa tanda puncak gelombang T
    output wire                      t_on_o,              // Pulsa tanda onset gelombang T
    output wire                      t_off_o,             // Pulsa tanda offset gelombang T
    output wire                      s_off_o,             // Pulsa tanda titik J (S offset)
    output wire                      qrst_done_o,         // Pulsa 1-clk: seluruh beat selesai dikunci

    // Sinyal Koordinat Waktu Timestamp Numerik Terkunci (16-Bit Wire)
    output wire        [15:0]        t_q_val_o,
    output wire        [15:0]        t_r_val_o,
    output wire        [15:0]        t_s_val_o,
    output wire        [15:0]        t_on_val_o,
    output wire        [15:0]        t_off_val_o,
    output wire        [15:0]        s_off_val_o,

    // Sinyal Koordinat Amplitudo QRST Terkunci (Signed 16-Bit Q15 Wire)
    output wire signed [15:0]        q_amp_o,
    output wire signed [15:0]        s_amp_o,
    output wire signed [15:0]        t_amp_o,
    output wire signed [15:0]        st_elev_o,
    output wire signed [15:0]        iso_base_o,

    // Penanda Real-Time & Telemetri
    output wire        [7:0]         qrst_marker_o,       // Marker gelombang
    output wire        [7:0]         heart_rate_bpm_o     // Denyut Jantung (BPM)
);

    // =========================================================================
    // 1. STATE ENCODING (FSM MOORE 3-ALWAYS BLOCK)
    // =========================================================================
    localparam [2:0]
        S_IDLE   = 3'd0,
        S_SCAN_Q = 3'd1,
        S_SCAN_S = 3'd2,
        S_SCAN_T = 3'd3,
        S_DONE   = 3'd4;

    reg [2:0] state_ps, state_ns;

    // Register internal status dan alamat buffer (_ps dan _ns)
    reg [5:0] read_addr_ps, read_addr_ns;
    reg [5:0] scan_q_cnt_ps, scan_q_cnt_ns;

    // Register internal data amplitudo QRST (_ps dan _ns)
    reg signed [15:0] q_amp_ps, q_amp_ns;
    reg signed [15:0] s_amp_ps, s_amp_ns;
    reg signed [15:0] t_amp_ps, t_amp_ns;
    reg signed [15:0] st_elev_ps, st_elev_ns;
    reg signed [15:0] iso_base_ps, iso_base_ns;

    // Register internal data waktu / timestamp numerik (_ps dan _ns)
    reg [15:0] t_r_val_ps,   t_r_val_ns;
    reg [15:0] t_q_val_ps,   t_q_val_ns;
    reg [15:0] t_s_val_ps,   t_s_val_ns;
    reg [15:0] t_t_val_ps,   t_t_val_ns;
    reg [15:0] t_on_val_ps,  t_on_val_ns;
    reg [15:0] t_off_val_ps, t_off_val_ns;
    reg [15:0] s_off_val_ps, s_off_val_ns;

    // Register internal pulsa tanda gelombang (1-bit _ps dan _ns)
    reg t_q_ps,       t_q_ns;
    reg t_s_ps,       t_s_ns;
    reg t_t_ps,       t_t_ns;
    reg t_on_ps,      t_on_ns;
    reg t_off_ps,     t_off_ns;
    reg s_off_ps,     s_off_ns;
    reg done_ps,      done_ns;

    // Penanda marker & BPM (_ps dan _ns)
    reg [7:0]  marker_ps, marker_ns;
    reg [7:0]  bpm_ps, bpm_ns;

    // Register penunjang kalkulasi lokal (_ps dan _ns)
    reg [15:0] timer_fsm_ps, timer_fsm_ns;
    reg signed [15:0] min_q_val_ps, min_q_val_ns;
    reg [15:0] min_q_pos_ps, min_q_pos_ns;
    reg signed [15:0] min_s_val_ps, min_s_val_ns;
    reg [15:0] min_s_pos_ps, min_s_pos_ns;
    reg        s_found_ps, s_found_ns;
    reg signed [15:0] max_t_val_ps, max_t_val_ns;
    reg [15:0] max_t_pos_ps, max_t_pos_ns;
    reg        t_found_ps, t_found_ns;
    reg        t_on_found_ps, t_on_found_ns;

    // Register riwayat puncak R untuk kalkulasi RR-interval
    reg [15:0] last_r_time_ps, last_r_time_ns;
    reg [15:0] rr_interval_ps, rr_interval_ns;

    // =========================================================================
    // 2. BLOK 1: SEKUENSIAL SINKRON (CLOCK & ASYNC RESET)
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_ps        <= S_IDLE;
            read_addr_ps    <= 6'd0;
            scan_q_cnt_ps   <= 6'd0;
            q_amp_ps        <= 16'sd0;
            s_amp_ps        <= 16'sd0;
            t_amp_ps        <= 16'sd0;
            st_elev_ps      <= 16'sd0;
            iso_base_ps     <= 16'sd0;

            t_r_val_ps      <= 16'd0;
            t_q_val_ps      <= 16'd0;
            t_s_val_ps      <= 16'd0;
            t_t_val_ps      <= 16'd0;
            t_on_val_ps     <= 16'd0;
            t_off_val_ps    <= 16'd0;
            s_off_val_ps    <= 16'd0;

            t_q_ps          <= 1'b0;
            t_s_ps          <= 1'b0;
            t_t_ps          <= 1'b0;
            t_on_ps         <= 1'b0;
            t_off_ps        <= 1'b0;
            s_off_ps        <= 1'b0;
            done_ps         <= 1'b0;

            marker_ps       <= 8'd0;
            bpm_ps          <= 8'd75; // Nilai default wajar denyut jantung

            timer_fsm_ps    <= 16'd0;
            min_q_val_ps    <= 16'sh7FFF;
            min_q_pos_ps    <= 16'd0;
            min_s_val_ps    <= 16'sh7FFF;
            min_s_pos_ps    <= 16'd0;
            s_found_ps      <= 1'b0;
            max_t_val_ps    <= -16'sh7FFF;
            max_t_pos_ps    <= 16'd0;
            t_found_ps      <= 1'b0;
            t_on_found_ps   <= 1'b0;

            last_r_time_ps  <= 16'd0;
            rr_interval_ps  <= 16'd1000;
        end else if (ce) begin
            state_ps        <= state_ns;
            read_addr_ps    <= read_addr_ns;
            scan_q_cnt_ps   <= scan_q_cnt_ns;
            q_amp_ps        <= q_amp_ns;
            s_amp_ps        <= s_amp_ns;
            t_amp_ps        <= t_amp_ns;
            st_elev_ps      <= st_elev_ns;
            iso_base_ps     <= iso_base_ns;

            t_r_val_ps      <= t_r_val_ns;
            t_q_val_ps      <= t_q_val_ns;
            t_s_val_ps      <= t_s_val_ns;
            t_t_val_ps      <= t_t_val_ns;
            t_on_val_ps     <= t_on_val_ns;
            t_off_val_ps    <= t_off_val_ns;
            s_off_val_ps    <= s_off_val_ns;

            t_q_ps          <= t_q_ns;
            t_s_ps          <= t_s_ns;
            t_t_ps          <= t_t_ns;
            t_on_ps         <= t_on_ns;
            t_off_ps        <= t_off_ns;
            s_off_ps        <= s_off_ns;
            done_ps         <= done_ns;

            marker_ps       <= marker_ns;
            bpm_ps          <= bpm_ns;

            timer_fsm_ps    <= timer_fsm_ns;
            min_q_val_ps    <= min_q_val_ns;
            min_q_pos_ps    <= min_q_pos_ns;
            min_s_val_ps    <= min_s_val_ns;
            min_s_pos_ps    <= min_s_pos_ns;
            s_found_ps      <= s_found_ns;
            max_t_val_ps    <= max_t_val_ns;
            max_t_pos_ps    <= max_t_pos_ns;
            t_found_ps      <= t_found_ns;
            t_on_found_ps   <= t_on_found_ns;

            last_r_time_ps  <= last_r_time_ns;
            rr_interval_ps  <= rr_interval_ns;
        end
    end

    // =========================================================================
    // LOOK-UP TABLE (LUT ROM) UNTUK KALKULASI BPM (DIVIDER-FREE)
    // BPM = 60,000 ms / RR_interval_ms
    // =========================================================================
    function [7:0] calc_bpm(input [15:0] rr_ms);
        begin
            if (rr_ms <= 16'd350)        calc_bpm = 8'd170;
            else if (rr_ms <= 16'd400)   calc_bpm = 8'd150;
            else if (rr_ms <= 16'd460)   calc_bpm = 8'd130;
            else if (rr_ms <= 16'd500)   calc_bpm = 8'd120;
            else if (rr_ms <= 16'd550)   calc_bpm = 8'd109;
            else if (rr_ms <= 16'd600)   calc_bpm = 8'd100;
            else if (rr_ms <= 16'd650)   calc_bpm = 8'd92;
            else if (rr_ms <= 16'd700)   calc_bpm = 8'd86;
            else if (rr_ms <= 16'd750)   calc_bpm = 8'd80;
            else if (rr_ms <= 16'd800)   calc_bpm = 8'd75;
            else if (rr_ms <= 16'd850)   calc_bpm = 8'd70;
            else if (rr_ms <= 16'd900)   calc_bpm = 8'd67;
            else if (rr_ms <= 16'd1000)  calc_bpm = 8'd60;
            else if (rr_ms <= 16'd1100)  calc_bpm = 8'd55;
            else if (rr_ms <= 16'd1200)  calc_bpm = 8'd50;
            else                         calc_bpm = 8'd45;
        end
    endfunction

    // =========================================================================
    // 3. BLOK 2: KOMBINASIONAL TRANSISI STATE & NEXT-STATE LOGIC
    // =========================================================================
    always @(*) begin
        // Nilai default untuk mencegah inferensi latch
        state_ns        = state_ps;
        read_addr_ns    = read_addr_ps;
        scan_q_cnt_ns   = scan_q_cnt_ps;
        q_amp_ns        = q_amp_ps;
        s_amp_ns        = s_amp_ps;
        t_amp_ns        = t_amp_ps;
        st_elev_ns      = st_elev_ps;
        iso_base_ns     = iso_base_ps;

        t_r_val_ns      = t_r_val_ps;
        t_q_val_ns      = t_q_val_ps;
        t_s_val_ns      = t_s_val_ps;
        t_t_val_ns      = t_t_val_ps;
        t_on_val_ns     = t_on_val_ps;
        t_off_val_ns    = t_off_val_ps;
        s_off_val_ns    = s_off_val_ps;

        // Default pulsa 1-clk (semua pulsa kembali ke 0 kecuali di-trigger)
        t_q_ns          = 1'b0;
        t_s_ns          = 1'b0;
        t_t_ns          = 1'b0;
        t_on_ns         = 1'b0;
        t_off_ns        = 1'b0;
        s_off_ns        = 1'b0;
        done_ns         = 1'b0;

        marker_ns       = marker_ps;
        bpm_ns          = bpm_ps;

        timer_fsm_ns    = timer_fsm_ps;
        min_q_val_ns    = min_q_val_ps;
        min_q_pos_ns    = min_q_pos_ns;
        min_s_val_ns    = min_s_val_ps;
        min_s_pos_ns    = min_s_pos_ns;
        s_found_ns      = s_found_ps;
        max_t_val_ns    = max_t_val_ps;
        max_t_pos_ns    = max_t_pos_ns;
        t_found_ns      = t_found_ps;
        t_on_found_ns   = t_on_found_ps;

        last_r_time_ns  = last_r_time_ps;
        rr_interval_ns  = rr_interval_ps;

        case (state_ps)
            // -----------------------------------------------------------------
            // S_IDLE: Menunggu pulsa terdeteksi puncak R (t_r_i)
            // -----------------------------------------------------------------
            S_IDLE: begin
                read_addr_ns = 6'd0;
                if (t_r_i) begin
                    state_ns     = S_SCAN_Q;
                    t_r_val_ns   = sample_cnt_i; // Waktu R disimpan di reg internal
                    marker_ns    = 8'h01;        // Marker R

                    // Hitung RR-interval dan estimasi BPM via LUT
                    if (last_r_time_ps != 16'd0 && (sample_cnt_i > last_r_time_ps)) begin
                        rr_interval_ns = sample_cnt_i - last_r_time_ps;
                        bpm_ns         = calc_bpm(sample_cnt_i - last_r_time_ps);
                    end
                    last_r_time_ns = sample_cnt_i;

                    // Mulai scan mundur ke Shift Register untuk mencari gelombang Q
                    scan_q_cnt_ns = 6'd2;        // Lewati sampel R terdekat
                    read_addr_ns  = 6'd2;
                    min_q_val_ns  = 16'sh7FFF;
                    min_q_pos_ns  = sample_cnt_i - 16'd2;
                end
            end

            // -----------------------------------------------------------------
            // S_SCAN_Q: Memindai jendela riwayat [2..45 ms] mundur dari R
            // -----------------------------------------------------------------
            S_SCAN_Q: begin
                // Update minimum lembah Q pada sampel tertunda yang terbaca
                if (delayed_sample_i < min_q_val_ps) begin
                    min_q_val_ns = delayed_sample_i;
                    min_q_pos_ns = t_r_val_ps - {10'd0, scan_q_cnt_ps};
                end

                // Geser alamat scan mundur 1 tap
                scan_q_cnt_ns = scan_q_cnt_ps + 6'd1;
                read_addr_ns  = scan_q_cnt_ps + 6'd1;

                // Ambil baseline isoelektrik di ujung PR-segment (tap 45)
                if (scan_q_cnt_ps == 6'd45) begin
                    iso_base_ns   = delayed_sample_i;
                end

                // Akhir jendela pencarian Q (50 tap = ~50 ms sebelum R)
                if (scan_q_cnt_ps >= 6'd50) begin
                    state_ns      = S_SCAN_S;
                    t_q_ns        = 1'b1;         // Pulsa 1-clk tanda Q
                    t_q_val_ns    = min_q_pos_ps; // Waktu Q disimpan di reg internal
                    q_amp_ns      = min_q_val_ps; // Amplitudo Q disimpan di reg internal
                    marker_ns     = 8'h02;        // Marker Q

                    // Inisialisasi pelacakan real-time lembah S
                    timer_fsm_ns  = 16'd0;
                    min_s_val_ns  = 16'sh7FFF;
                    min_s_pos_ns  = sample_cnt_i;
                    s_found_ns    = 1'b0;
                end
            end

            // -----------------------------------------------------------------
            // S_SCAN_S: Melacak lembah akhir gelombang S secara real-time
            // -----------------------------------------------------------------
            S_SCAN_S: begin
                if (sample_valid_i) begin
                    timer_fsm_ns = timer_fsm_ps + 16'd1;

                    // Pelacakan nilai minimum mutlak di lembah S
                    if (sample_raw_i < min_s_val_ps) begin
                        min_s_val_ns = sample_raw_i;
                        min_s_pos_ns = sample_cnt_i;
                    end

                    // Deteksi kurva berbalik naik setelah lembah sejati tercapai (15 - 70 ms)
                    if (!s_found_ps && (timer_fsm_ps >= 16'd15)) begin
                        if ((sample_raw_i >= min_s_val_ps + 16'sd30) || (timer_fsm_ps >= 16'd70)) begin
                            s_found_ns   = 1'b1;
                            t_s_ns       = 1'b1;         // Pulsa 1-clk tanda S tepat di lembah akhir
                            t_s_val_ns   = min_s_pos_ps; // Waktu S disimpan di reg internal
                            s_amp_ns     = min_s_val_ps; // Amplitudo S disimpan di reg internal
                            s_off_val_ns = sample_cnt_i; // Titik J (S offset)
                            s_off_ns     = 1'b1;         // Pulsa 1-clk tanda titik J
                            marker_ns    = 8'h03;        // Marker S
                            st_elev_ns   = sample_raw_i - iso_base_ps; // Elevasi ST
                        end
                    end

                    // Transisi ke pencarian gelombang T setelah segmen S selesai (~80 ms pasca-R)
                    if (timer_fsm_ps >= 16'd80) begin
                        state_ns      = S_SCAN_T;
                        if (!s_found_ps) begin
                            t_s_ns       = 1'b1;
                            t_s_val_ns   = min_s_pos_ps;
                            s_amp_ns     = min_s_val_ps;
                            s_off_val_ns = sample_cnt_i;
                            s_off_ns     = 1'b1;
                        end
                        // Persiapan pelacakan gelombang T
                        max_t_val_ns  = -16'sh7FFF;
                        max_t_pos_ns  = sample_cnt_i;
                        t_found_ns    = 1'b0;
                        t_on_found_ns = 1'b0;
                    end
                end
            end

            // -----------------------------------------------------------------
            // S_SCAN_T: Melacak puncak gelombang T, Onset, dan Offset (J-T window)
            // -----------------------------------------------------------------
            S_SCAN_T: begin
                if (sample_valid_i) begin
                    timer_fsm_ns = timer_fsm_ps + 16'd1;

                    // T onset: saat sinyal melampaui baseline + margin (120 - 220 ms)
                    if (!t_on_found_ps && (timer_fsm_ps >= 16'd120)) begin
                        if (sample_raw_i > (iso_base_ps + 16'sd50)) begin
                            t_on_found_ns = 1'b1;
                            t_on_ns       = 1'b1;         // Pulsa 1-clk onset T
                            t_on_val_ns   = sample_cnt_i; // Waktu onset T
                        end
                    end

                    // Pelacakan puncak tertinggi gelombang T (140 - 380 ms)
                    if (timer_fsm_ps >= 16'd140 && timer_fsm_ps <= 16'd380) begin
                        if (sample_raw_i > max_t_val_ps) begin
                            max_t_val_ns = sample_raw_i;
                            max_t_pos_ns = sample_cnt_i;
                        end
                    end

                    // Pancarkan tanda puncak T saat lereng mulai melandai turun
                    if (!t_found_ps && (timer_fsm_ps >= 16'd250)) begin
                        if (sample_raw_i < (max_t_val_ps - 16'sd40) || (timer_fsm_ps >= 16'd350)) begin
                            t_found_ns = 1'b1;
                            t_t_ns     = 1'b1;            // Pulsa 1-clk puncak T
                            t_t_val_ns = max_t_pos_ps;    // Waktu puncak T
                            t_amp_ns   = max_t_val_ps;    // Amplitudo puncak T
                            marker_ns  = 8'h04;           // Marker T
                        end
                    end

                    // T offset: saat kurva kembali menyentuh baseline setelah puncak T
                    if (t_found_ps && !done_ps && (timer_fsm_ps >= 16'd320)) begin
                        if ((sample_raw_i <= (iso_base_ps + 16'sd60)) || (timer_fsm_ps >= 16'd450)) begin
                            t_off_ns     = 1'b1;          // Pulsa 1-clk offset T
                            t_off_val_ns = sample_cnt_i;  // Waktu offset T
                            state_ns     = S_DONE;
                        end
                    end

                    // Batas waktu penyelamat (Timeout safe exit @ 460 ms)
                    if (timer_fsm_ps >= 16'd460) begin
                        t_off_ns     = 1'b1;
                        t_off_val_ns = sample_cnt_i;
                        state_ns     = S_DONE;
                    end
                end
            end

            // -----------------------------------------------------------------
            // S_DONE: Seluruh parameter beat lengkap terkunci
            // -----------------------------------------------------------------
            S_DONE: begin
                done_ns   = 1'b1; // Pulsa 1-clk seluruh beat selesai dikunci
                state_ns  = S_IDLE;
            end

            default: begin
                state_ns = S_IDLE;
                done_ns  = 1'b0;
            end
        endcase
    end

    // =========================================================================
    // 4. BLOK 3: PENUGASAN PORT OUTPUT (ASSIGN EKSPLISIT DARI _ps)
    // =========================================================================
    // Output kontroler pembacaan shift register
    assign read_addr_o      = read_addr_ps;

    // Output tanda pulsa murni 1-bit wire dari register _ps
    assign t_q_o            = t_q_ps;
    assign t_s_o            = t_s_ps;
    assign t_t_o            = t_t_ps;
    assign t_on_o           = t_on_ps;
    assign t_off_o          = t_off_ps;
    assign s_off_o          = s_off_ps;
    assign qrst_done_o      = done_ps;

    // Output data koordinat waktu timestamp numerik (16-bit wire)
    assign t_q_val_o        = t_q_val_ps;
    assign t_r_val_o        = t_r_val_ps;
    assign t_s_val_o        = t_s_val_ps;
    assign t_on_val_o       = t_on_val_ps;
    assign t_off_val_o      = t_off_val_ps;
    assign s_off_val_o      = s_off_val_ps;

    // Output data amplitudo signed 16-bit wire
    assign q_amp_o          = q_amp_ps;
    assign s_amp_o          = s_amp_ps;
    assign t_amp_o          = t_amp_ps;
    assign st_elev_o        = st_elev_ps;
    assign iso_base_o       = iso_base_ps;

    // Output telemetri marker & BPM wire
    assign qrst_marker_o    = marker_ps;
    assign heart_rate_bpm_o = bpm_ps;

endmodule
