`timescale 1ns / 1ns
//////////////////////////////////////////////////////////////////////////////////
// Modul      : uart_rx_packet_parser.v
// Proyek     : Indonesia Chip Hackathon Challenge 2026 (DIICES UB)
// Deskripsi  : FSM Protocol Layer Parser Paket RX dari PC/Browser.
//              Menerima aliran byte serial dan merakit frame 4-byte:
//              [0xAA] [ECG_HIGH] [ECG_LOW] [0x55]
//              menjadi kata paralel signed 16-bit (sample_out_o) yang valid.
//
// Standar Desain:
// - Seluruh output bertipe 'output wire'.
// - Register menggunakan konvensi Moore _ps, _ns.
//////////////////////////////////////////////////////////////////////////////////

module uart_rx_packet_parser (
    input  wire                      clk,
    input  wire                      rst_n,

    // Masukan dari Physical Layer uart_rx
    input  wire [7:0]                rx_byte_i,
    input  wire                      rx_valid_i,

    // Keluaran ke Core Pemroses EKG (top_ecg_system)
    output wire signed [15:0]        sample_out_o,
    output wire                      sample_valid_o,
    output wire                      frame_err_o
);

    // =========================================================================
    // ENCODING STATE FSM MOORE
    // =========================================================================
    localparam [2:0] P_WAIT_HDR = 3'b000;
    localparam [2:0] P_GET_MSB  = 3'b001;
    localparam [2:0] P_GET_LSB  = 3'b010;
    localparam [2:0] P_CHK_TAIL = 3'b011;
    localparam [2:0] P_DONE     = 3'b100;

    // =========================================================================
    // REGISTER PRESENT & NEXT STATE
    // =========================================================================
    reg [2:0]         state_ps,        state_ns;
    reg [7:0]         msb_buf_ps,      msb_buf_ns;
    reg [7:0]         lsb_buf_ps,      lsb_buf_ns;
    reg signed [15:0] sample_out_ps,   sample_out_ns;
    reg               sample_valid_ps, sample_valid_ns;
    reg               frame_err_ps,    frame_err_ns;

    // =========================================================================
    // UPDATE SEKUENSIAL REGISTER
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_ps        <= P_WAIT_HDR;
            msb_buf_ps      <= 8'h00;
            lsb_buf_ps      <= 8'h00;
            sample_out_ps   <= 16'sh0000;
            sample_valid_ps <= 1'b0;
            frame_err_ps    <= 1'b0;
        end else begin
            state_ps        <= state_ns;
            msb_buf_ps      <= msb_buf_ns;
            lsb_buf_ps      <= lsb_buf_ns;
            sample_out_ps   <= sample_out_ns;
            sample_valid_ps <= sample_valid_ns;
            frame_err_ps    <= frame_err_ns;
        end
    end

    // =========================================================================
    // LOGIKA TRANSISI STATE & KOMBINASIONAL
    // =========================================================================
    always @(*) begin
        // Nilai Default
        state_ns        = state_ps;
        msb_buf_ns      = msb_buf_ps;
        lsb_buf_ns      = lsb_buf_ps;
        sample_out_ns   = sample_out_ps;
        sample_valid_ns = 1'b0;
        frame_err_ns    = 1'b0;

        case (state_ps)
            P_WAIT_HDR: begin
                if (rx_valid_i) begin
                    if (rx_byte_i == 8'hAA) begin
                        state_ns = P_GET_MSB;
                    end
                end
            end

            P_GET_MSB: begin
                if (rx_valid_i) begin
                    msb_buf_ns = rx_byte_i;
                    state_ns   = P_GET_LSB;
                end
            end

            P_GET_LSB: begin
                if (rx_valid_i) begin
                    lsb_buf_ns = rx_byte_i;
                    state_ns   = P_CHK_TAIL;
                end
            end

            P_CHK_TAIL: begin
                if (rx_valid_i) begin
                    if (rx_byte_i == 8'h55) begin
                        // Paket valid dan utuh
                        sample_out_ns   = {msb_buf_ps, lsb_buf_ps};
                        sample_valid_ns = 1'b1;
                        state_ns        = P_DONE;
                    end else begin
                        // Kesalahan framing (tail bukan 0x55)
                        frame_err_ns = 1'b1;
                        // Jika kebetulan byte ini adalah 0xAA, bisa jadi awal frame baru
                        if (rx_byte_i == 8'hAA) state_ns = P_GET_MSB;
                        else state_ns = P_WAIT_HDR;
                    end
                end
            end

            P_DONE: begin
                sample_valid_ns = 1'b0;
                state_ns        = P_WAIT_HDR;
            end

            default: state_ns = P_WAIT_HDR;
        endcase
    end

    // =========================================================================
    // OUTPUT WIRE ASSIGNMENTS
    // =========================================================================
    assign sample_out_o   = sample_out_ps;
    assign sample_valid_o = sample_valid_ps;
    assign frame_err_o    = frame_err_ps;

endmodule

