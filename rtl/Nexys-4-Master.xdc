## ==============================================================================
## XDC Constraint File untuk Digilent Nexys-4 (XC7A100T-1CSG324C)
## Proyek : Indonesia Chip Hackathon Challenge 2026 (DIICES UB)
## Top-Level : top_chip_ecg_uart.v
## ==============================================================================

## -----------------------------------------------------------------------------
## 1. CLOCK UTAMA 100 MHz (OSILATOR ONBOARD)
## -----------------------------------------------------------------------------
set_property PACKAGE_PIN E3 [get_ports clk]							
set_property IOSTANDARD LVCMOS33 [get_ports clk]
create_clock -add -name sys_clk_pin -period 10.00 -waveform {0 5} [get_ports clk]

## -----------------------------------------------------------------------------
## 2. RESET TOMBOL (CPU RESET - ACTIVE LOW)
## -----------------------------------------------------------------------------
set_property PACKAGE_PIN C12 [get_ports rst_n]				
set_property IOSTANDARD LVCMOS33 [get_ports rst_n]

## -----------------------------------------------------------------------------
## 3. SAKELAR KONTROL (SLIDE SWITCHES)
## -----------------------------------------------------------------------------
## SW0: Saklar Enable Pemrosesan EKG (1 = ON/Aktif, 0 = OFF/Standby)
set_property PACKAGE_PIN U9 [get_ports enable_sw_i]					
set_property IOSTANDARD LVCMOS33 [get_ports enable_sw_i]

## SW1: Saklar Uji Loopback UART (1 = Loopback Aktif, 0 = Normal)
set_property PACKAGE_PIN U8 [get_ports loopback_en_i]					
set_property IOSTANDARD LVCMOS33 [get_ports loopback_en_i]

## -----------------------------------------------------------------------------
## 4. ANTARMUKA USB-RS232 (FTDI FT2232HQ ONBOARD @ 115.200 bps)
## -----------------------------------------------------------------------------
## C4: UART_TXD_IN dari FTDI chip -> Masuk ke FPGA RX (uart_rx_i)
set_property PACKAGE_PIN C4 [get_ports uart_rx_i]						
set_property IOSTANDARD LVCMOS33 [get_ports uart_rx_i]

## D4: UART_RXD_OUT dari FPGA TX -> Masuk ke FTDI chip (uart_tx_o)
set_property PACKAGE_PIN D4 [get_ports uart_tx_o]						
set_property IOSTANDARD LVCMOS33 [get_ports uart_tx_o]

## -----------------------------------------------------------------------------
## 5. DISPLAY 7-SEGMENT 8-DIGIT (COMMON ANODE - ACTIVE LOW)
## -----------------------------------------------------------------------------
## Katoda Segmen A..G (0 = Segmen Nyala, 1 = Segmen Mati)
set_property PACKAGE_PIN L3 [get_ports {seg_o[0]}]					
set_property IOSTANDARD LVCMOS33 [get_ports {seg_o[0]}]
set_property PACKAGE_PIN N1 [get_ports {seg_o[1]}]					
set_property IOSTANDARD LVCMOS33 [get_ports {seg_o[1]}]
set_property PACKAGE_PIN L5 [get_ports {seg_o[2]}]					
set_property IOSTANDARD LVCMOS33 [get_ports {seg_o[2]}]
set_property PACKAGE_PIN L4 [get_ports {seg_o[3]}]					
set_property IOSTANDARD LVCMOS33 [get_ports {seg_o[3]}]
set_property PACKAGE_PIN K3 [get_ports {seg_o[4]}]					
set_property IOSTANDARD LVCMOS33 [get_ports {seg_o[4]}]
set_property PACKAGE_PIN M2 [get_ports {seg_o[5]}]					
set_property IOSTANDARD LVCMOS33 [get_ports {seg_o[5]}]
set_property PACKAGE_PIN L6 [get_ports {seg_o[6]}]					
set_property IOSTANDARD LVCMOS33 [get_ports {seg_o[6]}]

## Titik Desimal (DP)
set_property PACKAGE_PIN M4 [get_ports dp_o]							
set_property IOSTANDARD LVCMOS33 [get_ports dp_o]

## Anoda 8-Digit (0 = Digit Aktif, 1 = Digit Mati)
set_property PACKAGE_PIN N6 [get_ports {an_o[0]}]					
set_property IOSTANDARD LVCMOS33 [get_ports {an_o[0]}]
set_property PACKAGE_PIN M6 [get_ports {an_o[1]}]					
set_property IOSTANDARD LVCMOS33 [get_ports {an_o[1]}]
set_property PACKAGE_PIN M3 [get_ports {an_o[2]}]					
set_property IOSTANDARD LVCMOS33 [get_ports {an_o[2]}]
set_property PACKAGE_PIN N5 [get_ports {an_o[3]}]					
set_property IOSTANDARD LVCMOS33 [get_ports {an_o[3]}]
set_property PACKAGE_PIN N2 [get_ports {an_o[4]}]					
set_property IOSTANDARD LVCMOS33 [get_ports {an_o[4]}]
set_property PACKAGE_PIN N4 [get_ports {an_o[5]}]					
set_property IOSTANDARD LVCMOS33 [get_ports {an_o[5]}]
set_property PACKAGE_PIN L1 [get_ports {an_o[6]}]					
set_property IOSTANDARD LVCMOS33 [get_ports {an_o[6]}]
set_property PACKAGE_PIN M1 [get_ports {an_o[7]}]					
set_property IOSTANDARD LVCMOS33 [get_ports {an_o[7]}]

## -----------------------------------------------------------------------------
## 6. LED INDIKATOR STATUS BOARD
## -----------------------------------------------------------------------------
## LED0 & LED1: Hasil Klasifikasi (00: Normal, 01: Infark Miokard, 10: Unknown)
set_property PACKAGE_PIN T8 [get_ports {led_diagnosis_o[0]}]					
set_property IOSTANDARD LVCMOS33 [get_ports {led_diagnosis_o[0]}]
set_property PACKAGE_PIN V9 [get_ports {led_diagnosis_o[1]}]					
set_property IOSTANDARD LVCMOS33 [get_ports {led_diagnosis_o[1]}]

## LED2: Pulsa Detak Puncak R (Heartbeat Blink)
set_property PACKAGE_PIN R8 [get_ports led_r_peak_o]					
set_property IOSTANDARD LVCMOS33 [get_ports led_r_peak_o]

## LED3: Aktivitas Penerimaan Serial RX
set_property PACKAGE_PIN T6 [get_ports led_rx_tick_o]					
set_property IOSTANDARD LVCMOS33 [get_ports led_rx_tick_o]

## LED4: Aktivitas Pengiriman Serial TX
set_property PACKAGE_PIN T5 [get_ports led_tx_tick_o]					
set_property IOSTANDARD LVCMOS33 [get_ports led_tx_tick_o]

## -----------------------------------------------------------------------------
## 7. KONFIGURASI SPESIFIK BITSTREAM
## -----------------------------------------------------------------------------
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]

