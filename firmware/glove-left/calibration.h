// calibration.h — per-finger flat/90-degree calibration state machine + NVS.
#pragma once
#include <stdint.h>

// Resistance calibration tables (ohms) + the raw ADC readings behind them.
// Populated from NVS or the placeholders below when no profile exists yet.
extern float flatRes[5];        // flat_ohm
extern float bendRes[5];        // bent90_ohm
extern uint16_t flatAdc[5];     // raw ADC at flat
extern uint16_t bendAdc[5];     // raw ADC at 90 deg
extern uint16_t spanCounts[5];  // |bent90_adc - flat_adc| per finger

// Load the saved profile from NVS (per-finger-name keys flat_<name>/bend_<name>,
// flata_<name>/benda_<name>/span_<name>/rdiv_<name>, plus the cal_id/valid
// keys, so reordering FLEX_PINS never attaches a profile to the wrong sensor).
// Returns false when nothing usable was stored or when R_DIV changed since the
// profile was saved (then recalibration is required).
bool calibrationLoad();
void calibrationSave();         // quality-gates each finger, bumps cal_id, saves

// State machine driven by the dashboard's COMMAND writes:
//   START -> step 1 (thumb, waiting for FLAT)
//   CAPTURE_FLAT (odd step)  -> step++ (same finger, waiting for 90)
//   CAPTURE_90   (even step) -> quality checks; a 90 capture within 5% of
//                               flat is rejected (stay on step, redo). After
//                               pinky's 90 the profile is saved to NVS and
//                               mode returns to streaming. Order: thumb ->
//                               pointer -> middle -> ring -> pinky.
void calibrationStart();
bool calibrationCaptureFlat();   // false when called out of sequence
bool calibrationCapture90();     // false when called out of sequence
void calibrationCancel();        // discard the run, keep the previous profile

bool calibrationIsActive();
uint8_t calibrationStep();       // 0 = idle, 1..10 (1 = thumb flat, 10 = pinky 90)
bool calibrationIsComplete();    // a valid profile is loaded/saved

// Quality-gate results (thresholds in calibration.cpp):
uint8_t calibrationValidMask();  // bit0..4: finger passed the checks
uint8_t calibrationWeakMask();   // bit0..4: span < 100 counts (warning only)
uint32_t calibrationId();        // bumps on every saved calibration
uint8_t calibrationLastError();  // ERR_SPAN_TOO_SMALL / ERR_RESISTANCE_FAULT / 0

// Build the 104-byte CAL_INFO packet (layout in config.h) and push it over BLE.
void calibrationSendInfo();

// Linear map resistance -> 0..90 deg against the current profile.
// Works whether resistance rises or falls with bend.
float mapResistanceToAngle(uint8_t finger, float resistance);
