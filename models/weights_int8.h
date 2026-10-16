/* Auto-generated INT8 Quantized Weights & Inference for ECG Classifier (FPGA / MCU) */
#ifndef WEIGHTS_INT8_H
#define WEIGHTS_INT8_H

#include <stdint.h>

#define INPUT_DIM 12
#define HIDDEN_DIM 8
#define NUM_CLASSES 3

// Skala Kuantisasi
#define SCALE_X_INV   1.000000f
#define SCALE_H1_INV  1.000000f
#define SCALE_OUT_INV 1.000000f

// Bobot Layer 1 [8][12] (INT8)
static const int8_t W1_INT8[HIDDEN_DIM][INPUT_DIM] = {
    {33, 30, 36, 8, 8, -1, 17, 14, -2, 11, -4, 0},
    {1, -10, -9, -3, -5, 2, -5, -7, 7, -1, 0, -7},
    {-24, -22, -34, 14, 3, 10, 3, 14, 12, 2, 17, 5},
    {1, -10, -7, 1, 4, 1, -1, -2, -7, -4, -2, 5},
    {-17, -29, -22, 8, -1, 14, 7, 8, 6, 3, 15, 15},
    {-21, -19, -31, 1, 5, 12, 2, 5, 8, -1, 7, 12},
    {0, 8, -13, 4, 0, -1, 0, -10, -1, 2, 7, -3},
    {-4, -3, 5, 2, -3, 3, 0, 5, -4, -2, -2, -7},
};

// Bias Layer 1 [8] (INT32)
static const int32_t b1_INT32[HIDDEN_DIM] = {0, 0, 0, 0, 0, 0, 0, 0};

// Bobot Layer 2 [3][8] (INT8)
static const int8_t W2_INT8[NUM_CLASSES][HIDDEN_DIM] = {
    {18, 4, -39, -4, -57, -34, -5, -12},
    {-23, 6, 54, 3, 26, 30, -29, 0},
    {5, 37, 9, 5, 12, -40, 17, 11},
};

// Bias Layer 2 [3] (INT32)
static const int32_t b2_INT32[NUM_CLASSES] = {0, 0, 0};

/**
 * Inferensi INT8 murni: Mengembalikan output skor logits INT8 untuk 3 kelas:
 * out_scores[0]: Skor Normal
 * out_scores[1]: Skor Infark Miokard
 * out_scores[2]: Skor Unknown
 * Mengembalikan indeks kelas dengan skor tertinggi (0, 1, atau 2).
 */
static inline uint8_t predict_ecg_int8(const int8_t x_in[INPUT_DIM], int8_t out_scores[NUM_CLASSES]) {
    int32_t h_acc[HIDDEN_DIM];
    int8_t h_int8[HIDDEN_DIM];
    
    // Layer 1: H = ReLU(W1 * x + b1)
    for (int i = 0; i < HIDDEN_DIM; i++) {
        int32_t acc = b1_INT32[i];
        for (int j = 0; j < INPUT_DIM; j++) {
            acc += (int32_t)W1_INT8[i][j] * (int32_t)x_in[j];
        }
        if (acc < 0) acc = 0; // ReLU
        // Re-kuantisasi ke INT8 [0, 127]
        int32_t scaled_h = (int32_t)(acc * SCALE_H1_INV);
        if (scaled_h > 127) scaled_h = 127;
        h_int8[i] = (int8_t)scaled_h;
    }
    
    // Layer 2: Out = W2 * H + b2
    uint8_t best_class = 0;
    int32_t max_score = -2147483647;
    for (int k = 0; k < NUM_CLASSES; k++) {
        int32_t acc = b2_INT32[k];
        for (int i = 0; i < HIDDEN_DIM; i++) {
            acc += (int32_t)W2_INT8[k][i] * (int32_t)h_int8[i];
        }
        // Skalakan output menjadi skor INT8 [-128, 127]
        int32_t scaled_out = (int32_t)(acc * SCALE_OUT_INV);
        if (scaled_out > 127) scaled_out = 127;
        if (scaled_out < -128) scaled_out = -128;
        out_scores[k] = (int8_t)scaled_out;
        
        if (scaled_out > max_score) {
            max_score = scaled_out;
            best_class = k;
        }
    }
    return best_class;
}

#endif // WEIGHTS_INT8_H
