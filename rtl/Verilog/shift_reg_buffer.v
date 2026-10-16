`timescale 1ns / 1ns
//////////////////////////////////////////////////////////////////////////////////
// Modul: shift_reg_buffer.v
// Proyek: Indonesia Chip Hackathon Challenge 2026 (DIICES UB)
// Deskripsi: Master Shift Register berkedalaman 64-tap untuk penyedia jendela
//            waktu (sliding window) deteksi R dan pembacaan riwayat Q, S, T.
//
// Standar Desain:
// - Header modul: seluruh port output bertipe 'output wire' (tidak boleh output reg).
// - Port data bernilai multi-bit menggunakan rentang bit eksplisit (packed wire).
// - Seluruh nilai data disimpan di register internal _ps dan _ns.
// - Penugasan akhir konsisten menggunakan 'assign <port> = <signal>_ps;'.
//////////////////////////////////////////////////////////////////////////////////

module shift_reg_buffer #(
    parameter integer DEPTH = 64
)(
    input  wire                      clk,
    input  wire                      rst_n,
    input  wire                      ce,
    input  wire signed [15:0]        sample_in,
    input  wire                      sample_valid_i,
    input  wire        [5:0]         read_addr_i,

    // Port status 1-bit wire
    output wire                      buffer_ready_o,

    // Port data multi-bit wire
    output wire signed [15:0]        tap0_o,
    output wire signed [15:0]        tap1_o,
    output wire signed [15:0]        tap2_o,
    output wire signed [15:0]        delayed_sample_o,
    output wire        [15:0]        sample_cnt_o
);

    // Register status 1-bit (_ps dan _ns)
    reg buffer_ready_ps, buffer_ready_ns;

    // Register internal penyimpanan data nilai (_ps dan _ns)
    reg signed [15:0] tap0_ps,       tap0_ns;
    reg signed [15:0] tap1_ps,       tap1_ns;
    reg signed [15:0] tap2_ps,       tap2_ns;
    reg signed [15:0] delayed_ps,    delayed_ns;
    reg        [15:0] sample_cnt_ps, sample_cnt_ns;

    // Register internal buffer geser riwayat sampel (_ps dan _ns)
    reg signed [15:0] sr_ps [0:DEPTH-1];
    reg signed [15:0] sr_ns [0:DEPTH-1];

    integer i;

    // =========================================================================
    // 1. BLOK SEKUENSIAL SINKRON (CLOCK & ASYNC RESET)
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            buffer_ready_ps <= 1'b0;
            tap0_ps         <= 16'sd0;
            tap1_ps         <= 16'sd0;
            tap2_ps         <= 16'sd0;
            delayed_ps      <= 16'sd0;
            sample_cnt_ps   <= 16'd0;
            for (i = 0; i < DEPTH; i = i + 1) begin
                sr_ps[i] <= 16'sd0;
            end
        end else if (ce) begin
            buffer_ready_ps <= buffer_ready_ns;
            tap0_ps         <= tap0_ns;
            tap1_ps         <= tap1_ns;
            tap2_ps         <= tap2_ns;
            delayed_ps      <= delayed_ns;
            sample_cnt_ps   <= sample_cnt_ns;
            for (i = 0; i < DEPTH; i = i + 1) begin
                sr_ps[i] <= sr_ns[i];
            end
        end
    end

    // =========================================================================
    // 2. BLOK KOMBINASIONAL LOGIKA PERGESERAN (_ns)
    // =========================================================================
    always @(*) begin
        // Nilai default untuk mencegah inferensi latch
        buffer_ready_ns = buffer_ready_ps;
        tap0_ns         = sr_ps[0];
        tap1_ns         = sr_ps[1];
        tap2_ns         = sr_ps[2];
        delayed_ns      = sr_ps[read_addr_i];
        sample_cnt_ns   = sample_cnt_ps;
        for (i = 0; i < DEPTH; i = i + 1) begin
            sr_ns[i] = sr_ps[i];
        end

        // Logika pergeseran saat sampel baru valid masuk
        if (sample_valid_i) begin
            sr_ns[0] = sample_in;
            for (i = 1; i < DEPTH; i = i + 1) begin
                sr_ns[i] = sr_ps[i - 1];
            end

            tap0_ns         = sample_in;
            tap1_ns         = sr_ps[0];
            tap2_ns         = sr_ps[1];
            sample_cnt_ns   = sample_cnt_ps + 16'd1;
            buffer_ready_ns = 1'b1;
        end
    end

    // =========================================================================
    // 3. PENUGASAN PORT OUTPUT (ASSIGN EKSPLISIT DARI _ps)
    // =========================================================================
    assign buffer_ready_o   = buffer_ready_ps;
    assign tap0_o           = tap0_ps;
    assign tap1_o           = tap1_ps;
    assign tap2_o           = tap2_ps;
    assign delayed_sample_o = delayed_ps;
    assign sample_cnt_o     = sample_cnt_ps;

endmodule
