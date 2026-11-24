#include "calibration.h"
#include "config.h"
#include "flex.h"
#include "ble_link.h"
#include <Arduino.h>
#include <Preferences.h>
#include <math.h>

// Placeholder profile (~30k flat / ~60k bent): angles derived from these are
// "raw-based" and the STATUS FLAG_UNCALIBRATED bit marks them.
float flatRes[5] = {30000.0f, 30000.0f, 30000.0f, 30000.0f, 30000.0f};
float bendRes[5] = {60000.0f, 60000.0f, 60000.0f, 60000.0f, 60000.0f};
uint16_t flatAdc[5] = {0};
uint16_t bendAdc[5] = {0};
uint16_t spanCounts[5] = {0};

static bool complete = false;   // valid profile present
static bool active = false;     // calibration run in progress
static uint8_t step = 0;        // 0 idle; 1..10 (see header)
static uint8_t finger = 0;      // 0..4 into FLEX_PINS
static uint8_t validMask = 0;   // bit0..4: finger passed quality checks
static uint8_t invalidMask = 0; // failures during the run; ~ & 0x1F at save
static uint8_t weakMask = 0;    // span < 100 counts (warning only)
static uint32_t calId = 0;      // bumps on every saved calibration
static uint8_t calError = ERR_NONE;

// Quality thresholds (dataset recorder contract):
// - span_counts = |bent90_adc - flat_adc| must be >= 100 (else warn)
// - bent90 must differ from flat by at least 5% (else reject, redo capture)
// - flat/bent90 resistance must sit in 1k..100k ohm (else wiring fault)
#define SPAN_MIN_COUNTS   100
#define SPAN_MIN_FRACTION 0.05f
#define RES_MIN_OHM       1000.0f
#define RES_MAX_OHM       100000.0f

bool calibrationLoad() {
  Preferences p;
  p.begin("talkhimik", true);
  bool ok = p.isKey("cal_id");
  if (ok && p.getUChar("pinmap", 0xFF) != PIN_MAP_VERSION) {
    Serial.println("[calib] NVS profile invalidated: pin map changed since calibration");
    ok = false;
  }
  for (int i = 0; i < 5 && ok; i++) {
    String n = FLEX_NAMES[i];
    String k1 = "flat_" + n, k2 = "bend_" + n, k3 = "rdiv_" + n;
    String k4 = "flata_" + n, k5 = "benda_" + n, k6 = "span_" + n;
    if (!p.isKey(k1.c_str()) || !p.isKey(k2.c_str()) || !p.isKey(k3.c_str()) ||
        !p.isKey(k4.c_str()) || !p.isKey(k5.c_str()) || !p.isKey(k6.c_str())) { ok = false; break; }
    float storedRdiv = p.getFloat(k3.c_str(), -1.0f);
    if (storedRdiv < R_DIV[i] - 1.0f || storedRdiv > R_DIV[i] + 1.0f) {
      Serial.println("[calib] NVS profile invalidated: R_DIV changed since calibration");
      ok = false;
      break;
    }
    flatRes[i]    = p.getFloat(k1.c_str(), flatRes[i]);
    bendRes[i]    = p.getFloat(k2.c_str(), bendRes[i]);
    flatAdc[i]    = (uint16_t)p.getUShort(k4.c_str(), 0);
    bendAdc[i]    = (uint16_t)p.getUShort(k5.c_str(), 0);
    spanCounts[i] = (uint16_t)p.getUShort(k6.c_str(), 0);
  }
  if (ok) {
    calId = p.getUInt("cal_id", 0);
    validMask = p.getUChar("valid", 0);
    weakMask = 0;
    for (int i = 0; i < 5; i++) if (spanCounts[i] < SPAN_MIN_COUNTS) weakMask |= (1 << i);
  }
  p.end();
  complete = ok;
  return ok;
}

void calibrationSave() {
  Preferences p;
  p.begin("talkhimik", false);
  calId++;                                   // new id on every calibration
  for (int i = 0; i < 5; i++) {
    String n = FLEX_NAMES[i];
    p.putFloat(("flat_" + n).c_str(), flatRes[i]);
    p.putFloat(("bend_" + n).c_str(), bendRes[i]);
    p.putFloat(("rdiv_" + n).c_str(), R_DIV[i]);
    p.putUShort(("flata_" + n).c_str(), flatAdc[i]);
    p.putUShort(("benda_" + n).c_str(), bendAdc[i]);
    p.putUShort(("span_" + n).c_str(), spanCounts[i]);
  }
  p.putUInt("cal_id", calId);
  p.putUChar("valid", validMask);
  p.putUChar("pinmap", PIN_MAP_VERSION);
  p.end();
  complete = true;
  Serial.printf("[calib] profile saved to NVS (cal_id=%lu, valid mask 0x%02X)\n",
                (unsigned long)calId, validMask);
  calibrationSendInfo();
}

void calibrationStart() {
  active = true;
  finger = 0;
  step = 1;                    // thumb, waiting for FLAT
  invalidMask = 0;
  weakMask = 0;
  calError = ERR_NONE;
  Serial.printf("[calib] run started: thumb flat (R_DIV: %.1f %.1f %.1f %.1f %.1f)\n",
                R_DIV[0], R_DIV[1], R_DIV[2], R_DIV[3], R_DIV[4]);
}

