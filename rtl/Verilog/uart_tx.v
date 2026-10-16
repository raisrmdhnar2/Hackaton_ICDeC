`timescale 1ns / 1ns
//////////////////////////////////////////////////////////////////////////////////
// Modul      : uart_tx.v
// Proyek     : Indonesia Chip Hackathon Challenge 2026 (DIICES UB)
// Deskripsi  : Physical Layer Transmitter UART 8-Bit.
//              - Mengirimkan 1 Start bit ('0'), 8 Data bit (LSB-first), 1 Stop bit ('1').
//              - FSM Moore dengan sinkronisasi baud tick 1x.
//
// Standar Desain:
// - Seluruh output bertipe 'output wire'.
// - Register menggunakan konvensi Moore _ps, _ns.
//////////////////////////////////////////////////////////////////////////////////

module uart_tx (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       tick_1x_i,  // Pulsa 1x Baud Tick dari baud generator
    input  wire [7:0] tx_byte_i,  // Byte data yang akan dikirim
    input  wire       tx_start_i, // Pulsa pemicu mulai transmisi

    output wire       tx_o,       // Jalur Serial TX (Idle = '1')
    output wire       tx_busy_o,  // Indikator sedang sibuk mentransmisi
    output wire       tx_done_o   // Pulsa 1-clk tanda transmisi 1 byte selesai
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
    // REGISTER PRESENT & NEXT STATE
    // =========================================================================
    reg [2:0] state_ps,   state_ns;
    reg [2:0] bit_idx_ps, bit_idx_ns;
    reg [7:0] tx_buf_ps,  tx_buf_ns;
    reg       tx_line_ps, tx_line_ns;
    reg       busy_ps,    busy_ns;
    reg       done_ps,    done_ns;

    // =========================================================================
    // UPDATE SEKUENSIAL REGISTER
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_ps   <= ST_IDLE;
            bit_idx_ps <= 3'd0;
            tx_buf_ps  <= 8'h00;
            tx_line_ps <= 1'b1; // Idle line HIGH
            busy_ps    <= 1'b0;
            done_ps    <= 1'b0;
        end else begin
            state_ps   <= state_ns;
            bit_idx_ps <= bit_idx_ns;
            tx_buf_ps  <= tx_buf_ns;
            tx_line_ps <= tx_line_ns;
            busy_ps    <= busy_ns;
            done_ps    <= done_ns;
        end
    end

    // =========================================================================
    // LOGIKA TRANSISI STATE & KOMBINASIONAL
    // =========================================================================
    always @(*) begin
        // Nilai Default
        state_ns   = state_ps;
        bit_idx_ns = bit_idx_ps;
        tx_buf_ns  = tx_buf_ps;
        tx_line_ns = tx_line_ps;
        busy_ns    = 1'b1;
        done_ns    = 1'b0;

        case (state_ps)
            ST_IDLE: begin
                tx_line_ns = 1'b1; // Jalur serial IDLE = 1
                busy_ns    = 1'b0;
                bit_idx_ns = 3'd0;

                if (tx_start_i) begin
                    tx_buf_ns  = tx_byte_i;
                    tx_line_ns = 1'b0; // Langsung siapkan Start Bit '0'
                    busy_ns    = 1'b1;
                    state_ns   = ST_START;
                end
            end

            ST_START: begin
                tx_line_ns = 1'b0; // Start bit '0'
                if (tick_1x_i) begin
                    tx_line_ns = tx_buf_ps[0]; // Bit 0 (LSB)
                    bit_idx_ns = 3'd0;
                    state_ns   = ST_DATA;
                end
            end

            ST_DATA: begin
                tx_line_ns = tx_buf_ps[bit_idx_ps];
                if (tick_1x_i) begin
                    if (bit_idx_ps == 3'd7) begin
                        tx_line_ns = 1'b1; // Siapkan Stop Bit '1'
                        state_ns   = ST_STOP;
                    end else begin
                        bit_idx_ns = bit_idx_ps + 1'b1;
                        tx_line_ns = tx_buf_ps[bit_idx_ps + 1'b1];
                    end
                end
            end

            ST_STOP: begin
                tx_line_ns = 1'b1; // Stop bit '1'
                if (tick_1x_i) begin
                    done_ns  = 1'b1;
                    state_ns = ST_DONE;
                end
            end

            ST_DONE: begin
                done_ns  = 1'b0;
                busy_ns  = 1'b0;
                state_ns = ST_IDLE;
            end

            default: state_ns = ST_IDLE;
        endcase
    end

    // =========================================================================
    // OUTPUT WIRE ASSIGNMENTS
    // =========================================================================
    assign tx_o      = tx_line_ps;
    assign tx_busy_o = busy_ps;
    assign tx_done_o = done_ps;

endmodule

