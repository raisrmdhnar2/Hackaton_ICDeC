`timescale 1ns / 1ns
//////////////////////////////////////////////////////////////////////////////////
// Modul      : uart_rx.v
// Proyek     : Indonesia Chip Hackathon Challenge 2026 (DIICES UB)
// Deskripsi  : Physical Layer Receiver UART 8-Bit.
//              - Dilengkapi 2-Stage DFF Synchronizer untuk proteksi metastabilitas.
//              - FSM Moore dengan Mid-Bit 16x Oversampling untuk ketahanan noise.
//
// Standar Desain:
// - Seluruh output bertipe 'output wire'.
// - Register menggunakan konvensi Moore _ps, _ns.
//////////////////////////////////////////////////////////////////////////////////

module uart_rx (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       tick_16x_i, // Pulsa 16x Baud Tick dari baud generator
    input  wire       rx_i,       // Jalur Serial Asinkron RX

    output wire [7:0] rx_byte_o,  // Byte data diterima paralel
    output wire       rx_valid_o, // Pulsa 1-clk tanda byte sah
    output wire       busy_o      // Indikator sedang menerima
);

    // =========================================================================
    // ENCODING STATE FSM MOORE
    // =========================================================================
    localparam [2:0] ST_IDLE  = 3'b000;
    localparam [2:0] ST_START = 3'b001;
    localparam [2:0] ST_DATA  = 3'b010;
    localparam [2:0] ST_STOP  = 3'b011;
    localparam [2:0] ST_DONE  = 3'b100;

    // =========================================================================
    // 2-STAGE DFF SYNCHRONIZER UNTUK RX_I
    // =========================================================================
    reg sync1_reg, sync2_reg;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sync1_reg <= 1'b1;
            sync2_reg <= 1'b1;
        end else begin
            sync1_reg <= rx_i;
            sync2_reg <= sync1_reg;
        end
    end
    wire rx_sync = sync2_reg;

    // =========================================================================
    // REGISTER PRESENT & NEXT STATE
    // =========================================================================
    reg [2:0] state_ps, state_ns;
    reg [3:0] tick_cnt_ps, tick_cnt_ns;
    reg [2:0] bit_idx_ps,  bit_idx_ns;
    reg [7:0] rx_shreg_ps, rx_shreg_ns;
    reg [7:0] rx_byte_ps,  rx_byte_ns;
    reg       rx_valid_ps, rx_valid_ns;
    reg       busy_ps,     busy_ns;

    // =========================================================================
    // UPDATE SEKUENSIAL REGISTER
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_ps    <= ST_IDLE;
            tick_cnt_ps <= 4'd0;
            bit_idx_ps  <= 3'd0;
            rx_shreg_ps <= 8'h00;
            rx_byte_ps  <= 8'h00;
            rx_valid_ps <= 1'b0;
            busy_ps     <= 1'b0;
        end else begin
            state_ps    <= state_ns;
            tick_cnt_ps <= tick_cnt_ns;
            bit_idx_ps  <= bit_idx_ns;
            rx_shreg_ps <= rx_shreg_ns;
            rx_byte_ps  <= rx_byte_ns;
            rx_valid_ps <= rx_valid_ns;
            busy_ps     <= busy_ns;
        end
    end

    // =========================================================================
    // LOGIKA TRANSISI STATE & LOGIKA KOMBINASIONAL
    // =========================================================================
    always @(*) begin
        // Nilai Default
        state_ns    = state_ps;
        tick_cnt_ns = tick_cnt_ps;
        bit_idx_ns  = bit_idx_ps;
        rx_shreg_ns = rx_shreg_ps;
        rx_byte_ns  = rx_byte_ps;
        rx_valid_ns = 1'b0;
        busy_ns     = 1'b1;

        case (state_ps)
            ST_IDLE: begin
                busy_ns     = 1'b0;
                tick_cnt_ns = 4'd0;
                bit_idx_ns  = 3'd0;
                // Deteksi tepi turun start bit ('0')
                if (!rx_sync) begin
                    state_ns = ST_START;
                    busy_ns  = 1'b1;
                end
            end

            ST_START: begin
                // Hitung sampai tengah start bit (tick 7 dari 16)
                if (tick_16x_i) begin
                    if (tick_cnt_ps == 4'd7) begin
                        if (!rx_sync) begin
                            // Start bit terverifikasi valid
                            tick_cnt_ns = 4'd0;
                            state_ns    = ST_DATA;
                        end else begin
                            // Glitch / noise, kembali ke IDLE
                            state_ns = ST_IDLE;
                        end
                    end else begin
                        tick_cnt_ns = tick_cnt_ps + 1'b1;
                    end
                end
            end

            ST_DATA: begin
                // Sample data bit di tengah bit (setiap 16 tick)
                if (tick_16x_i) begin
                    if (tick_cnt_ps == 4'd15) begin
                        tick_cnt_ns = 4'd0;
                        // Geser masuk LSB-first
                        rx_shreg_ns = {rx_sync, rx_shreg_ps[7:1]};
                        if (bit_idx_ps == 3'd7) begin
                            state_ns = ST_STOP;
                        end else begin
                            bit_idx_ns = bit_idx_ps + 1'b1;
                        end
                    end else begin
                        tick_cnt_ns = tick_cnt_ps + 1'b1;
                    end
                end
            end

            ST_STOP: begin
                // Verifikasi Stop bit di tengah bit (setelah 15 tick)
                if (tick_16x_i) begin
                    if (tick_cnt_ps == 4'd15) begin
                        tick_cnt_ns = 4'd0;
                        if (rx_sync == 1'b1) begin
                            // Stop bit sah -> data valid
                            rx_byte_ns  = rx_shreg_ps;
                            rx_valid_ns = 1'b1;
                            state_ns    = ST_DONE;
                        end else begin
                            // Framing error
                            state_ns = ST_IDLE;
                        end
                    end else begin
                        tick_cnt_ns = tick_cnt_ps + 1'b1;
                    end
                end
            end

            ST_DONE: begin
                busy_ns     = 1'b0;
                rx_valid_ns = 1'b0;
                state_ns    = ST_IDLE;
            end

            default: state_ns = ST_IDLE;
        endcase
    end

    // =========================================================================
    // OUTPUT WIRE ASSIGNMENTS
    // =========================================================================
    assign rx_byte_o  = rx_byte_ps;
    assign rx_valid_o = rx_valid_ps;
    assign busy_o     = busy_ps;

endmodule

