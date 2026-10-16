`timescale 1ns / 1ns
//////////////////////////////////////////////////////////////////////////////////
// Modul      : uart_tx_packet_builder.v
// Proyek     : Indonesia Chip Hackathon Challenge 2026 (DIICES UB)
// Deskripsi  : FSM Protocol Layer Builder Paket Telemetri TX ke PC/GUI.
//              Menerima hasil olahan EKG dari top_ecg_system dan menyusun frame 8-byte:
//              [0xAA] [FLT_H] [FLT_L] [MARKER] [CONF] [CLASS] [BPM] [0x55]
//              lalu mengalirkan byte-demi-byte ke modul fisik uart_tx.
//
// Standar Desain:
// - Seluruh output bertipe 'output wire'.
// - Register menggunakan konvensi Moore _ps, _ns.
//////////////////////////////////////////////////////////////////////////////////

module uart_tx_packet_builder (
    input  wire                      clk,
    input  wire                      rst_n,

    // Masukan Data Telemetri dari top_ecg_system
    input  wire signed [15:0]        filtered_sample_i, // Sampel EKG terfilter BPF
    input  wire                      sample_trigger_i,  // Pulsa pemicu pengiriman paket baru
    input  wire [7:0]                qrst_marker_i,     // 0: None, 1: Q, 2: R, 3: S, 4: T
    input  wire [7:0]                confidence_i,      // Confidence score (0-100%)
    input  wire [1:0]                class_id_i,        // 0: Normal, 1: MI, 2: Unknown
    input  wire [7:0]                bpm_i,             // Denyut Jantung (BPM)

    // Antarmuka Kontrol ke Physical Layer uart_tx
    input  wire                      tx_busy_i,         // Status sibuk dari uart_tx
    input  wire                      tx_done_i,         // Pulsa selesai 1-byte dari uart_tx
    output wire [7:0]                tx_byte_o,         // Byte dikirim ke uart_tx
    output wire                      tx_start_o,        // Pulsa pemicu ke uart_tx
    output wire                      builder_busy_o     // Status sibuk perakit paket
);

    // =========================================================================
    // ENCODING STATE FSM MOORE
    // =========================================================================
    localparam [1:0] S_IDLE      = 2'b00;
    localparam [1:0] S_SEND_BYTE = 2'b01;
    localparam [1:0] S_WAIT_TX   = 2'b10;
    localparam [1:0] S_DONE      = 2'b11;

    // =========================================================================
    // REGISTER ARRAY FRAME 8-BYTE
    // =========================================================================
    reg [7:0] pkt_0_ps, pkt_0_ns; // 0xAA (SOF)
    reg [7:0] pkt_1_ps, pkt_1_ns; // FLT_H
    reg [7:0] pkt_2_ps, pkt_2_ns; // FLT_L
    reg [7:0] pkt_3_ps, pkt_3_ns; // QRST Marker
    reg [7:0] pkt_4_ps, pkt_4_ns; // Confidence
    reg [7:0] pkt_5_ps, pkt_5_ns; // Class ID
    reg [7:0] pkt_6_ps, pkt_6_ns; // BPM
    reg [7:0] pkt_7_ps, pkt_7_ns; // 0x55 (EOF)

    // =========================================================================
    // REGISTER KONTROL FSM PRESENT & NEXT STATE
    // =========================================================================
    reg [1:0] state_ps,        state_ns;
    reg [2:0] byte_idx_ps,     byte_idx_ns;
    reg [7:0] tx_byte_ps,      tx_byte_ns;
    reg       tx_start_ps,     tx_start_ns;
    reg       builder_busy_ps, builder_busy_ns;

    // =========================================================================
    // UPDATE SEKUENSIAL REGISTER
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_ps        <= S_IDLE;
            byte_idx_ps     <= 3'd0;
            tx_byte_ps      <= 8'h00;
            tx_start_ps     <= 1'b0;
            builder_busy_ps <= 1'b0;

            pkt_0_ps <= 8'hAA;
            pkt_1_ps <= 8'h00;
            pkt_2_ps <= 8'h00;
            pkt_3_ps <= 8'h00;
            pkt_4_ps <= 8'h00;
            pkt_5_ps <= 8'h00;
            pkt_6_ps <= 8'h00;
            pkt_7_ps <= 8'h55;
        end else begin
            state_ps        <= state_ns;
            byte_idx_ps     <= byte_idx_ns;
            tx_byte_ps      <= tx_byte_ns;
            tx_start_ps     <= tx_start_ns;
            builder_busy_ps <= builder_busy_ns;

            pkt_0_ps <= pkt_0_ns;
            pkt_1_ps <= pkt_1_ns;
            pkt_2_ps <= pkt_2_ns;
            pkt_3_ps <= pkt_3_ns;
            pkt_4_ps <= pkt_4_ns;
            pkt_5_ps <= pkt_5_ns;
            pkt_6_ps <= pkt_6_ns;
            pkt_7_ps <= pkt_7_ns;
        end
    end

    // =========================================================================
    // FUNGSI MUX PENGAMBIL BYTE DARI ARRAY FRAME
    // =========================================================================
    function [7:0] get_packet_byte(input [2:0] idx);
        case (idx)
            3'd0: get_packet_byte = pkt_0_ps;
            3'd1: get_packet_byte = pkt_1_ps;
            3'd2: get_packet_byte = pkt_2_ps;
            3'd3: get_packet_byte = pkt_3_ps;
            3'd4: get_packet_byte = pkt_4_ps;
            3'd5: get_packet_byte = pkt_5_ps;
            3'd6: get_packet_byte = pkt_6_ps;
            3'd7: get_packet_byte = pkt_7_ps;
        endcase
    endfunction

    // =========================================================================
    // LOGIKA TRANSISI STATE & KOMBINASIONAL
    // =========================================================================
    always @(*) begin
        // Nilai Default
        state_ns        = state_ps;
        byte_idx_ns     = byte_idx_ps;
        tx_byte_ns      = tx_byte_ps;
        tx_start_ns     = 1'b0;
        builder_busy_ns = 1'b1;

        pkt_0_ns = pkt_0_ps;
        pkt_1_ns = pkt_1_ps;
        pkt_2_ns = pkt_2_ps;
        pkt_3_ns = pkt_3_ps;
        pkt_4_ns = pkt_4_ps;
        pkt_5_ns = pkt_5_ps;
        pkt_6_ns = pkt_6_ps;
        pkt_7_ns = pkt_7_ps;

        case (state_ps)
            S_IDLE: begin
                builder_busy_ns = 1'b0;
                byte_idx_ns     = 3'd0;

                if (sample_trigger_i && !tx_busy_i) begin
                    // Kunci parameter data ke dalam buffer frame
                    pkt_0_ns = 8'hAA;
                    pkt_1_ns = filtered_sample_i[15:8];
                    pkt_2_ns = filtered_sample_i[7:0];
                    pkt_3_ns = qrst_marker_i;
                    pkt_4_ns = confidence_i;
                    pkt_5_ns = {6'b000000, class_id_i};
                    pkt_6_ns = bpm_i;
                    pkt_7_ns = 8'h55;

                    builder_busy_ns = 1'b1;
                    byte_idx_ns     = 3'd0;
                    state_ns        = S_SEND_BYTE;
                end
            end

            S_SEND_BYTE: begin
                tx_byte_ns  = get_packet_byte(byte_idx_ps);
                tx_start_ns = 1'b1;
                state_ns    = S_WAIT_TX;
            end

            S_WAIT_TX: begin
                tx_start_ns = 1'b0;
                // Tunggu sampai uart_tx selesai mentransmisi byte ini
                if (tx_done_i) begin
                    if (byte_idx_ps == 3'd7) begin
                        // Seluruh 8 byte telah terkirim
                        state_ns = S_DONE;
                    end else begin
                        byte_idx_ns = byte_idx_ps + 1'b1;
                        state_ns    = S_SEND_BYTE;
                    end
                end
            end

            S_DONE: begin
                builder_busy_ns = 1'b0;
                state_ns        = S_IDLE;
            end

            default: state_ns = S_IDLE;
        endcase
    end

    // =========================================================================
    // OUTPUT WIRE ASSIGNMENTS
    // =========================================================================
    assign tx_byte_o      = tx_byte_ps;
    assign tx_start_o     = tx_start_ps;
    assign builder_busy_o = builder_busy_ps;

endmodule

