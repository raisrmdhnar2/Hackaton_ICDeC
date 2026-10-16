`timescale 1ns / 1ns
//////////////////////////////////////////////////////////////////////////////////
// Modul: ecg_bandpass_filter.v
// Proyek: Indonesia Chip Hackathon Challenge 2026 (DIICES UB)
// Deskripsi: Bandpass Filter Sinyal EKG Terintegrasi (0.5 Hz - 45 Hz) pada fs = 1000 Hz.
//            Arsitektur Terdiri atas 2 Tahap Cascade:
//            Tahap 1: DC-Blocker IIR 1-Pole (~0.5 Hz) bebas multiplier untuk
//                     menghilangkan Baseline Wander (artefak nafas/gerak pasien).
//                     y_hpf[n] = x[n] - x[n-1] + y_hpf[n-1] - (y_hpf[n-1] >>> 9)
//            Tahap 2: 21-Tap Linear Phase Symmetrical FIR (~45 Hz Low-Pass Filter)
//                     untuk meredam derau jala-jala listrik PLN 50/60 Hz dan EMG.
//                     Memiliki Constant Group Delay = 10 sampel tanpa distorsi fase.
//
// Standar Desain:
// - Seluruh port output bertipe 'output wire' (bebas dari 'output reg').
// - Bebas dari unpacked array pada port.
// - Registrasi output menggunakan konvensi _ps/_ns dan 'assign <port> = <signal>_ps;'.
//////////////////////////////////////////////////////////////////////////////////

module ecg_bandpass_filter (
    // Clock & Kontrol Global
    input  wire                      clk,
    input  wire                      rst_n,
    input  wire                      ce,

    // Masukan Data Sinyal EKG Mentah (Signed 16-Bit Q15)
    input  wire signed [15:0]        sample_in,
    input  wire                      sample_valid_i,

    // Keluaran Data Sinyal EKG Terfilter (Signed 16-Bit Q15)
    output wire signed [15:0]        filtered_sample_o,
    output wire                      filtered_valid_o
);

    // =========================================================================
    // PARAMETER KOEFISIEN FIR 21-TAP SIMETRIS (SCALE = 1024, LPF 45 Hz)
    // h = [1, 3, 7, 14, 27, 44, 63, 83, 100, 112, 116, 112, ... 1]
    // =========================================================================
    localparam signed [15:0] H0  = 16'sd1;
    localparam signed [15:0] H1  = 16'sd3;
    localparam signed [15:0] H2  = 16'sd7;
    localparam signed [15:0] H3  = 16'sd14;
    localparam signed [15:0] H4  = 16'sd27;
    localparam signed [15:0] H5  = 16'sd44;
    localparam signed [15:0] H6  = 16'sd63;
    localparam signed [15:0] H7  = 16'sd83;
    localparam signed [15:0] H8  = 16'sd100;
    localparam signed [15:0] H9  = 16'sd112;
    localparam signed [15:0] H10 = 16'sd116;

    // =========================================================================
    // REGISTER TAHAP 1: DC-BLOCKER HPF 0.5 Hz (PRESENT & NEXT STATE)
    // =========================================================================
    reg signed [15:0] prev_sample_ps, prev_sample_ns;
    reg signed [31:0] hpf_acc_ps,     hpf_acc_ns;

    // =========================================================================
    // REGISTER TAHAP 2: PIPELINE SHIFT REGISTER FIR 21-TAP
    // =========================================================================
    reg signed [15:0] tap0_ps,  tap0_ns;
    reg signed [15:0] tap1_ps,  tap1_ns;
    reg signed [15:0] tap2_ps,  tap2_ns;
    reg signed [15:0] tap3_ps,  tap3_ns;
    reg signed [15:0] tap4_ps,  tap4_ns;
    reg signed [15:0] tap5_ps,  tap5_ns;
    reg signed [15:0] tap6_ps,  tap6_ns;
    reg signed [15:0] tap7_ps,  tap7_ns;
    reg signed [15:0] tap8_ps,  tap8_ns;
    reg signed [15:0] tap9_ps,  tap9_ns;
    reg signed [15:0] tap10_ps, tap10_ns;
    reg signed [15:0] tap11_ps, tap11_ns;
    reg signed [15:0] tap12_ps, tap12_ns;
    reg signed [15:0] tap13_ps, tap13_ns;
    reg signed [15:0] tap14_ps, tap14_ns;
    reg signed [15:0] tap15_ps, tap15_ns;
    reg signed [15:0] tap16_ps, tap16_ns;
    reg signed [15:0] tap17_ps, tap17_ns;
    reg signed [15:0] tap18_ps, tap18_ns;
    reg signed [15:0] tap19_ps, tap19_ns;
    reg signed [15:0] tap20_ps, tap20_ns;

    // =========================================================================
    // REGISTER KELUARAN TERFILTER (PRESENT & NEXT STATE)
    // =========================================================================
    reg signed [15:0] filt_sample_ps, filt_sample_ns;
    reg               filt_valid_ps,  filt_valid_ns;

    // =========================================================================
    // LOGIKA SEQUENTIAL (UPDATE REGISTER STATE PADA POSEDGE CLK)
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prev_sample_ps <= 16'sd0;
            hpf_acc_ps     <= 32'sd0;

            tap0_ps  <= 16'sd0;
            tap1_ps  <= 16'sd0;
            tap2_ps  <= 16'sd0;
            tap3_ps  <= 16'sd0;
            tap4_ps  <= 16'sd0;
            tap5_ps  <= 16'sd0;
            tap6_ps  <= 16'sd0;
            tap7_ps  <= 16'sd0;
            tap8_ps  <= 16'sd0;
            tap9_ps  <= 16'sd0;
            tap10_ps <= 16'sd0;
            tap11_ps <= 16'sd0;
            tap12_ps <= 16'sd0;
            tap13_ps <= 16'sd0;
            tap14_ps <= 16'sd0;
            tap15_ps <= 16'sd0;
            tap16_ps <= 16'sd0;
            tap17_ps <= 16'sd0;
            tap18_ps <= 16'sd0;
            tap19_ps <= 16'sd0;
            tap20_ps <= 16'sd0;

            filt_sample_ps <= 16'sd0;
            filt_valid_ps  <= 1'b0;
        end else if (ce) begin
            prev_sample_ps <= prev_sample_ns;
            hpf_acc_ps     <= hpf_acc_ns;

            tap0_ps  <= tap0_ns;
            tap1_ps  <= tap1_ns;
            tap2_ps  <= tap2_ns;
            tap3_ps  <= tap3_ns;
            tap4_ps  <= tap4_ns;
            tap5_ps  <= tap5_ns;
            tap6_ps  <= tap6_ns;
            tap7_ps  <= tap7_ns;
            tap8_ps  <= tap8_ns;
            tap9_ps  <= tap9_ns;
            tap10_ps <= tap10_ns;
            tap11_ps <= tap11_ns;
            tap12_ps <= tap12_ns;
            tap13_ps <= tap13_ns;
            tap14_ps <= tap14_ns;
            tap15_ps <= tap15_ns;
            tap16_ps <= tap16_ns;
            tap17_ps <= tap17_ns;
            tap18_ps <= tap18_ns;
            tap19_ps <= tap19_ns;
            tap20_ps <= tap20_ns;

            filt_sample_ps <= filt_sample_ns;
            filt_valid_ps  <= filt_valid_ns;
        end
    end

    // =========================================================================
    // LOGIKA KOMBINATORIAL (PROSES FILTERING DUA TAHAP HPF + LPF)
    // =========================================================================
    // Sinyal Internal Tahap 1 (HPF)
    reg signed [16:0] diff_sample;
    reg signed [31:0] next_hpf_acc;
    reg signed [31:0] hpf_scaled;
    reg signed [15:0] hpf_out;

    // Sinyal Internal Tahap 2 (Symmetric FIR Sum of Products)
    reg signed [16:0] sum_p0, sum_p1, sum_p2, sum_p3, sum_p4;
    reg signed [16:0] sum_p5, sum_p6, sum_p7, sum_p8, sum_p9;
    reg signed [31:0] fir_acc;
    reg signed [31:0] fir_scaled;

    always @(*) begin
        // Anti-Latch Default Assignment
        prev_sample_ns = prev_sample_ps;
        hpf_acc_ns     = hpf_acc_ps;

        tap0_ns  = tap0_ps;
        tap1_ns  = tap1_ps;
        tap2_ns  = tap2_ps;
        tap3_ns  = tap3_ps;
        tap4_ns  = tap4_ps;
        tap5_ns  = tap5_ps;
        tap6_ns  = tap6_ps;
        tap7_ns  = tap7_ps;
        tap8_ns  = tap8_ps;
        tap9_ns  = tap9_ps;
        tap10_ns = tap10_ps;
        tap11_ns = tap11_ps;
        tap12_ns = tap12_ps;
        tap13_ns = tap13_ps;
        tap14_ns = tap14_ps;
        tap15_ns = tap15_ps;
        tap16_ns = tap16_ps;
        tap17_ns = tap17_ps;
        tap18_ns = tap18_ps;
        tap19_ns = tap19_ps;
        tap20_ns = tap20_ps;

        filt_sample_ns = filt_sample_ps;
        filt_valid_ns  = 1'b0;

        diff_sample  = 17'sd0;
        next_hpf_acc = 32'sd0;
        hpf_scaled   = 32'sd0;
        hpf_out      = 16'sd0;

        sum_p0  = 17'sd0;
        sum_p1  = 17'sd0;
        sum_p2  = 17'sd0;
        sum_p3  = 17'sd0;
        sum_p4  = 17'sd0;
        sum_p5  = 17'sd0;
        sum_p6  = 17'sd0;
        sum_p7  = 17'sd0;
        sum_p8  = 17'sd0;
        sum_p9  = 17'sd0;
        fir_acc = 32'sd0;
        fir_scaled = 32'sd0;

        if (sample_valid_i) begin
            // -----------------------------------------------------------------
            // TAHAP 1: HPF DC-BLOCKER 0.5 Hz
            // acc[n] = acc[n-1] + ((x[n] - x[n-1]) <<< 14) - (acc[n-1] >>> 9)
            // -----------------------------------------------------------------
            diff_sample    = sample_in - prev_sample_ps;
            prev_sample_ns = sample_in;

            next_hpf_acc   = hpf_acc_ps + (diff_sample <<< 14) - (hpf_acc_ps >>> 9);
            hpf_acc_ns     = next_hpf_acc;

            hpf_scaled     = next_hpf_acc >>> 14;

            // Saturasi Proteksi 16-Bit
            if (hpf_scaled > 32'sd32767)
                hpf_out = 16'sd32767;
            else if (hpf_scaled < -32'sd32768)
                hpf_out = -16'sd32768;
            else
                hpf_out = hpf_scaled[15:0];

            // -----------------------------------------------------------------
            // TAHAP 2: SHIFT REGISTER FIR 21-TAP
            // Geser sampel keluaran HPF ke dalam tap buffer FIR
            // -----------------------------------------------------------------
            tap0_ns  = hpf_out;
            tap1_ns  = tap0_ps;
            tap2_ns  = tap1_ps;
            tap3_ns  = tap2_ps;
            tap4_ns  = tap3_ps;
            tap5_ns  = tap4_ps;
            tap6_ns  = tap5_ps;
            tap7_ns  = tap6_ps;
            tap8_ns  = tap7_ps;
            tap9_ns  = tap8_ps;
            tap10_ns = tap9_ps;
            tap11_ns = tap10_ps;
            tap12_ns = tap11_ps;
            tap13_ns = tap12_ps;
            tap14_ns = tap13_ps;
            tap15_ns = tap14_ps;
            tap16_ns = tap15_ps;
            tap17_ns = tap16_ps;
            tap18_ns = tap17_ps;
            tap19_ns = tap18_ps;
            tap20_ns = tap19_ps;

            // -----------------------------------------------------------------
            // PERKALIAN & PENJUMLAHAN SIMETRIS FIR (LPF 45 Hz)
            // Memanfaatkan sifat simetris h[k] = h[20-k] untuk efisiensi DSP
            // -----------------------------------------------------------------
            sum_p0 = tap0_ns  + tap19_ps; // tap0_ns (baru) berpasangan dengan tap20_ns = tap19_ps
            sum_p1 = tap1_ns  + tap18_ps;
            sum_p2 = tap2_ns  + tap17_ps;
            sum_p3 = tap3_ns  + tap16_ps;
            sum_p4 = tap4_ns  + tap15_ps;
            sum_p5 = tap5_ns  + tap14_ps;
            sum_p6 = tap6_ns  + tap13_ps;
            sum_p7 = tap7_ns  + tap12_ps;
            sum_p8 = tap8_ns  + tap11_ps;
            sum_p9 = tap9_ns  + tap10_ps;

            fir_acc = (sum_p0 * H0) +
                      (sum_p1 * H1) +
                      (sum_p2 * H2) +
                      (sum_p3 * H3) +
                      (sum_p4 * H4) +
                      (sum_p5 * H5) +
                      (sum_p6 * H6) +
                      (sum_p7 * H7) +
                      (sum_p8 * H8) +
                      (sum_p9 * H9) +
                      (tap10_ns * H10);

            // Normalisasi Skala FIR (Pembagian 1024 melalui bitshift >>> 10)
            fir_scaled = fir_acc >>> 10;

            // Saturasi Proteksi 16-Bit Keluaran
            if (fir_scaled > 32'sd32767)
                filt_sample_ns = 16'sd32767;
            else if (fir_scaled < -32'sd32768)
                filt_sample_ns = -16'sd32768;
            else
                filt_sample_ns = fir_scaled[15:0];

            filt_valid_ns = 1'b1;
        end
    end

    // =========================================================================
    // PENUGASAN PORT OUTPUT DARI PRESENT STATE
    // Standar: assign <port> = <signal>_ps;
    // =========================================================================
    assign filtered_sample_o = filt_sample_ps;
    assign filtered_valid_o  = filt_valid_ps;

endmodule

