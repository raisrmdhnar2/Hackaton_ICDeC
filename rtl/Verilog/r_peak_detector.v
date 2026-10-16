`timescale 1ns / 1ns
//////////////////////////////////////////////////////////////////////////////////
// Modul: r_peak_detector.v
// Proyek: Indonesia Chip Hackathon Challenge 2026 (DIICES UB)
// Deskripsi: Detektor puncak R berbasis 3-Tap Sliding Window dan FSM Moore.
//
// Standar Desain:
// - Header modul: seluruh port output bertipe 'output wire' (bukan output reg).
// - Port tanda kontrol 1-bit wire (t_r_o) dan port data amplitudo signed [15:0] wire.
// - Seluruh nilai data disimpan di register internal _ps dan _ns.
// - Penugasan akhir konsisten menggunakan 'assign <port> = <signal>_ps;'.
//////////////////////////////////////////////////////////////////////////////////

module r_peak_detector #(
    parameter integer R_THRESH_INIT   = 350,       // Ambang batas awal diturunkan ke 350 agar mendeteksi R tertekan pada MI
    parameter integer REFRACTORY_SAMP = 250        // Periode refraktori R (~250 ms)
)(
    input  wire                      clk,
    input  wire                      rst_n,
    input  wire                      ce,
    input  wire signed [15:0]        tap0_i,       // x[n]
    input  wire signed [15:0]        tap1_i,       // x[n-1] (kandidat puncak)
    input  wire signed [15:0]        tap2_i,       // x[n-2]
    input  wire        [15:0]        sample_cnt_i, // Timestamp sampel global
    input  wire                      sample_valid_i,

    // Header output bertipe wire
    output wire                      t_r_o,        // Pulsa tanda terdeteksi puncak R (1-clk)
    output wire signed [15:0]        r_amp_o       // Amplitudo puncak R terkunci
);

    // =========================================================================
    // 1. STATE ENCODING (FSM MOORE)
    // =========================================================================
    localparam [1:0]
        S_IDLE   = 2'b00,
        S_PEAK   = 2'b01;

    reg [1:0] state_ps, state_ns;

    // Register internal (_ps dan _ns)
    reg               t_r_ps, t_r_ns;              // Register pulsa tanda R (1-bit)
    reg        [15:0] t_r_val_ps, t_r_val_ns;      // Data waktu (timestamp) disimpan di reg internal
    reg signed [15:0] r_amp_ps, r_amp_ns;          // Data amplitudo disimpan di reg internal
    reg signed [15:0] threshold_ps, threshold_ns;
    reg        [15:0] ref_cnt_ps, ref_cnt_ns;

    // Evaluasi kondisi ekstremum lokal 3-titik
    wire is_local_max = (tap1_i > tap2_i) && 
                        (tap1_i >= tap0_i) && 
                        (tap1_i > threshold_ps) && 
                        (ref_cnt_ps >= REFRACTORY_SAMP[15:0]);

    // =========================================================================
    // 2. BLOK SEKUENSIAL SINKRON (CLOCK & ASYNC RESET)
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_ps     <= S_IDLE;
            t_r_ps       <= 1'b0;
            t_r_val_ps   <= 16'd0;
            r_amp_ps     <= 16'sd0;
            threshold_ps <= R_THRESH_INIT[15:0];
            ref_cnt_ps   <= REFRACTORY_SAMP[15:0];
        end else if (ce) begin
            state_ps     <= state_ns;
            t_r_ps       <= t_r_ns;
            t_r_val_ps   <= t_r_val_ns;
            r_amp_ps     <= r_amp_ns;
            threshold_ps <= threshold_ns;
            ref_cnt_ps   <= ref_cnt_ns;
        end
    end

    // =========================================================================
    // 3. BLOK KOMBINASIONAL TRANSISI STATE & NEXT-STATE LOGIC
    // =========================================================================
    always @(*) begin
        // Nilai default untuk mencegah inferensi latch
        state_ns     = state_ps;
        t_r_ns       = 1'b0; // Default pulsa strobo 1-clk
        t_r_val_ns   = t_r_val_ps;
        r_amp_ns     = r_amp_ps;
        threshold_ns = threshold_ps;
        ref_cnt_ns   = ref_cnt_ps;

        // Pencacah refraktori bertambah per sampel
        if (sample_valid_i) begin
            if (ref_cnt_ps < 16'hFFFF) begin
                ref_cnt_ns = ref_cnt_ps + 16'd1;
            end
            // Threshold decay: jika tidak ada detak selama > 600 sampel (600 ms),
            // turunkan ambang batas secara gradual mendekati batas awal R_THRESH_INIT
            if (ref_cnt_ps > 16'd600 && threshold_ps > R_THRESH_INIT[15:0]) begin
                threshold_ns = threshold_ps - 16'd2;
            end
        end

        case (state_ps)
            S_IDLE: begin
                if (sample_valid_i && is_local_max) begin
                    state_ns     = S_PEAK;
                    t_r_ns       = 1'b1;                 // Pulsa tanda terdeteksi R
                    t_r_val_ns   = sample_cnt_i - 16'd1; // Data waktu R disimpan di reg internal
                    r_amp_ns     = tap1_i;               // Amplitudo R disimpan di reg internal
                    ref_cnt_ns   = 16'd0;                // Reset timer refraktori

                    // Ambang batas adaptif dinamis: 62.5% dari puncak R (R * 5/8)
                    threshold_ns = (tap1_i >>> 1) + (tap1_i >>> 3);
                end
            end

            S_PEAK: begin
                // State satu siklus untuk memancarkan strobo Moore
                state_ns = S_IDLE;
                t_r_ns   = 1'b0;
            end

            default: begin
                state_ns = S_IDLE;
                t_r_ns   = 1'b0;
            end
        endcase
    end

    // =========================================================================
    // 4. PENUGASAN PORT OUTPUT (ASSIGN EKSPLISIT DARI _ps)
    // =========================================================================
    assign t_r_o   = t_r_ps;
    assign r_amp_o = r_amp_ps;

endmodule
