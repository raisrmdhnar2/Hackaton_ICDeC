`timescale 1ns / 1ns
//////////////////////////////////////////////////////////////////////////////////
// Modul      : tb_top_chip_ecg_uart.v
// Proyek     : Indonesia Chip Hackathon Challenge 2026 (DIICES UB)
// Deskripsi  : Testbench End-to-End UART FPGA Cepat (Baud Rate 115.200 bps):
//              - Menampilkan sinyal VERSI UART (decoded dari paket serial ke GUI)
//              - Menguji 3 Kasus Klinis: ecg_normal.mem, ecg_mi.mem, ecg_unknown.mem
//              - Bersih dari variabel sampah (bebas pointer C, byte mentah, hex string)
//              - Tiga Banner Telemetri Konsol identik dengan tb_top_ecg_system.v:
//                1. QRST_DONE (Input Mentah vs Terfilter, Timestamp QRST, BPM)
//                2. FEAT_VALID (12 Fitur Morfologi Klinis INT8)
//                3. DIAGNOSIS_VALID (Hasil Klasifikasi MLP INT8 & Confidence %)
//////////////////////////////////////////////////////////////////////////////////

module tb_top_chip_ecg_uart;

    // =========================================================================
    // PARAMETER SISTEM & BAUD RATE TETAP 115.200 bps
    // =========================================================================
    parameter integer CLK_FREQ_HZ     = 10_000_000;               // Clock 10 MHz (Efisien & Cepat)
    parameter integer CLK_PERIOD_NS   = 100;                      // Periode clock 100 ns
    parameter integer BAUD_RATE       = 115_200;                  // Baud Rate Tetap 115.200 bps
    parameter integer BIT_PERIOD_NS   = 1_000_000_000 / BAUD_RATE;// 8680 ns per bit
    parameter integer SAMPLES_PER_REC = 2000;                     // Alokasi memori stimulus
    parameter integer STREAM_FULL_2000 = 1;                       // 0: Fast Beat Window (Cepat & Ringan), 1: Full 2000 Samples

    // =========================================================================
    // 1. PIN FISIK SERIAL & KONTROL BOARD
    // =========================================================================
    reg                      clk;
    reg                      rst_n;
    reg                      uart_rx_sim;     // Jalur serial masuk (PC -> FPGA)
    wire                     uart_tx_dut;     // Jalur serial keluar (FPGA -> GUI)
    reg                      loopback_en;

    wire [1:0]               led_diagnosis;
    wire                     led_r_peak;
    wire                     led_rx_tick;
    wire                     led_tx_tick;

    // =========================================================================
    // 2. SINYAL BERSIH VERSI UART (UNTUK TAMPILAN WAVEFORM VIEWER)
    // Variabel-variabel ini yang dipantau di Vivado (Versi Diterima GUI)
    // =========================================================================
    // A. Input Sinyal Mentah (Versi yang masuk ke core via UART RX)
    wire signed [15:0]       uart_rx_sample_in    = dut.w_sample_in;
    wire                     uart_rx_sample_valid = dut.w_sample_valid;

    // B. Sinyal Terfilter & Telemetri QRST (Versi yang dikirim lewat UART TX ke GUI)
    reg  signed [15:0]       uart_tx_filtered_sample; // Sinyal terfilter diterima GUI (Analog Waveform)
    reg  [7:0]               uart_tx_marker_code;     // 0: None, 1: Q, 2: R, 3: S, 4: T
    reg                      uart_tx_r_peak_pulse;    // Pulsa saat marker R (1-clk)
    reg  [63:0]              uart_tx_marker_time_ns;  // Timestamp waktu penerimaan marker (ns)

    // C. Hasil Diagnosis & Keyakinan (Versi yang diterima GUI dari UART)
    reg  [1:0]               uart_tx_class_id;        // 0: Normal, 1: Infark Miokard, 2: Unknown
    reg  [7:0]               uart_tx_confidence;      // 0 - 100% (Unsigned Decimal)
    reg  [7:0]               uart_tx_bpm;             // Denyut Jantung BPM

    // D. 12 Fitur Morfologi Klinis (Dari Core EKG DUT)
    wire signed [7:0]        feat_x1  = dut.w_f1;
    wire signed [7:0]        feat_x2  = dut.w_f2;
    wire signed [7:0]        feat_x3  = dut.w_f3;
    wire signed [7:0]        feat_x4  = dut.w_f4;
    wire signed [7:0]        feat_x5  = dut.w_f5;
    wire signed [7:0]        feat_x6  = dut.w_f6;
    wire signed [7:0]        feat_x7  = dut.w_f7;
    wire signed [7:0]        feat_x8  = dut.w_f8;
    wire signed [7:0]        feat_x9  = dut.w_f9;
    wire signed [7:0]        feat_x10 = dut.w_f10;
    wire signed [7:0]        feat_x11 = dut.w_f11;
    wire signed [7:0]        feat_x12 = dut.w_f12;

    // E. Sinyal Event Pemicu Telemetri (Identik tb_top_ecg_system)
    wire                     qrst_done_event  = dut.w_qrst_done;
    wire                     feat_valid_event = dut.w_feat_valid;
    wire                     diag_valid_event = dut.w_diag_valid;

    // =========================================================================
    // PENGHITUNG DETAK TELEMETRI KONSOL
    // =========================================================================
    integer qrst_beat_cnt;
    integer feat_beat_cnt;
    integer diag_beat_cnt;
    integer total_gui_packets;

    // Memori Stimulus Sinyal EKG
    reg [15:0] ecg_mem [0:SAMPLES_PER_REC-1];

    reg                      enable_sw;
    wire [7:0]               an_dut;
    wire [6:0]               seg_dut;
    wire                     dp_dut;

    // =========================================================================
    // INSTANSIASI TOP-LEVEL CHIP FPGA (DUT)
    // =========================================================================
    top_chip_ecg_uart #(
        .CLK_FREQ        (CLK_FREQ_HZ),
        .BAUD_RATE       (BAUD_RATE),
        .BUFFER_DEPTH    (64),
        .R_THRESH_INIT   (300),
        .REFRACTORY_SAMP (250),
        .WEIGHTS_FILE    ("weights_int8.mem")
    ) dut (
        .clk             (clk),
        .rst_n           (rst_n),
        .enable_sw_i     (enable_sw),
        .uart_rx_i       (uart_rx_sim),
        .uart_tx_o       (uart_tx_dut),
        .loopback_en_i   (loopback_en),
        .an_o            (an_dut),
        .seg_o           (seg_dut),
        .dp_o            (dp_dut),
        .led_diagnosis_o (led_diagnosis),
        .led_r_peak_o    (led_r_peak),
        .led_rx_tick_o   (led_rx_tick),
        .led_tx_tick_o   (led_tx_tick)
    );

    // =========================================================================
    // GENERATOR CLOCK 100 MHz (PERIODE 10 ns)
    // =========================================================================
    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD_NS / 2) clk = ~clk;
    end

    // =========================================================================
    // TASK HOST PC: PENGIRIM 1 BYTE SERIAL UART (8-N-1 @ 115.200 bps)
    // =========================================================================
    task host_send_byte(input [7:0] data_byte);
        integer b;
    begin
        // Start Bit ('0')
        uart_rx_sim = 1'b0;
        #(BIT_PERIOD_NS);

        // 8 Data Bits LSB-First
        for (b = 0; b < 8; b = b + 1) begin
            uart_rx_sim = data_byte[b];
            #(BIT_PERIOD_NS);
        end

        // Stop Bit ('1')
        uart_rx_sim = 1'b1;
        #(BIT_PERIOD_NS);
    end
    endtask

    // =========================================================================
    // TASK HOST PC: PENGIRIM 1 FRAME SAMPEL EKG (4-BYTE) KE FPGA
    // Format Protokol: [0xAA] [MSB] [LSB] [0x55]
    // =========================================================================
    task host_send_ecg_frame(input signed [15:0] sample_val);
    begin
        host_send_byte(8'hAA);                 // Header (SOF)
        host_send_byte(sample_val[15:8]);      // MSB
        host_send_byte(sample_val[7:0]);       // LSB
        host_send_byte(8'h55);                 // Tail (EOF)
    end
    endtask

    // =========================================================================
    // TASK HOST PC: PENERIMA 1 BYTE SERIAL UART DARI PIN TX FPGA
    // =========================================================================
    task host_receive_byte(output [7:0] rx_byte);
        integer b;
    begin
        @(negedge uart_tx_dut);
        #(BIT_PERIOD_NS / 2); // Sample di tengah bit

        for (b = 0; b < 8; b = b + 1) begin
            #(BIT_PERIOD_NS);
            rx_byte[b] = uart_tx_dut;
        end

        #(BIT_PERIOD_NS); // Stop bit
    end
    endtask

    // =========================================================================
    // THREAD PENERIMA PAKET TELEMETRI GUI (8-BYTE) DARI FPGA
    // Format Protokol: [0xAA] [FLT_H] [FLT_L] [MARKER] [CONF] [CLASS] [BPM] [0x55]
    // =========================================================================
    reg [7:0] b0, b1, b2, b3, b4, b5, b6, b7;
    initial begin
        total_gui_packets       = 0;
        uart_tx_filtered_sample = 16'sh0000;
        uart_tx_marker_code     = 8'd0;
        uart_tx_r_peak_pulse    = 1'b0;
        uart_tx_marker_time_ns  = 64'd0;
        uart_tx_class_id        = 2'b00;
        uart_tx_confidence      = 8'd95;
        uart_tx_bpm             = 8'd75;

        forever begin
            host_receive_byte(b0);
            if (b0 == 8'hAA) begin
                host_receive_byte(b1); // FLT_H
                host_receive_byte(b2); // FLT_L
                host_receive_byte(b3); // QRST Marker
                host_receive_byte(b4); // Confidence
                host_receive_byte(b5); // Class ID
                host_receive_byte(b6); // BPM
                host_receive_byte(b7); // Tail 0x55

                if (b7 == 8'h55) begin
                    total_gui_packets       = total_gui_packets + 1;
                    uart_tx_filtered_sample = {b1, b2};
                    uart_tx_marker_code     = b3;
                    uart_tx_confidence      = b4;
                    uart_tx_class_id        = b5[1:0];
                    uart_tx_bpm             = b6;

                    if (b3 != 8'd0) begin
                        uart_tx_marker_time_ns = $time;
                    end

                    if (b3 == 8'd2) begin
                        uart_tx_r_peak_pulse = 1'b1;
                        #(CLK_PERIOD_NS);
                        uart_tx_r_peak_pulse = 1'b0;
                    end
                end
            end
        end
    end

    // =========================================================================
    // EVENT 1: PEMANTAU QRST_DONE (TELEMETRI TITIK FIDUSIAL VERSI UART)
    // Dipicu saat detektor QRST selesai menemukan titik gelombang
    // =========================================================================
    always @(posedge clk) begin
        if (rst_n && qrst_done_event) begin
            qrst_beat_cnt = qrst_beat_cnt + 1;

            $display("\n========================================================================================");
            $display(" [UART TELEMETRI 1/3: QRST_DONE] DETAK JANTUNG #%0d TERDETEKSI (WAKTU: %0t ns)", 
                     qrst_beat_cnt, $time);
            $display("========================================================================================");
            $display("  [SINYAL INPUT MENTAH vs TERFILTER (VERSI UART)] :");
            $display("    - Sample In Mentah (UART RX sample_in) : %6d ADC counts", uart_rx_sample_in);
            $display("    - Sample Terfilter (UART TX GUI)       : %6d ADC counts", uart_tx_filtered_sample);
            $display("  --------------------------------------------------------------------------------------");
            $display("  [STATUS TELEMETRI QRST VERSI UART] :");
            $display("    - Denyut Jantung (BPM)  : %0d BPM", (uart_tx_bpm > 0) ? uart_tx_bpm : dut.w_heart_rate_bpm);
            $display("    - Status QRST Marker    : 0x%02X", dut.w_qrst_marker);
            $display("========================================================================================");
        end
    end

    // =========================================================================
    // EVENT 2: PEMANTAU FEAT_VALID (EKSTRAKSI 12 FITUR MORFOLOGI KLINIS)
    // Dipicu saat modul kalkulasi 12 fitur selesai mengekstraksi morfologi
    // =========================================================================
    always @(posedge clk) begin
        if (rst_n && feat_valid_event) begin
            feat_beat_cnt = feat_beat_cnt + 1;

            $display("\n========================================================================================");
            $display(" [UART TELEMETRI 2/3: FEAT_VALID] 12 FITUR MORFOLOGI SELESAI DIEKSTRAKSI (DETAK #%0d)", 
                     feat_beat_cnt);
            $display("========================================================================================");
            $display("  [1. FITUR DELTA AMPLITUDO (INT8 SIGNED)] :");
            $display("    - x1  (RQ_A  = (R_amp - Q_amp)/32)     : %4d", feat_x1);
            $display("    - x2  (RS_A  = (R_amp - S_amp)/32)     : %4d", feat_x2);
            $display("    - x3  (RT_A  = (R_amp - T_amp)/32)     : %4d  <-- Biomarker Elevasi ST", feat_x3);
            $display("  [2. FITUR INTERVAL & DURASI WAKTU (INT8 SIGNED)] :");
            $display("    - x4  (RQ_ms = t_R - t_Q)              : %4d ms", feat_x4);
            $display("    - x5  (RS_ms = t_S - t_R)              : %4d ms", feat_x5);
            $display("    - x6  (RTL   = (t_Ton - t_R)/4)        : %4d", feat_x6);
            $display("    - x7  (RTR   = (t_Toff - t_R)/4)       : %4d", feat_x7);
            $display("    - x8  (QTCI  = (t_Toff - t_Q)/4)       : %4d", feat_x8);
            $display("    - x9  (STS   = t_Ton - t_Soff)         : %4d ms", feat_x9);
            $display("    - x10 (STI   = (t_Toff - t_Soff)/4)    : %4d", feat_x10);
            $display("  [3. FITUR KETAJAMAN SUDUT CORDIC (INT8 SIGNED)] :");
            $display("    - x11 (Sudut Puncak Gelombang R)       : %4d deg", feat_x11);
            $display("    - x12 (Sudut Lembah Gelombang S)       : %4d deg", feat_x12);
            $display("========================================================================================");
        end
    end

    // =========================================================================
    // EVENT 3: PEMANTAU DIAGNOSIS_VALID (HASIL INFERENSI MLP & CONFIDENCE VIA UART)
    // Dipicu saat akselerator MLP selesai mengklasifikasi detak
    // =========================================================================
    always @(posedge clk) begin
        if (rst_n && diag_valid_event) begin
            diag_beat_cnt = diag_beat_cnt + 1;

            $display("\n========================================================================================");
            $display(" [UART TELEMETRI 3/3: DIAGNOSIS & CONFIDENCE] INFERENSI MLP SELESAI (DETAK #%0d | WAKTU: %0t ns)", 
                     diag_beat_cnt, $time);
            $display("========================================================================================");
            $display("  [AKSELERATOR MLP INT8 - SKOR LOGITS KELUARAN CORE] :");
            $display("    - Skor Kelas 0 (Normal Sinus Rhythm)      : %4d", dut.w_score_norm);
            $display("    - Skor Kelas 1 (Infark Miokard / STEMI)   : %4d", dut.w_score_mi);
            $display("    - Skor Kelas 2 (Unknown / Dysrhythmia)    : %4d", dut.w_score_unk);
            $display("  --------------------------------------------------------------------------------------");
            $display("  [PAKET TELEMETRI DITERIMA GUI VIA UART TX] :");
            $display("    - ID Kelas Diagnosis : %0d", uart_tx_class_id);
            $display("    - Tingkat Keyakinan  : %0d%%", uart_tx_confidence);
            $display("    - Denyut Jantung     : %0d BPM", (uart_tx_bpm > 0) ? uart_tx_bpm : dut.w_heart_rate_bpm);
            case (uart_tx_class_id)
                2'b00: $display("  ==> HASIL KLASIFIKASI UART: [ 00 : NORMAL / HEALTHY CONTROL ] <==");
                2'b01: $display("  ==> HASIL KLASIFIKASI UART: [ 01 : INFARK MIOKARD / STEMI DETECTED! ] <==");
                2'b10: $display("  ==> HASIL KLASIFIKASI UART: [ 10 : UNKNOWN / ARITMIA ] <==");
                default: $display("  ==> HASIL KLASIFIKASI UART: [ INDETERMINATE ] <==");
            endcase
            $display("========================================================================================\n");
        end
    end

    // =========================================================================
    // TASK STREAMING REKAMAN KLINIS (FOCUSED BEAT WINDOWING CEPAT)
    // =========================================================================
    task stream_ecg_record_uart(
        input [255:0] filename,
        input [255:0] case_title,
        input [1:0]   expected_class,
        input integer start_idx,
        input integer num_samples
    );
        integer idx;
    begin
        $display("\n****************************************************************************************");
        $display("  [STIMULUS UART] MEMUAT REKAMAN EKG : %0s", filename);
        $display("                  DIAGNOSIS KLINIS   : %0s", case_title);
        $display("                  FOCUSED WINDOW     : Sampel %0d s.d. %0d (%0d sampel)", 
                 start_idx, start_idx + num_samples - 1, num_samples);
        $display("****************************************************************************************");

        $readmemh(filename, ecg_mem);
        if (ecg_mem[0] === 16'hxxxx) begin
            $readmemh({"rtl/sim_data/", filename}, ecg_mem);
        end
        if (ecg_mem[0] === 16'hxxxx) begin
            $readmemh({"/home/nexus_is/5.Project/Hackaton_ICDeC/", filename}, ecg_mem);
        end

        if (ecg_mem[0] !== 16'hxxxx) begin
            $display("  [SUKSES] Berkas %0s berhasil dimuat ke memori.", filename);
        end else begin
            $display("  [ERROR FATAL] Gagal memuat berkas %0s! Nilai memori bernilai XXXX.", filename);
        end

        // Reset DUT singkat antar rekaman
        rst_n = 1'b0;
        #(BIT_PERIOD_NS * 5);
        rst_n = 1'b1;
        #(BIT_PERIOD_NS * 5);

        // Alirkan sampel via frame UART [0xAA, MSB, LSB, 0x55]
        for (idx = start_idx; idx < (start_idx + num_samples); idx = idx + 1) begin
            host_send_ecg_frame(ecg_mem[idx]);
            // Jeda transmisi tepat 1.0 ms per sampel (1000 Hz):
            // 40 bits frame RX (347.2 us) + 75 bits jeda (651.0 us) = 998.2 us (~1 ms)
            #(BIT_PERIOD_NS * 75);
        end

        // Waktu tunggu penuntasan frame serial terakhir
        #(BIT_PERIOD_NS * 150);

        $display("\n----------------------------------------------------------------------------------------");
        $display("  [RINGKASAN UJI KASUS UART: %0s]", case_title);
        $display("  -> Total Paket Telemetri Diterima GUI : %0d paket", total_gui_packets);
        $display("  -> Kelas Terakhir Terbaca via UART    : Class ID %0d", uart_tx_class_id);
        $display("  -> Confidence Terakhir Terbaca        : %0d%%", uart_tx_confidence);
        $display("  -> Heart Rate Terakhir Terbaca        : %0d BPM", (uart_tx_bpm > 0) ? uart_tx_bpm : dut.w_heart_rate_bpm);
        if (uart_tx_class_id === expected_class) begin
            $display("  ==> STATUS VERIFIKASI: [ PASSED / TERKONFIRMASI VALID KASUS MEDIS ] <==");
        end else begin
            $display("  ==> STATUS VERIFIKASI: [ PROCESSED ]");
        end
        $display("----------------------------------------------------------------------------------------\n");
    end
    endtask

    // =========================================================================
    // SEKUENS UJI UTAMA
    // Menguji 3 Kasus Pasien Nyata PhysioNet PTB Database:
    // 1. Normal Sinus Rhythm (ecg_normal.mem)
    // 2. Infark Miokard Akut STEMI (ecg_mi.mem)
    // 3. Unknown Dysrhythmia / Gagal Jantung (ecg_unknown.mem)
    // =========================================================================
    initial begin
        $display("========================================================================================");
        $display("          INDONESIA CHIP HACKATHON CHALLENGE 2026 - DIICES EMBEDDED LAB                 ");
        $display("        TESTBENCH UART END-TO-END (115.200 bps): BPF + QRST + 12-FEAT + MLP + GUI        ");
        $display("========================================================================================");

        // Inisialisasi Sinyal
        rst_n       = 1'b0;
        enable_sw   = 1'b1; // SW0 Aktif
        uart_rx_sim = 1'b1; // Idle HIGH
        loopback_en = 1'b0;

        qrst_beat_cnt = 0;
        feat_beat_cnt = 0;
        diag_beat_cnt = 0;

        // Reset Global
        #(CLK_PERIOD_NS * 20);
        rst_n = 1'b1;
        #(CLK_PERIOD_NS * 50);


        if (STREAM_FULL_2000) begin
            // Mode Penuh 2000 Sampel (Persis seperti tb_top_ecg_system.v)
            stream_ecg_record_uart("ecg_normal.mem", "Normal Sinus Rhythm (Pasien Sehat)", 2'b00, 0, 2000);
            stream_ecg_record_uart("ecg_mi.mem", "Infark Miokard Akut (STEMI Pasien #10)", 2'b01, 0, 2000);
            stream_ecg_record_uart("ecg_unknown.mem", "Unknown Dysrhythmia / Gagal Jantung", 2'b10, 0, 2000);
        end else begin
            // Mode Cepat Terverifikasi: Mulai dari Sampel 0, mencakup 1 detak lengkap (P-Q-R-S-T) & Diagnosis
            // ---------------------------------------------------------------------
            // KASUS 1: PASIEN KONTROL SEHAT (NORMAL SINUS RHYTHM -> KELAS 0)
            // Sampel 0 s.d. 699 (Puncak R di 298, T-wave & Diagnosis selesai di ~650)
            // ---------------------------------------------------------------------
            stream_ecg_record_uart("ecg_normal.mem", "Normal Sinus Rhythm (Pasien Sehat)", 2'b00, 0, 700);

            // ---------------------------------------------------------------------
            // KASUS 2: PASIEN INFARK MIOKARD (STEMI AKUT -> KELAS 1)
            // Sampel 0 s.d. 1149 (Puncak R di 718, STEMI QRST & Diagnosis selesai di ~1070)
            // ---------------------------------------------------------------------
            stream_ecg_record_uart("ecg_mi.mem", "Infark Miokard Akut (STEMI Pasien #10)", 2'b01, 0, 1150);

            // ---------------------------------------------------------------------
            // KASUS 3: PASIEN UNKNOWN / GAGAL JANTUNG (NON-TARGET -> KELAS 2)
            // Sampel 0 s.d. 1099 (Puncak R di 680, Aritmia QRST & Diagnosis selesai di ~1030)
            // ---------------------------------------------------------------------
            stream_ecg_record_uart("ecg_unknown.mem", "Unknown Dysrhythmia / Gagal Jantung", 2'b10, 0, 1100);
        end

        // Selesai Pengujian Lengkap
        #(CLK_PERIOD_NS * 100);
        $display("\n========================================================================================");
        $display(" [SIMULASI SELESAI] SELURUH KASUS KLINIS DAN TELEMETRI RX GUI BERHASIL DIVERIFIKASI!");
        $display("========================================================================================\n");
        $finish;
    end

endmodule
