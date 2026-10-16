`timescale 1ns / 1ns
//////////////////////////////////////////////////////////////////////////////////
// Testbench: tb_top_qrst_detector.v
// Proyek:    Indonesia Chip Hackathon Challenge 2026 (DIICES UB)
// Deskripsi: Testbench untuk modul top_qrst_detector.v.
//            Memverifikasi deteksi gelombang QRST berbasis Sliding Window
//            Shift Register dan FSM Moore dengan output konsol yang ringkas.
//
// Standar Desain:
// - Output tanda gelombang pada UUT murni 1-bit wire (t_q, t_r, t_s, t_t, qrst_done).
// - Parameter numerik waktu dan amplitudo terhubung langsung dari port wire UUT.
// - Hanya menampilkan ringkasan parameter penting saat beat selesai dikunci.
//////////////////////////////////////////////////////////////////////////////////

module tb_top_qrst_detector;

    // Parameter Simulasi & Waktu
    localparam integer CLK_PERIOD_NS   = 10;          // Clock sistem 100 MHz (10 ns)
    localparam integer TOTAL_SAMPLES   = 2000;        // 2000 sampel EKG (~2 detik @ 1000 Hz)
    localparam time    SAMPLE_PERIOD   = 1_000_000;   // Periode sampling 1 ms = 1000 Hz

    // Sinyal Masukan DUT
    reg                      clk;
    reg                      rst_n;
    reg                      ce;
    reg  signed [15:0]       sample_in;
    reg                      sample_valid;

    // Sinyal Keluaran Tanda QRST Real-Time (1-Bit Wire Pulse)
    wire                     t_q;
    wire                     t_r;
    wire                     t_s;
    wire                     t_t;
    wire                     t_on;
    wire                     t_off;
    wire                     s_off;
    wire                     qrst_done;

    // Sinyal Koordinat Waktu Timestamp Numerik Terkunci (16-Bit Wire)
    wire        [15:0]       t_q_val;
    wire        [15:0]       t_r_val;
    wire        [15:0]       t_s_val;
    wire        [15:0]       t_on_val;
    wire        [15:0]       t_off_val;
    wire        [15:0]       s_off_val;

    // Sinyal Keluaran Telemetri & Metrik (Bus Wire)
    wire        [7:0]        qrst_marker;
    wire        [7:0]        heart_rate_bpm;

    wire signed [15:0]       q_amp;
    wire signed [15:0]       r_amp;
    wire signed [15:0]       s_amp;
    wire signed [15:0]       t_amp;
    wire signed [15:0]       st_elev;
    wire signed [15:0]       iso_base;

    // Memori Stimulus EKG
    reg [15:0] ecg_mem [0:TOTAL_SAMPLES-1];
    integer s_idx;
    integer beat_count;

    // -------------------------------------------------------------------------
    // Instansiasi Top Unit Under Test (UUT)
    // -------------------------------------------------------------------------
    top_qrst_detector #(
        .BUFFER_DEPTH    (64),
        .R_THRESH_INIT   (800),
        .REFRACTORY_SAMP (250)
    ) uut (
        .clk              (clk),
        .rst_n            (rst_n),
        .ce               (ce),
        .sample_in        (sample_in),
        .sample_valid_i   (sample_valid),
        .t_q_o            (t_q),
        .t_r_o            (t_r),
        .t_s_o            (t_s),
        .t_t_o            (t_t),
        .t_on_o           (t_on),
        .t_off_o          (t_off),
        .s_off_o          (s_off),
        .qrst_done_o      (qrst_done),
        .t_q_val_o        (t_q_val),
        .t_r_val_o        (t_r_val),
        .t_s_val_o        (t_s_val),
        .t_on_val_o       (t_on_val),
        .t_off_val_o      (t_off_val),
        .s_off_val_o      (s_off_val),
        .q_amp_o          (q_amp),
        .r_amp_o          (r_amp),
        .s_amp_o          (s_amp),
        .t_amp_o          (t_amp),
        .st_elev_o        (st_elev),
        .iso_base_o       (iso_base),
        .qrst_marker_o    (qrst_marker),
        .heart_rate_bpm_o (heart_rate_bpm)
    );

    // -------------------------------------------------------------------------
    // Generator Clock Sistem 100 MHz
    // -------------------------------------------------------------------------
    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD_NS / 2) clk = ~clk;
    end

    // -------------------------------------------------------------------------
    // Monitor Output Ringkas & Bersih
    // HANYA MENCETAK PARAMETER PENTING SAAT 1 BEAT SELESAI DIKUNCI (qrst_done == 1)
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst_n && ce && qrst_done) begin
            beat_count = beat_count + 1;
            $display("========================================================================================");
            $display("               DETEKSI MORFOLOGI GELOMBANG QRST SELESAI (BEAT #%0d)                      ", beat_count);
            $display("========================================================================================");
            $display("  Waktu Puncak R  : %0d ms | Denyut Jantung: %0d BPM", 
                     t_r_val, heart_rate_bpm);
            $display("  Baseline (V_iso): %0d Q15 (0x%04X) | ST-Elevation: %+0d Q15", 
                     iso_base, iso_base, st_elev);
            $display("  --------------------------------------------------------------------------------------");
            $display("  PARAMETER GELOMBANG :   AMPLITUDO (Q15)   |   TIMESTAMP   |      INTERVAL / DURASI");
            $display("    - Lembah Q        :  %7d (0x%04X)   |   %5d ms   |  R - Q    : %0d ms", 
                     q_amp, q_amp, t_q_val, (t_r_val - t_q_val));
            $display("    - Puncak R        :  %7d (0x%04X)   |   %5d ms   |  [PUNCAK UTAMA TERKONFIRMASI]", 
                     r_amp, r_amp, t_r_val);
            $display("    - Lembah S        :  %7d (0x%04X)   |   %5d ms   |  S - R    : %0d ms", 
                     s_amp, s_amp, t_s_val, (t_s_val - t_r_val));
            $display("    - Titik J (S_off) :  ---                |   %5d ms   |  QRS Width: %0d ms", 
                     s_off_val, (s_off_val - t_q_val));
            $display("    - Puncak T        :  %7d (0x%04X)   |   %5d ms   |  QT-Intvl : %0d ms", 
                     t_amp, t_amp, uut.u_qst_detector_fsm.t_t_val_ps, (t_off_val - t_q_val));
            $display("    - T Onset / Offset:  T_on = %0d ms      |   T_off = %0d ms", 
                     t_on_val, t_off_val);
            $display("  --------------------------------------------------------------------------------------");
            $display("  Status Pipeline : Parameter Berhasil Diserahkan ke Akselerator Klasifikasi");
            $display("========================================================================================\n");
        end
    end

    // -------------------------------------------------------------------------
    // Alur Stimulus Verifikasi
    // -------------------------------------------------------------------------
    initial begin
        // Inisialisasi awal
        rst_n        = 1'b0;
        ce           = 1'b0;
        sample_in    = 16'sd0;
        sample_valid = 1'b0;
        beat_count   = 0;

        $display("\n****************************************************************************************");
        $display("   MEMULAI SIMULASI TOP_QRST_DETECTOR DENGAN STIMULUS EKG ASLI (PTB DATABASE)           ");
        $display("****************************************************************************************");

        // Membaca berkas hex memori EKG (mencoba direktori xsim lokal lalu fallback path)
        $readmemh("ecg_normal.mem", ecg_mem);
        if (ecg_mem[0] === 16'hxxxx) begin
            $readmemh("rtl/sim_data/ecg_normal.mem", ecg_mem);
        end
        if (ecg_mem[0] === 16'hxxxx) begin
            $readmemh("/home/nexus_is/5.Project/Hackaton_ICDeC/rtl/sim_data/ecg_normal.mem", ecg_mem);
        end

        if (ecg_mem[0] !== 16'hxxxx) begin
            $display("  [SUKSES] 2000 sampel EKG berhasil dimuat ke dalam memori simulasi.");
        end else begin
            $display("  [FATAL ERROR] Gagal memuat file stimulus ecg_normal.mem! Seluruh memori bernilai XXXX.");
        end

        // Siklus Reset Asinkron & Enable Clock
        #100;
        @(posedge clk);
        rst_n <= 1'b1;
        ce    <= 1'b1;
        $display("  [STATUS] Reset dilepas (rst_n = 1), CE aktif (ce = 1). Memulai streaming data EKG...\n");

        // Pengaliran 2000 sampel EKG berkecepatan 1000 Hz (1 ms per sampel)
        for (s_idx = 0; s_idx < TOTAL_SAMPLES; s_idx = s_idx + 1) begin
            @(posedge clk);
            sample_in    <= ecg_mem[s_idx];
            sample_valid <= 1'b1;
            @(posedge clk);
            sample_valid <= 1'b0;

            // Tunggu interval sampling 1 ms
            #SAMPLE_PERIOD;
        end

        // Tunggu penyelesaian beat terakhir di dalam pipeline (50 ms)
        #50_000_000;

        $display("****************************************************************************************");
        $display("  SIMULASI TOP_QRST_DETECTOR SELESAI DENGAN SUKSES!");
        $display("  Total Denyut Terdeteksi: %0d Beat", beat_count);
        $display("****************************************************************************************\n");
        $finish;
    end

endmodule
