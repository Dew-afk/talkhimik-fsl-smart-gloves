#include "flex.h"
#include "config.h"
#include <Arduino.h>

void flexBegin() {
  analogReadResolution(12);
#if defined(ESP_ARDUINO_VERSION_MAJOR) && (ESP_ARDUINO_VERSION_MAJOR >= 3)
  analogContinuousSetAtten(ADC_11db);               // ESP32 Arduino core 3.x
#else
  for (int i = 0; i < 5; i++) {
    analogSetPinAttenuation(FLEX_PINS[i], ADC_11db); // ESP32 Arduino core 2.x
  }
#endif
}

uint16_t flexReadAdc(uint8_t finger, int samples, int sampleDelayUs) {
  int pin = FLEX_PINS[finger];
  analogRead(pin);                            // discard: settling read
  delayMicroseconds(2000);                    // let the new channel settle
  long total = 0;
  for (int i = 0; i < samples; i++) {
    total += analogRead(pin);
    delayMicroseconds(sampleDelayUs);
  }
  return (uint16_t)(total / samples);         // averaged 0..4095 (12-bit)
}

float adcToResistance(uint8_t finger, uint16_t adc) {
  int a = adc;
  if (a <= 0) a = 1;                          // guard: floating pin -> huge R
  if (a >= 4095) a = 4094;                    // guard: shorted sensor -> ~0 R
  return R_DIV[finger] * (4095.0f - a) / a;   // sensor on 3.3 V side, R_DIV to GND
}

float flexReadResistance(uint8_t finger, int samples, int sampleDelayUs) {
  return adcToResistance(finger, flexReadAdc(finger, samples, sampleDelayUs));
}