bool calibrationCaptureFlat() {
  calError = ERR_NONE;
  if (!active || (step % 2) == 0) return false;
  flatAdc[finger] = flexReadAdc(finger, CALIBRATION_SAMPLES, 10000);
  flatRes[finger] = adcToResistance(finger, flatAdc[finger]);
  if (flatRes[finger] < RES_MIN_OHM || flatRes[finger] > RES_MAX_OHM) {
    invalidMask |= (1 << finger);
    calError = ERR_RESISTANCE_FAULT;
    Serial.printf("[calib] WARN: %s flat = %.0f ohms outside 1k..100k — sensor fault, finger excluded\n",
                  FLEX_NAMES[finger], flatRes[finger]);
  }
  step++;                      // same finger, waiting for 90
  Serial.printf("[calib] %s flat = %.0f ohms (adc %u)\n", FLEX_NAMES[finger],
                flatRes[finger], flatAdc[finger]);
  return true;
}

bool calibrationCapture90() {
  calError = ERR_NONE;
  if (!active || (step % 2) == 1) return false;
  bendAdc[finger] = flexReadAdc(finger, CALIBRATION_SAMPLES, 10000);
  bendRes[finger] = adcToResistance(finger, bendAdc[finger]);
  Serial.printf("[calib] %s 90 = %.0f ohms (adc %u)\n", FLEX_NAMES[finger],
                bendRes[finger], bendAdc[finger]);
  bool fault = (invalidMask & (1 << finger)) ||
               (bendRes[finger] < RES_MIN_OHM || bendRes[finger] > RES_MAX_OHM);
  if (bendRes[finger] < RES_MIN_OHM || bendRes[finger] > RES_MAX_OHM) {
    invalidMask |= (1 << finger);
    calError = ERR_RESISTANCE_FAULT;
    Serial.printf("[calib] WARN: %s 90 outside 1k..100k — sensor fault, finger excluded\n",
                  FLEX_NAMES[finger]);
  }
  if (!fault) {
    float dfrac = fabsf(bendRes[finger] - flatRes[finger]) / flatRes[finger];
    if (dfrac < SPAN_MIN_FRACTION) {
      calError = ERR_SPAN_TOO_SMALL;
      Serial.printf("[calib] REJECT: %s 90 within 5%% of flat — redo this capture\n",
                    FLEX_NAMES[finger]);
      return true;             // capture rejected: stay on this step
    }
  }
  spanCounts[finger] = (uint16_t)(bendAdc[finger] > flatAdc[finger]
                                  ? bendAdc[finger] - flatAdc[finger]
                                  : flatAdc[finger] - bendAdc[finger]);
  if (!fault && spanCounts[finger] < SPAN_MIN_COUNTS) {
    weakMask |= (1 << finger);
    Serial.printf("[calib] WARN: %s span %u counts < %d — weak but accepted\n",
                  FLEX_NAMES[finger], spanCounts[finger], SPAN_MIN_COUNTS);
  }
  finger++;
  if (finger >= 5) {           // pinky's 90 was the last capture
    active = false;
    step = 0;
    validMask = (~invalidMask) & 0x1F;
    calibrationSave();
    Serial.println("[calib] run complete");
  } else {
    step++;
    Serial.printf("[calib] next: %s flat\n", FLEX_NAMES[finger]);
  }
  return true;
}

void calibrationCancel() {
  active = false;
  step = 0;
  calError = ERR_NONE;
  Serial.println("[calib] run cancelled");
}

bool calibrationIsActive()   { return active; }
uint8_t calibrationStep()    { return step; }
bool calibrationIsComplete() { return complete; }

uint8_t calibrationValidMask() { return validMask; }
uint8_t calibrationWeakMask()  { return weakMask; }
uint32_t calibrationId()       { return calId; }
uint8_t calibrationLastError() { return calError; }

void calibrationSendInfo() {
  uint8_t out[CAL_INFO_LEN] = {0};
  out[0] = validMask;
  out[1] = weakMask;
  out[2] = (uint8_t)(calId & 0xFF);
  out[3] = (uint8_t)((calId >> 8) & 0xFF);
  out[4] = (uint8_t)((calId >> 16) & 0xFF);
  out[5] = (uint8_t)((calId >> 24) & 0xFF);
  size_t o = 6;
  memcpy(&out[o], flatRes, sizeof(float) * 5);      o += 20;
  memcpy(&out[o], bendRes, sizeof(float) * 5);      o += 20;
  memcpy(&out[o], flatAdc, sizeof(uint16_t) * 5);   o += 10;
  memcpy(&out[o], bendAdc, sizeof(uint16_t) * 5);   o += 10;
  memcpy(&out[o], R_DIV, sizeof(float) * 5);        o += 20;
  memcpy(&out[o], spanCounts, sizeof(uint16_t) * 5); o += 10;
  size_t vlen = strlen(FW_VERSION);
  memcpy(&out[o], FW_VERSION, vlen < 8 ? vlen : 8);  // ASCII, zero-padded
  bleNotifyCalInfo(out, sizeof(out));
}

float mapResistanceToAngle(uint8_t finger, float r) {
  float d = bendRes[finger] - flatRes[finger];
  if (d > -1.0f && d < 1.0f) return 0.0f;   // degenerate profile
  float a = (r - flatRes[finger]) * 90.0f / d;
  if (a < 0.0f) a = 0.0f;
  if (a > 90.0f) a = 90.0f;
  return a;
}
