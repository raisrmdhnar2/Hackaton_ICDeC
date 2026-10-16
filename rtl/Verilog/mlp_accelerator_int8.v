`timescale 1ns / 1ns
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: Antigravity AI
// 
// Create Date: 14.10.2026
// Design Name: ECG Myocardial Infarction Classifier
// Module Name: mlp_accelerator_int8
// Project Name: Hackathon ICDeC
// Target Devices: Artix-7 / Spartan-7 FPGA
// Tool Versions: Vivado 2024.1 / 2025.1
// Description:
//   Akselerator Inferensi Perangkat Keras Multilayer Perceptron (MLP 12 -> 8 -> 3)
//   Kuantisasi Simetris INT8 Penuh (Bobot 120-byte dalam Distributed ROM).
//   
//   Standar Implementasi:
//   - Header Port: Seluruh output bertipe 'output wire' dengan bus bit eksplisit.
//   - Tidak menggunakan 'output reg' dan tidak menggunakan unpacked array pada port.
//   - Arsitektur FSM Moore Murni 3-Block (Sequential, Combinational, Port Assign).
//   - Anti-Latch Default Assignment di awal blok kombinatorial.
//
//   Arsitektur Jaringan:
//   - Input Layer  : 12 Fitur Morfologi Klinis QRST INT8 (in_x1 s.d. in_x12)
//   - Hidden Layer : 8 Neuron Tersembunyi dengan Aktivasi ReLU
//   - Output Layer : 3 Neuron Logits (Normal, Infark Miokard, Unknown)
//   - Pengambilan Keputusan: Argmax Output Terbesar
//////////////////////////////////////////////////////////////////////////////////

module mlp_accelerator_int8 #(
    parameter WEIGHTS_FILE = "weights_int8.mem"
)(
    input  wire                   clk,
    input  wire                   rst_n,
    input  wire                   ce,
    input  wire                   start_i,
    
    // 12 Fitur Morfologi Masukan (INT8 Signed [-128 s.d. 127])
    input  wire signed [7:0]      in_x1_i,
    input  wire signed [7:0]      in_x2_i,
    input  wire signed [7:0]      in_x3_i,
    input  wire signed [7:0]      in_x4_i,
    input  wire signed [7:0]      in_x5_i,
    input  wire signed [7:0]      in_x6_i,
    input  wire signed [7:0]      in_x7_i,
    input  wire signed [7:0]      in_x8_i,
    input  wire signed [7:0]      in_x9_i,
    input  wire signed [7:0]      in_x10_i,
    input  wire signed [7:0]      in_x11_i,
    input  wire signed [7:0]      in_x12_i,
    
    // Header Output: 'output wire' dengan rentang bit eksplisit (SESUAI ATURAN MOORE)
    output wire signed [7:0]      score_normal_o,
    output wire signed [7:0]      score_mi_o,
    output wire signed [7:0]      score_unknown_o,
    output wire [1:0]             class_pred_o,   // 0: Normal, 1: Infark Miokard, 2: Unknown
    output wire                   done_o
);

    // =========================================================================
    // ENUMERASI STATE FSM MOORE
    // =========================================================================
    localparam [2:0]
        S_IDLE     = 3'b000,
        S_L1_LOAD  = 3'b001,
        S_L1_CALC  = 3'b010,
        S_L2_LOAD  = 3'b011,
        S_L2_CALC  = 3'b100,
        S_ARGMAX   = 3'b101,
        S_DONE     = 3'b110;

    // =========================================================================
    // ROM BOBOT TERKUANTISASI INT8 (120 BYTES TOTAL)
    // W1: addr 0..95  (8 neuron x 12 fitur)
    // W2: addr 96..119 (3 kelas x 8 neuron)
    // =========================================================================
    reg signed [7:0] rom_weights [0:119];
    initial begin
        $readmemh(WEIGHTS_FILE, rom_weights);
    end

    // =========================================================================
    // REGISTER PRESENT STATE (_ps) & NEXT STATE (_ns) FSM MOORE
    // =========================================================================
    reg [2:0] state_ps, state_ns;
    
    // Counter Iterasi
    reg [3:0] idx_feat_ps, idx_feat_ns;   // 0..11
    reg [3:0] idx_hid_ps,  idx_hid_ns;    // 0..7
    reg [1:0] idx_out_ps,  idx_out_ns;    // 0..2
    
    // Akumulator Perkalian (Signed 24-bit mencegah overflow)
    reg signed [23:0] accum_ps, accum_ns;
    
    // Register Penyangga Input 12 Fitur (INT8)
    reg signed [7:0] x_reg_ps [0:11];
    reg signed [7:0] x_reg_ns [0:11];
    
    // Register Aktivasi Hidden Layer (8 Neuron INT8 [0..127])
    reg signed [7:0] h_act_ps [0:7];
    reg signed [7:0] h_act_ns [0:7];
    
    // Register Output Skor & Prediksi Kelas
    reg signed [7:0] score_norm_ps, score_norm_ns;
    reg signed [7:0] score_mi_ps,   score_mi_ns;
    reg signed [7:0] score_unk_ps,  score_unk_ns;
    reg [1:0]        class_pred_ps, class_pred_ns;
    reg              done_ps,       done_ns;

    // ROM Read Wire (Kombinatorial pembacaan bobot berdasarkan alamat)
    reg [6:0] rom_addr;
    wire signed [7:0] current_weight;
    assign current_weight = rom_weights[rom_addr];

    // =========================================================================
    // BLOK 1: SEKUENSIAL CLOCK DRIVEN (UPDATE _ps DARI _ns)
    // =========================================================================
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_ps       <= S_IDLE;
            idx_feat_ps    <= 4'd0;
            idx_hid_ps     <= 4'd0;
            idx_out_ps     <= 2'd0;
            accum_ps       <= 24'sd0;
            score_norm_ps  <= 8'sd0;
            score_mi_ps    <= 8'sd0;
            score_unk_ps   <= 8'sd0;
            class_pred_ps  <= 2'b00;
            done_ps        <= 1'b0;
            for (i = 0; i < 12; i = i + 1) begin
                x_reg_ps[i] <= 8'sd0;
            end
            for (i = 0; i < 8; i = i + 1) begin
                h_act_ps[i] <= 8'sd0;
            end
        end else if (ce) begin
            state_ps       <= state_ns;
            idx_feat_ps    <= idx_feat_ns;
            idx_hid_ps     <= idx_hid_ns;
            idx_out_ps     <= idx_out_ns;
            accum_ps       <= accum_ns;
            score_norm_ps  <= score_norm_ns;
            score_mi_ps    <= score_mi_ns;
            score_unk_ps   <= score_unk_ns;
            class_pred_ps  <= class_pred_ns;
            done_ps        <= done_ns;
            for (i = 0; i < 12; i = i + 1) begin
                x_reg_ps[i] <= x_reg_ns[i];
            end
            for (i = 0; i < 8; i = i + 1) begin
                h_act_ps[i] <= h_act_ns[i];
            end
        end
    end

    // =========================================================================
    // BLOK 2: LOGIKA KOMBINATORIAL (NEXT STATE & NEXT REGISTER LOGIC)
    // Anti-latch default assignment diterapkan secara menyeluruh.
    // =========================================================================
    reg signed [15:0] mult_result;
    reg signed [23:0] shifted_relu;
    reg signed [23:0] shifted_out;
    integer k;

    always @(*) begin
        // --- Anti-Latch Default Assignment ---
        state_ns       = state_ps;
        idx_feat_ns    = idx_feat_ps;
        idx_hid_ns     = idx_hid_ps;
        idx_out_ns     = idx_out_ps;
        accum_ns       = accum_ps;
        score_norm_ns  = score_norm_ps;
        score_mi_ns    = score_mi_ps;
        score_unk_ns   = score_unk_ns;
        class_pred_ns  = class_pred_ps;
        done_ns        = 1'b0;
        rom_addr       = 7'd0;
        mult_result    = 16'sd0;
        shifted_relu   = 24'sd0;
        shifted_out    = 24'sd0;

        for (k = 0; k < 12; k = k + 1) begin
            x_reg_ns[k] = x_reg_ps[k];
        end
        for (k = 0; k < 8; k = k + 1) begin
            h_act_ns[k] = h_act_ps[k];
        end

        // --- Transisi State & Komputasi ---
        case (state_ps)
            S_IDLE: begin
                idx_feat_ns = 4'd0;
                idx_hid_ns  = 4'd0;
                idx_out_ns  = 2'd0;
                accum_ns    = 24'sd0;
                done_ns     = 1'b0;

                if (start_i) begin
                    // Latch 12 masukan fitur ke register internal
                    x_reg_ns[0]  = in_x1_i;
                    x_reg_ns[1]  = in_x2_i;
                    x_reg_ns[2]  = in_x3_i;
                    x_reg_ns[3]  = in_x4_i;
                    x_reg_ns[4]  = in_x5_i;
                    x_reg_ns[5]  = in_x6_i;
                    x_reg_ns[6]  = in_x7_i;
                    x_reg_ns[7]  = in_x8_i;
                    x_reg_ns[8]  = in_x9_i;
                    x_reg_ns[9]  = in_x10_i;
                    x_reg_ns[10] = in_x11_i;
                    x_reg_ns[11] = in_x12_i;
                    state_ns     = S_L1_LOAD;
                end
            end

            // Persiapan akumulasi neuron hidden layer
            S_L1_LOAD: begin
                accum_ns    = 24'sd0;
                idx_feat_ns = 4'd0;
                state_ns    = S_L1_CALC;
            end

            // Komputasi Layer 1: MAC W1 * x
            S_L1_CALC: begin
                rom_addr    = idx_hid_ps * 7'd12 + idx_feat_ps;
                mult_result = x_reg_ps[idx_feat_ps] * current_weight;
                accum_ns    = accum_ps + {{8{mult_result[15]}}, mult_result};

                if (idx_feat_ps == 4'd11) begin
                    // Selesai 12 fitur untuk neuron tersembunyi idx_hid_ps
                    // Terapkan ReLU dan scaling ke INT8 [0..127]
                    if (accum_ns > 24'sd0) begin
                        shifted_relu = accum_ns >>> 8; // Bit shift scaling / kuantisasi
                        if (shifted_relu > 24'sd127)
                            h_act_ns[idx_hid_ps] = 8'sd127;
                        else
                            h_act_ns[idx_hid_ps] = shifted_relu[7:0];
                    end else begin
                        h_act_ns[idx_hid_ps] = 8'sd0; // ReLU clip non-negatif
                    end

                    // Cek apakah seluruh 8 hidden neuron sudah selesai
                    if (idx_hid_ps == 4'd7) begin
                        idx_hid_ns = 4'd0;
                        idx_out_ns = 2'd0;
                        state_ns   = S_L2_LOAD;
                    end else begin
                        idx_hid_ns = idx_hid_ps + 4'd1;
                        state_ns   = S_L1_LOAD;
                    end
                end else begin
                    idx_feat_ns = idx_feat_ps + 4'd1;
                end
            end

            // Persiapan akumulasi neuron output layer
            S_L2_LOAD: begin
                accum_ns   = 24'sd0;
                idx_hid_ns = 4'd0;
                state_ns   = S_L2_CALC;
            end

            // Komputasi Layer 2: MAC W2 * H
            S_L2_CALC: begin
                rom_addr    = 7'd96 + (idx_out_ps * 7'd8) + idx_hid_ps;
                mult_result = h_act_ps[idx_hid_ps] * current_weight;
                accum_ns    = accum_ps + {{8{mult_result[15]}}, mult_result};

                if (idx_hid_ps == 4'd7) begin
                    // Selesai 8 hidden activations untuk neuron output idx_out_ps
                    // Skalakan hasil ke rentang skor logits INT8 [-128..127]
                    shifted_out = accum_ns >>> 8;
                    if (shifted_out > 24'sd127)
                        shifted_out = 24'sd127;
                    else if (shifted_out < -24'sd128)
                        shifted_out = -24'sd128;

                    if (idx_out_ps == 2'd0)
                        score_norm_ns = shifted_out[7:0];
                    else if (idx_out_ps == 2'd1)
                        score_mi_ns = shifted_out[7:0];
                    else
                        score_unk_ns = shifted_out[7:0];

                    if (idx_out_ps == 2'd2) begin
                        state_ns = S_ARGMAX;
                    end else begin
                        idx_out_ns = idx_out_ps + 2'd1;
                        state_ns   = S_L2_LOAD;
                    end
                end else begin
                    idx_hid_ns = idx_hid_ps + 4'd1;
                end
            end

            // Pengambilan Keputusan Argmax Berdasarkan Skor Tertinggi
            S_ARGMAX: begin
                if (score_mi_ps > score_norm_ps && score_mi_ps > score_unk_ps) begin
                    class_pred_ns = 2'b01; // Kelas 1: Infark Miokard
                end else if (score_unk_ps > score_norm_ps && score_unk_ps >= score_mi_ps) begin
                    class_pred_ns = 2'b10; // Kelas 2: Unknown
                end else begin
                    class_pred_ns = 2'b00; // Kelas 0: Normal
                end
                state_ns = S_DONE;
            end

            // State Selesai (Pulsa done_o selama 1 cycle)
            S_DONE: begin
                done_ns  = 1'b1;
                state_ns = S_IDLE;
            end

            default: begin
                state_ns = S_IDLE;
            end
        endcase
    end

    // =========================================================================
    // BLOK 3: PENUGASAN PORT OUTPUT DARI PRESENT STATE (MOORE COMPLIANT)
    // Sesuai standar docs/FSM_Moore.md: assign <port> = <signal>_ps;
    // =========================================================================
    assign score_normal_o  = score_norm_ps;
    assign score_mi_o      = score_mi_ps;
    assign score_unknown_o = score_unk_ps;
    assign class_pred_o    = class_pred_ps;
    assign done_o          = done_ps;

endmodule

