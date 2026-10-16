`timescale 1ns / 1ns
//////////////////////////////////////////////////////////////////////////////////
// Modul      : uart_baud_gen.v
// Proyek     : Indonesia Chip Hackathon Challenge 2026 (DIICES UB)
// Deskripsi  : Generator baud rate presisi tinggi berbasis Phase Accumulator (DDA).
//              Menghasilkan pulsa tick_16x_o untuk oversampling RX dan
//              tick_1x_o untuk clock transmisi TX dengan deviasi baud rate 0.00%
//              pada berbagai frekuensi clock sistem (10 MHz, 50 MHz, 100 MHz).
//
// Standar Desain:
// - Seluruh output bertipe 'output wire'.
// - Register menggunakan konvensi Moore _ps, _ns.
//////////////////////////////////////////////////////////////////////////////////

module uart_baud_gen #(
    parameter integer CLK_FREQ  = 100_000_000, // Frekuensi Clock Sistem Nexys-4 (100 MHz)
    parameter integer BAUD_RATE = 115_200      // Baud Rate Target (115.200 bps)
)(
    input  wire clk,
    input  wire rst_n,

    output wire tick_16x_o, // Pulsa 1-clk pada 16x baud rate (Oversampling RX)
    output wire tick_1x_o   // Pulsa 1-clk pada 1x baud rate (Transmisi TX)
);

    // =========================================================================
    // PARAMETER INKREMEN ACCUMULATOR
    // =========================================================================
    localparam integer INC_16X   = BAUD_RATE * 16;
    localparam integer INC_1X    = BAUD_RATE;
    localparam integer ACC_WIDTH = 32;

    // =========================================================================
    // REGISTER PHASE ACCUMULATOR 16X & 1X (PRESENT & NEXT STATE)
    // =========================================================================
    reg [ACC_WIDTH-1:0] acc_16x_ps,  acc_16x_ns;
    reg [ACC_WIDTH-1:0] acc_1x_ps,   acc_1x_ns;
    reg                 tick_16x_ps, tick_16x_ns;
    reg                 tick_1x_ps,  tick_1x_ns;

    // =========================================================================
    // LOGIKA SEKUENSIAL DENGAN RESET ASINKRON AKTIF RENDAH
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc_16x_ps  <= {ACC_WIDTH{1'b0}};
            acc_1x_ps   <= {ACC_WIDTH{1'b0}};
            tick_16x_ps <= 1'b0;
            tick_1x_ps  <= 1'b0;
        end else begin
            acc_16x_ps  <= acc_16x_ns;
            acc_1x_ps   <= acc_1x_ns;
            tick_16x_ps <= tick_16x_ns;
            tick_1x_ps  <= tick_1x_ns;
        end
    end

    // =========================================================================
    // LOGIKA KOMBINASIONAL PHASE ACCUMULATOR
    // =========================================================================
    always @(*) begin
        // Akumulator 16x (RX Oversampling)
        if ((acc_16x_ps + INC_16X) >= CLK_FREQ) begin
            acc_16x_ns  = (acc_16x_ps + INC_16X) - CLK_FREQ;
            tick_16x_ns = 1'b1;
        end else begin
            acc_16x_ns  = acc_16x_ps + INC_16X;
            tick_16x_ns = 1'b0;
        end

        // Akumulator 1x (TX Transmit Clock)
        if ((acc_1x_ps + INC_1X) >= CLK_FREQ) begin
            acc_1x_ns  = (acc_1x_ps + INC_1X) - CLK_FREQ;
            tick_1x_ns = 1'b1;
        end else begin
            acc_1x_ns  = acc_1x_ps + INC_1X;
            tick_1x_ns = 1'b0;
        end
    end

    // =========================================================================
    // OUTPUT WIRE ASSIGNMENTS
    // =========================================================================
    assign tick_16x_o = tick_16x_ps;
    assign tick_1x_o  = tick_1x_ps;

endmodule

