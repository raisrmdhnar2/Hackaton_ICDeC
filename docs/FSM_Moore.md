# PANDUAN DESAIN RTL: FSM MOORE (HARDWARE-DRIVEN GUIDELINES)

> **MINDSET UTAMA:**
> Kode Verilog yang ditulis di sini **BUKAN program perangkat lunak/informatika**, melainkan representasi inferensi gerbang logika, flip-flop, dan interkoneksi silikon fisik pada FPGA (Xilinx Artix-7). 
> Setiap baris kode harus merepresentasikan struktur hardware nyata: register clock, multiplexer, dan logika kombinasional.

---

## 1. ATURAN BAKU PERANCANGAN FSM MOORE & REGISTER INTERNAL

### A. Aturan Deklarasi Port Output (Wire Output & No Unpacked Array Rule)
1. **Seluruh Port Output Wajib Bertipe `output wire`:**
   - Dilarang keras menggunakan `output reg` pada header modul.
   - Port kontrol 1-bit dideklarasikan sebagai `output wire <signal>_o`.
   - Port bus data numerik multi-bit (amplitudo, timestamp, fitur INT8, marker) **BOLEH & WAJIB** memiliki rentang bit eksplisit (packed vector):
     ```verilog
     // BENAR: Port kontrol 1-bit wire
     output wire                      t_r_o,
     output wire                      qrst_done_o,
     output wire                      feat_valid_o,

     // BENAR: Port bus data numerik wire dengan rentang bit eksplisit
     output wire signed [15:0]        r_amp_o,
     output wire        [15:0]        t_r_val_o,
     output wire        [7:0]         heart_rate_bpm_o,
     output wire signed [7:0]         feat_x1_o
     ```
2. **Dilarang Port Bertipe Array Multidimensi (Unpacked Array):**
   - Dilarang keras mendeklarasikan port berupa memori array (misal `output wire [15:0] tap [0:2]`). Seluruh data port harus berupa skalar atau bus vektor 1-dimensi terpisah.
3. **Penyimpanan Data Penuh di Register Internal (`_ps` dan `_ns`):**
   - Seluruh nilai data register sekuensial disimpan di variabel internal berpasangan `_ps` (Present State) dan `_ns` (Next State).
4. **Penugasan Akhir via `assign`:**
   - Seluruh port keluaran fisik dihubungkan langsung dari register internal `_ps`:
     ```verilog
     assign t_r_o     = t_r_ps;
     assign r_amp_o   = r_amp_ps;
     assign feat_x1_o = feat_x1_ps;
     ```

---

### B. Konvensi Register Internal Sekuensial Berpasangan `_ps` dan `_ns`
Mengikuti pola standar implementasi hardware sekuensial:
1. **Penamaan Berpasangan Konsisten:**
   Setiap variabel kontrol atau datapath wajib memiliki sepasang register:
   ```verilog
   reg [2:0]         state_ps, state_ns;       // Register State FSM
   reg signed [15:0] r_amp_ps, r_amp_ns;       // Data Amplitudo
   reg        [15:0] t_r_val_ps, t_r_val_ns;   // Data Waktu / Timestamp
   reg               t_r_ps, t_r_ns;           // Sinyal Tanda / Pulsa
   ```
2. **Pola Tiga Blok Fungsional (3-Always Block Paradigm):**

   * **Blok 1: Sekuensial Sinkron (Clock & Async Reset)**
     - Hanya bertugas memindahkan nilai `_ns` ke `_ps` pada setiap sisi positif clock (`posedge clk`).
     - Menggunakan *non-blocking assignment* (`<=`).
     - Inisialisasi reset wajib jelas (`!rst_n` atau `rst == 1`).
     ```verilog
     always @(posedge clk or negedge rst_n) begin
         if (!rst_n) begin
             state_ps   <= S_IDLE;
             r_amp_ps   <= 16'sd0;
             t_r_val_ps <= 16'd0;
             t_r_ps     <= 1'b0;
         end else if (ce) begin
             state_ps   <= state_ns;
             r_amp_ps   <= r_amp_ns;
             t_r_val_ps <= t_r_val_ns;
             t_r_ps     <= t_r_ns;
         end
     end
     ```

   * **Blok 2: Logika Kombinasional Next-State & Datapath (`always @(*)`)**
     - Menggunakan *blocking assignment* (`=`).
     - **Anti-Latch Guarantee Wajib:** Di awal blok `always @(*)`, wajib memberikan nilai *default* untuk seluruh variabel `_ns` sama dengan `_ps` (`<signal>_ns = <signal>_ps;`).
     - Pulsa strobo 1-siklus diberi nilai default `0` (`t_r_ns = 1'b0;`).
     - Setiap `case (state_ps)` wajib memiliki `default: state_ns = S_IDLE;`.
     ```verilog
     always @(*) begin
         // Default assignment pencegah inferensi latch
         state_ns   = state_ps;
         r_amp_ns   = r_amp_ps;
         t_r_val_ns = t_r_val_ps;
         t_r_ns     = 1'b0; // Default pulsa strobo 1-clk
         
         case (state_ps)
             S_IDLE: begin
                 if (condition) begin
                     state_ns   = S_PEAK;
                     t_r_ns     = 1'b1;
                     r_amp_ns   = data_in;
                     t_r_val_ns = sample_cnt_i;
                 end
             end
             S_PEAK: begin
                 state_ns = S_IDLE;
                 t_r_ns   = 1'b0;
             end
             default: begin
                 state_ns = S_IDLE;
                 t_r_ns   = 1'b0;
             end
         endcase
     end
     ```

   * **Blok 3: Hardware Output Binding (`assign`)**
     - Seluruh port output terikat langsung ke register `_ps`.
     - Memberikan jaminan bebas *glitch* kombinasional pada sinyal kontrol.
     ```verilog
     assign t_r_o     = t_r_ps;
     assign r_amp_o   = r_amp_ps;
     assign t_r_val_o = t_r_val_ps;
     ```

---

## 2. ATURAN SIMULASI & VERIFIKASI (TESTBENCH)
1. **Clean Console Logging:**
   - Dilarang mencetak log per siklus clock ($100\text{ MHz}$) atau per sampel ($1\text{ ms}$).
   - Log hanya dicetak saat denyut selesai diekstraksi (`feat_valid == 1` atau `qrst_done == 1`).
2. **Kesesuaian Port Mapping:**
   - Testbench harus menginstansiasi modul menggunakan penamaan port eksplisit `.port_name(wire_name)`.