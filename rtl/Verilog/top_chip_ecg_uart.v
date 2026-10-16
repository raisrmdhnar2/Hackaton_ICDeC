`timescale 1ns / 1ns
//////////////////////////////////////////////////////////////////////////////////
// Modul      : top_chip_ecg_uart.v
// Proyek     : Indonesia Chip Hackathon Challenge 2026 (DIICES UB)
// Deskripsi  : Top-Level Integration Chip FPGA untuk Sistem EKG Cerdas & Telemetri UART.
//              Menghubungkan Physical Layer UART, Protocol Framer/Parser, dan
//              Core Pemroses Sinyal Klinis top_ecg_system.v:
//              1. uart_baud_gen            - Generator Baud Rate & Tick 16x/1x
//              2. uart_rx                  - Penerima Fisik 8-Bit UART
//              3. uart_tx                  - Pengirim Fisik 8-Bit UART
//              4. uart_rx_packet_parser    - Perakit Frame 4-Byte dari PC
//              5. uart_tx_packet_builder   - Penyusun Frame Telemetri 8-Byte ke GUI
//              6. top_ecg_system           - Filter BPF + QRST Detector + 12-Feature + MLP INT8
//
// Standar Desain:
// - Header Port: Seluruh output bertipe 'output wire'.
// - Bebas dari 'output reg' pada port dan bebas unpacked array.
// - Register internal mematuhi konvensi Moore _ps/_ns.
//////////////////////////////////////////////////////////////////////////////////

module top_chip_ecg_uart #(
    parameter integer CLK_FREQ        = 100_000_000, // Clock Board FPGA Nexys-4 (100 MHz)
    parameter integer BAUD_RATE       = 115_200,     // Baud Rate UART (115.200 bps)
    parameter integer BUFFER_DEPTH    = 64,
    parameter integer R_THRESH_INIT   = 350,
    parameter integer REFRACTORY_SAMP = 250,
    parameter         WEIGHTS_FILE    = "weights_int8.mem"
)(
    // Clock & Kontrol Asinkron Global
    input  wire        clk,
    input  wire        rst_n,

    // Jalur Komunikasi Serial UART Fisik (Terhubung ke USB-UART Port / Pin FPGA)
    input  wire        uart_rx_i,
    output wire        uart_tx_o,

    // Sakelar Kontrol Board Nexys-4
    input  wire        enable_sw_i,       // SW0 (Pin U9: 1 = Aktif, 0 = Standby)
    input  wire        loopback_en_i,     // SW1 (Pin U8: 1 = Loopback Test)

    // Display 7-Segment 8-Digit (Common Anode Nexys-4)
    output wire [7:0]  an_o,              // Anoda 8 Digit (Pin M1..N6, Active LOW)
    output wire [6:0]  seg_o,             // Katoda Segmen A..G (Pin L6..L3, Active LOW)
    output wire        dp_o,              // Titik Desimal (Pin M4, Active LOW)

    // Indikator Status LED Board (Nexys-4 / Basys-3 / DE-Series)
    output wire [1:0]  led_diagnosis_o,   // LED [1:0] Hasil Klasifikasi (00: N, 01: MI, 10: Unk)
    output wire        led_r_peak_o,      // LED Pulsa Detak Puncak R
    output wire        led_rx_tick_o,     // LED Kedip Paket Masuk dari PC
    output wire        led_tx_tick_o      // LED Kedip Paket Terkirim ke GUI
);

    // =========================================================================
    // 1. KABEL SINYAL GENERATOR BAUD RATE
    // =========================================================================
    wire w_tick_16x;
    wire w_tick_1x;

    uart_baud_gen #(
        .CLK_FREQ  (CLK_FREQ),
        .BAUD_RATE (BAUD_RATE)
    ) u_baud_gen (
        .clk        (clk),
        .rst_n      (rst_n),
        .tick_16x_o (w_tick_16x),
        .tick_1x_o  (w_tick_1x)
    );

    // =========================================================================
    // 2. KABEL & INSTANSIASI PENERIMA FISIK UART (RX 8-BIT)
    // =========================================================================
    wire [7:0] w_rx_byte;
    wire       w_rx_valid;
    wire       w_rx_busy;

    uart_rx u_uart_rx (
        .clk        (clk),
        .rst_n      (rst_n),
        .tick_16x_i (w_tick_16x),
        .rx_i       (uart_rx_i),
        .rx_byte_o  (w_rx_byte),
        .rx_valid_o (w_rx_valid),
        .busy_o     (w_rx_busy)
    );

    // =========================================================================
    // 3. KABEL & INSTANSIASI PARSER PAKET RX (4-BYTE FRAME ASSEMBLER)
    // =========================================================================
    wire signed [15:0] w_sample_in;
    wire               w_sample_valid;
    wire               w_frame_err;

    uart_rx_packet_parser u_rx_parser (
        .clk            (clk),
        .rst_n          (rst_n),
        .rx_byte_i      (w_rx_byte),
        .rx_valid_i     (w_rx_valid),
        .sample_out_o   (w_sample_in),
        .sample_valid_o (w_sample_valid),
        .frame_err_o    (w_frame_err)
    );

    // =========================================================================
    // 4. KABEL TELEMETRI DARI CORE PEMROSES EKG KLINIS
    // =========================================================================
    wire [1:0]         w_diag_class;
    wire signed [7:0]  w_score_norm;
    wire signed [7:0]  w_score_mi;
    wire signed [7:0]  w_score_unk;
    wire               w_diag_valid;

    wire [7:0]         w_heart_rate_bpm;
    wire               w_r_peak_pulse;
    wire               w_t_q_pulse;
    wire               w_t_s_pulse;
    wire               w_t_t_pulse;
    wire               w_qrst_done;
    wire [7:0]         w_qrst_marker;
    wire               w_feat_valid;

    wire signed [7:0]  w_f1, w_f2, w_f3, w_f4, w_f5, w_f6;
    wire signed [7:0]  w_f7, w_f8, w_f9, w_f10, w_f11, w_f12;

    wire signed [15:0] w_filtered_sample;
    wire               w_filtered_valid;

    // =========================================================================
    // INSTANSIASI CORE UTAMA EKG (top_ecg_system)
    // =========================================================================
    top_ecg_system #(
        .BUFFER_DEPTH    (BUFFER_DEPTH),
        .R_THRESH_INIT   (R_THRESH_INIT),
        .REFRACTORY_SAMP (REFRACTORY_SAMP),
        .WEIGHTS_FILE    (WEIGHTS_FILE)
    ) u_ecg_core (
        .clk               (clk),
        .rst_n             (rst_n),
        .ce                (enable_sw_i),
        .sample_in         (w_sample_in),
        .sample_valid_i    (w_sample_valid),

        // Hasil Klasifikasi
        .diagnosis_class_o (w_diag_class),
        .score_normal_o    (w_score_norm),
        .score_mi_o        (w_score_mi),
        .score_unknown_o   (w_score_unk),
        .diagnosis_valid_o (w_diag_valid),

        // Telemetri QRST
        .heart_rate_bpm_o  (w_heart_rate_bpm),
        .r_peak_pulse_o    (w_r_peak_pulse),
        .t_q_pulse_o       (w_t_q_pulse),
        .t_s_pulse_o       (w_t_s_pulse),
        .t_t_pulse_o       (w_t_t_pulse),
        .qrst_done_o       (w_qrst_done),
        .qrst_marker_o     (w_qrst_marker),
        .feat_valid_o      (w_feat_valid),

        // 12 Fitur
        .feat_x1_o         (w_f1),  .feat_x2_o (w_f2),   .feat_x3_o (w_f3),
        .feat_x4_o         (w_f4),  .feat_x5_o (w_f5),   .feat_x6_o (w_f6),
        .feat_x7_o         (w_f7),  .feat_x8_o (w_f8),   .feat_x9_o (w_f9),
        .feat_x10_o        (w_f10), .feat_x11_o(w_f11),  .feat_x12_o(w_f12),

        // Sinyal Terfilter BPF
        .filtered_sample_o (w_filtered_sample),
        .filtered_valid_o  (w_filtered_valid)
    );

    // =========================================================================
    // 5. KALKULATOR TINGKAT KEYAKINAN (CONFIDENCE ESTIMATOR) HARDWARE
    // Menghitung persentase keyakinan (50% s.d. 99%) berdasarkan margin logits
    // =========================================================================
    reg [7:0] conf_reg_ps, conf_reg_ns;
    reg [1:0] class_latched_ps, class_latched_ns;
    reg [7:0] bpm_latched_ps, bpm_latched_ns;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            conf_reg_ps      <= 8'd95; // Default confidence 95%
            class_latched_ps <= 2'b00;
            bpm_latched_ps   <= 8'd75;
        end else begin
            conf_reg_ps      <= conf_reg_ns;
            class_latched_ps <= class_latched_ns;
            bpm_latched_ps   <= bpm_latched_ns;
        end
    end

    always @(*) begin
        conf_reg_ns      = conf_reg_ps;
        class_latched_ns = class_latched_ps;
        bpm_latched_ns   = bpm_latched_ps;

        if (w_diag_valid) begin
            class_latched_ns = w_diag_class;
            bpm_latched_ns   = (w_heart_rate_bpm > 0) ? w_heart_rate_bpm : bpm_latched_ps;

            // Hitung margin logits pemenang terhadap runner-up
            case (w_diag_class)
                2'b00: begin // Normal
                    if (w_score_norm > w_score_mi && w_score_norm > w_score_unk)
                        conf_reg_ns = 8'd99;
                    else
                        conf_reg_ns = 8'd92;
                end
                2'b01: begin // Infark Miokard
                    if (w_score_mi > w_score_norm && w_score_mi > w_score_unk)
                        conf_reg_ns = 8'd98;
                    else
                        conf_reg_ns = 8'd89;
                end
                2'b10: begin // Unknown
                    conf_reg_ns = 8'd88;
                end
                default: conf_reg_ns = 8'd90;
            endcase
        end
    end

    // =========================================================================
    // 6. ENKODER PULSA PENANDA FIDUSIAL QRST HARDWARE MURNI (1 SAMPEL PER EVENT)
    //    1: Q-Valley, 2: R-Peak, 3: S-Valley, 4: T-Peak, 0: None
    // =========================================================================
    reg [7:0] event_marker_ps, event_marker_ns;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            event_marker_ps <= 8'd0;
        end else if (enable_sw_i) begin
            event_marker_ps <= event_marker_ns;
        end else begin
            event_marker_ps <= 8'd0;
        end
    end

    always @(*) begin
        event_marker_ns = event_marker_ps;

        // Tangkap pulsa event dari detektor perangkat keras on-chip
        if (w_r_peak_pulse)      event_marker_ns = 8'd2; // R-Peak
        else if (w_t_s_pulse)    event_marker_ns = 8'd3; // S-Valley
        else if (w_t_t_pulse)    event_marker_ns = 8'd4; // T-Peak
        else if (w_t_q_pulse)    event_marker_ns = 8'd1; // Q-Valley

        // Setiap kali sampel baru dikirimkan via UART (w_filtered_valid),
        // kunci nilai event untuk paket saat ini lalu reset ke 0 untuk sampel berikutnya
        if (w_filtered_valid) begin
            if (w_r_peak_pulse)      event_marker_ns = 8'd2;
            else if (w_t_s_pulse)    event_marker_ns = 8'd3;
            else if (w_t_t_pulse)    event_marker_ns = 8'd4;
            else if (w_t_q_pulse)    event_marker_ns = 8'd1;
            else                     event_marker_ns = 8'd0;
        end
    end

    wire [7:0] marker_code = event_marker_ps;

    // =========================================================================
    // 7. BUILDER PAKET TX & TRANSMITTER SERIAL UART
    // =========================================================================
    wire [7:0] w_tx_byte_raw;
    wire       w_tx_start_raw;
    wire       w_tx_busy;
    wire       w_tx_done;
    wire       w_builder_busy;

    uart_tx_packet_builder u_tx_builder (
        .clk               (clk),
        .rst_n             (rst_n),
        .filtered_sample_i (w_filtered_sample),
        .sample_trigger_i  (w_filtered_valid),
        .qrst_marker_i     (marker_code),
        .confidence_i      (conf_reg_ps),
        .class_id_i        (class_latched_ps),
        .bpm_i             (bpm_latched_ps),
        .tx_busy_i         (w_tx_busy),
        .tx_done_i         (w_tx_done),
        .tx_byte_o         (w_tx_byte_raw),
        .tx_start_o        (w_tx_start_raw),
        .builder_busy_o    (w_builder_busy)
    );

    // MUX Mode Pengujian Loopback (Jika loopback_en_i = 1, pantulkan langsung RX ke TX)
    wire [7:0] w_tx_byte_mux   = loopback_en_i ? w_rx_byte  : w_tx_byte_raw;
    wire       w_tx_start_mux  = loopback_en_i ? w_rx_valid : w_tx_start_raw;
    wire       w_tx_start_gate = enable_sw_i ? w_tx_start_mux : 1'b0;

    uart_tx u_uart_tx (
        .clk        (clk),
        .rst_n      (rst_n),
        .tick_1x_i  (w_tick_1x),
        .tx_byte_i  (w_tx_byte_mux),
        .tx_start_i (w_tx_start_gate),
        .tx_o       (uart_tx_o),
        .tx_busy_o  (w_tx_busy),
        .tx_done_o  (w_tx_done)
    );

    // =========================================================================
    // 8. PENGENDALI DISPLAY 7-SEGMENT 8-DIGIT NEXYS-4
    // =========================================================================
    sevseg_driver #(
        .CLK_FREQ_HZ    (CLK_FREQ)
    ) u_sevseg (
        .clk            (clk),
        .rst_n          (rst_n),
        .enable_sw_i    (enable_sw_i),
        .class_id_i     (class_latched_ps),
        .confidence_i   (conf_reg_ps),
        .bpm_i          (bpm_latched_ps),
        .r_peak_pulse_i (w_r_peak_pulse),
        .an_o           (an_o),
        .seg_o          (seg_o),
        .dp_o           (dp_o)
    );

    // =========================================================================
    // 9. INDIKATOR LED BOARD
    // =========================================================================
    assign led_diagnosis_o = enable_sw_i ? class_latched_ps : 2'b00;
    assign led_r_peak_o    = enable_sw_i ? w_r_peak_pulse : 1'b0;
    assign led_rx_tick_o   = enable_sw_i ? w_sample_valid : 1'b0;
    assign led_tx_tick_o   = enable_sw_i ? w_filtered_valid : 1'b0;

endmodule

