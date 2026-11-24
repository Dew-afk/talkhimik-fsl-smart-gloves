// flex.h — flex sensor ADC reads (voltage divider -> resistance).
#pragma once
#include <stdint.h>

// 12-bit ADC + per-pin 11 dB attenuation for all five flex channels.
void flexBegin();

// Raw 12-bit ADC read for finger `finger` (index into FLEX_PINS). Discards a
// settling read (the 10k divider means ~7-9k source impedance and lingering
// charge between channel switches), then averages `samples` reads spaced by
// `sampleDelayUs`. Calibration passes 30 samples / 10 ms; telemetry uses the
// 8-sample default.
uint16_t flexReadAdc(uint8_t finger, int samples = 8, int sampleDelayUs = 500);

// Convert an averaged ADC count to sensor ohms.
// Sensor on the 3.3 V side, R_DIV to GND: R_sensor = R_DIV * (4095 - adc) / adc.
// Guards: adc <= 0 -> huge R, adc >= 4095 -> ~0 R.
float adcToResistance(uint8_t finger, uint16_t adc);

// Averaged resistance for finger `finger` (one ADC pass + conversion).
float flexReadResistance(uint8_t finger, int samples = 8, int sampleDelayUs = 500);
