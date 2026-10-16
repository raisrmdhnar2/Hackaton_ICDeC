`timescale 1ns / 1ns
//////////////////////////////////////////////////////////////////////////////////
// Modul      : sevseg_driver.v
// Proyek     : Indonesia Chip Hackathon Challenge 2026 (DIICES UB)
// Deskripsi  : Driver Display 7-Segment 8-Digit Multiplexed untuk Digilent Nexys-4
//              - Common Anode (an_o = 0: Digit Aktif, seg_o = 0: Segmen Aktif)
//              - Refresh Rate Multiplexing: ~1.5 kHz (190 Hz/digit, Bebas Kedip)
//              - Kontrol Sakelar Enable (enable_sw_i):
//                * Saat Enable = 0: Menampilkan "  oFF   " (Standby Hemat Daya)
//                * Saat Enable = 1: Menampilkan Hasil Diagnosis Klinis:
//                  - Digit 7: Kelas Diagnosis ('0': Normal, '1': Infark, '2': Unk)
//                  - Digit 6: Tanda Pemisah ('-')
//                  - Digit 5-4: Denyut Jantung BPM (Puluhan & Satuan)
//                  - Digit 3: Pemisah Spasi
//                  - Digit 2-0: Skor Keyakinan Confidence % (Ratusan, Puluhan, Satuan)
//                  - DP (Titik Desimal): Berkedip mengikuti Pulsa Puncak R
//
// Standar Desain:
// - Header Port: Seluruh output bertipe 'output wire'.
// - Register internal menggunakan konvensi Moore _ps, _ns.
// - Di akhir blok modul, lakukan assign register internal _ps ke output wire.
//////////////////////////////////////////////////////////////////////////////////

module sevseg_driver #(
    parameter integer CLK_FREQ_HZ = 100_000_000 // Clock Nexys-4: 100 MHz
)(
    input  wire        clk,
    input  wire        rst_n,

    // Sinyal Kontrol & Hasil Klasifikasi dari Core EKG
    input  wire        enable_sw_i,     // Saklar SW0 (1: Aktif, 0: Standby)
    input  wire [1:0]  class_id_i,      // 00: Normal, 01: Infark Miokard, 10: Unknown
    input  wire [7:0]  confidence_i,    // Tingkat Keyakinan (0 - 100%)
    input  wire [7:0]  bpm_i,           // Denyut Jantung (BPM)
    input  wire        r_peak_pulse_i,  // Pulsa Detak Puncak R (Kedip DP)

    // Antarmuka Fisik ke Board Nexys-4 (Seluruhnya output wire)
    output wire [7:0]  an_o,            // Anoda 8-Digit (Active LOW)
    output wire [6:0]  seg_o,           // Katoda Segmen A..G (Active LOW)
    output wire        dp_o             // Titik Desimal (Active LOW)
);

    // =========================================================================
    // ENCODING KARAKTER 7-SEGMENT (ACTIVE LOW: 0 = NYALA, 1 = MATI)
    // Format: {CG, CF, CE, CD, CC, CB, CA}
    // =========================================================================
    localparam [6:0]
        CHAR_0     = 7'b1000000, // 0
        CHAR_1     = 7'b1111001, // 1
        CHAR_2     = 7'b0100100, // 2
        CHAR_3     = 7'b0110000, // 3
        CHAR_4     = 7'b0011001, // 4
        CHAR_5     = 7'b0010010, // 5
        CHAR_6     = 7'b0000010, // 6
        CHAR_7     = 7'b1111000, // 7
        CHAR_8     = 7'b0000000, // 8
        CHAR_9     = 7'b0010000, // 9
        CHAR_n     = 7'b0101011, // n (Normal)
        CHAR_H     = 7'b0001001, // H (Heart Attack / Infark Miokard)
        CHAR_U     = 7'b1000001, // U (Unknown / Dysrhythmia)
        CHAR_o     = 7'b0100011, // o (untuk "oFF")
        CHAR_F     = 7'b0001110, // F (untuk "oFF")
        CHAR_DASH  = 7'b0111111, // -
        CHAR_BLANK = 7'b1111111; // Layar Kosong

    // =========================================================================
    // REGISTER INTERNAL PRESENT STATE (_ps) DAN NEXT STATE (_ns)
    // =========================================================================
    reg [15:0] refresh_cnt_ps, refresh_cnt_ns;
    reg [22:0] r_blink_cnt_ps, r_blink_cnt_ns;
    reg [7:0]  an_ps,          an_ns;
    reg [6:0]  seg_ps,         seg_ns;
    reg        dp_ps,          dp_ns;

    wire [2:0] digit_sel      = refresh_cnt_ps[15:13];
    wire       r_blink_active = (r_blink_cnt_ps > 0);

    // =========================================================================
    // 1. PEMISAH DIGIT DESIMAL (BCD DECOMPOSER UNTUK BPM & CONFIDENCE)
    // =========================================================================
    // BPM (0 - 255)
    wire [3:0] bpm_hundreds = (bpm_i >= 200) ? 4'd2 : ((bpm_i >= 100) ? 4'd1 : 4'd0);
    wire [7:0] bpm_rem100   = (bpm_i >= 200) ? (bpm_i - 8'd200) : ((bpm_i >= 100) ? (bpm_i - 8'd100) : bpm_i);
    wire [3:0] bpm_tens     = (bpm_rem100 >= 90) ? 4'd9 : (bpm_rem100 >= 80) ? 4'd8 :
                              (bpm_rem100 >= 70) ? 4'd7 : (bpm_rem100 >= 60) ? 4'd6 :
                              (bpm_rem100 >= 50) ? 4'd5 : (bpm_rem100 >= 40) ? 4'd4 :
                              (bpm_rem100 >= 30) ? 4'd3 : (bpm_rem100 >= 20) ? 4'd2 :
                              (bpm_rem100 >= 10) ? 4'd1 : 4'd0;
    wire [3:0] bpm_ones     = bpm_rem100 - (bpm_tens * 4'd10);

    // Confidence (0 - 100)
    wire [3:0] conf_hundreds = (confidence_i >= 100) ? 4'd1 : 4'd0;
    wire [7:0] conf_rem100   = (confidence_i >= 100) ? (confidence_i - 8'd100) : confidence_i;
    wire [3:0] conf_tens     = (conf_rem100 >= 90) ? 4'd9 : (conf_rem100 >= 80) ? 4'd8 :
                               (conf_rem100 >= 70) ? 4'd7 : (conf_rem100 >= 60) ? 4'd6 :
                               (conf_rem100 >= 50) ? 4'd5 : (conf_rem100 >= 40) ? 4'd4 :
                               (conf_rem100 >= 30) ? 4'd3 : (conf_rem100 >= 20) ? 4'd2 :
                               (conf_rem100 >= 10) ? 4'd1 : 4'd0;
    wire [3:0] conf_ones     = conf_rem100 - (conf_tens * 4'd10);

    // Fungsi Pengonversi Nibble (0-9) ke 7-Segment
    function [6:0] bcd_to_7seg(input [3:0] val);
        case (val)
            4'd0: bcd_to_7seg = CHAR_0;
            4'd1: bcd_to_7seg = CHAR_1;
            4'd2: bcd_to_7seg = CHAR_2;
            4'd3: bcd_to_7seg = CHAR_3;
            4'd4: bcd_to_7seg = CHAR_4;
            4'd5: bcd_to_7seg = CHAR_5;
            4'd6: bcd_to_7seg = CHAR_6;
            4'd7: bcd_to_7seg = CHAR_7;
            4'd8: bcd_to_7seg = CHAR_8;
            4'd9: bcd_to_7seg = CHAR_9;
            default: bcd_to_7seg = CHAR_BLANK;
        endcase
    endfunction

    // =========================================================================
    // 2. LOGIKA SEKUENSIAL DENGAN RESET ASINKRON AKTIF RENDAH
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            refresh_cnt_ps <= 16'd0;
            r_blink_cnt_ps <= 23'd0;
            an_ps          <= 8'hFF;
            seg_ps         <= CHAR_BLANK;
            dp_ps          <= 1'b1;
        end else begin
            refresh_cnt_ps <= refresh_cnt_ns;
            r_blink_cnt_ps <= r_blink_cnt_ns;
            an_ps          <= an_ns;
            seg_ps         <= seg_ns;
            dp_ps          <= dp_ns;
        end
    end

    // =========================================================================
    // 3. LOGIKA KOMBINASIONAL MULTIPLEXING DISPLAY (NEXT STATE LOGIC)
    // =========================================================================
    always @(*) begin
        // Inkrementasi counter multiplexing
        refresh_cnt_ns = refresh_cnt_ps + 16'd1;

        // Pewaktu pulsa kedip puncak R (~50 ms pada 100 MHz)
        if (r_peak_pulse_i) begin
            r_blink_cnt_ns = 23'd5_000_000;
        end else if (r_blink_cnt_ps > 0) begin
            r_blink_cnt_ns = r_blink_cnt_ps - 23'd1;
        end else begin
            r_blink_cnt_ns = 23'd0;
        end

        // Default sinyal display
        an_ns  = 8'hFF;
        seg_ns = CHAR_BLANK;
        dp_ns  = 1'b1;

        if (!enable_sw_i) begin
            // -----------------------------------------------------------------
            // MODE STANDBY (SW0 = OFF): Menampilkan "   oFF  "
            // -----------------------------------------------------------------
            dp_ns = 1'b1;
            case (digit_sel)
                3'd7: begin an_ns = 8'b01111111; seg_ns = CHAR_BLANK; end
                3'd6: begin an_ns = 8'b10111111; seg_ns = CHAR_BLANK; end
                3'd5: begin an_ns = 8'b11011111; seg_ns = CHAR_BLANK; end
                3'd4: begin an_ns = 8'b11101111; seg_ns = CHAR_o;     end // 'o'
                3'd3: begin an_ns = 8'b11110111; seg_ns = CHAR_F;     end // 'F'
                3'd2: begin an_ns = 8'b11111011; seg_ns = CHAR_F;     end // 'F'
                3'd1: begin an_ns = 8'b11111101; seg_ns = CHAR_BLANK; end
                3'd0: begin an_ns = 8'b11111110; seg_ns = CHAR_BLANK; end
                default: begin an_ns = 8'b11111111; seg_ns = CHAR_BLANK; end
            endcase
        end else begin
            // -----------------------------------------------------------------
            // MODE AKTIF (SW0 = ON): Menampilkan [ KELAS - BPM   CONF ]
            // Contoh: [ 1 - 9 2   9 8 ] (STEMI, 92 BPM, 98% Confidence)
            // -----------------------------------------------------------------
            dp_ns = 1'b1;
            case (digit_sel)
                // DIGIT 7 (Paling Kiri): Hasil Diagnosis Utama
                3'd7: begin
                    an_ns = 8'b01111111;
                    case (class_id_i)
                        2'b00:   seg_ns = CHAR_0;    // 0: Normal Sinus Rhythm (atau CHAR_n)
                        2'b01:   seg_ns = CHAR_1;    // 1: Infark Miokard / STEMI (atau CHAR_H)
                        2'b10:   seg_ns = CHAR_2;    // 2: Unknown Dysrhythmia (atau CHAR_U)
                        default: seg_ns = CHAR_DASH;
                    endcase
                    dp_ns = ~r_blink_active; // Titik DP berkedip saat detak R
                end

                // DIGIT 6: Pemisah '-'
                3'd6: begin
                    an_ns  = 8'b10111111;
                    seg_ns = CHAR_DASH;
                end

                // DIGIT 5: BPM Puluhan (atau Ratusan jika > 99)
                3'd5: begin
                    an_ns  = 8'b11011111;
                    seg_ns = (bpm_i >= 100) ? bcd_to_7seg(bpm_hundreds) : 
                             (bpm_tens > 0) ? bcd_to_7seg(bpm_tens) : CHAR_BLANK;
                end

                // DIGIT 4: BPM Satuan (atau Puluhan jika > 99)
                3'd4: begin
                    an_ns  = 8'b11101111;
                    seg_ns = (bpm_i >= 100) ? bcd_to_7seg(bpm_tens) : bcd_to_7seg(bpm_ones);
                end

                // DIGIT 3: Spasi / Blank
                3'd3: begin
                    an_ns  = 8'b11110111;
                    seg_ns = (bpm_i >= 100) ? bcd_to_7seg(bpm_ones) : CHAR_BLANK;
                end

                // DIGIT 2: Confidence Ratusan (jika 100%) atau Puluhan
                3'd2: begin
                    an_ns  = 8'b11111011;
                    seg_ns = (conf_hundreds > 0) ? bcd_to_7seg(conf_hundreds) : 
                             (conf_tens > 0)     ? bcd_to_7seg(conf_tens)     : CHAR_BLANK;
                end

                // DIGIT 1: Confidence Puluhan (jika 100%) atau Satuan
                3'd1: begin
                    an_ns  = 8'b11111101;
                    seg_ns = (conf_hundreds > 0) ? bcd_to_7seg(conf_tens) : bcd_to_7seg(conf_ones);
                end

                // DIGIT 0 (Paling Kanan): Confidence Satuan jika 100%, atau Blank
                3'd0: begin
                    an_ns  = 8'b11111110;
                    seg_ns = (conf_hundreds > 0) ? bcd_to_7seg(conf_ones) : CHAR_BLANK;
                end

                default: begin
                    an_ns  = 8'b11111111;
                    seg_ns = CHAR_BLANK;
                end
            endcase
        end
    end

    // =========================================================================
    // 4. ASSIGN REGISTER INTERNAL _ps KE OUTPUT WIRE
    // =========================================================================
    assign an_o  = an_ps;
    assign seg_o = seg_ps;
    assign dp_o  = dp_ps;

endmodule
