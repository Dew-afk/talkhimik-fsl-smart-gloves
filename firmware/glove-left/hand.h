#pragma once
// hand.h -- the ONLY file that differs between firmware/glove-left/ and
// firmware/glove-right/ (firmware/check_same.py enforces it). Edit everything
// else in BOTH folders.

// Left glove: advertises "TALKHIMIK-L", telemetry hand byte 0,
// mount calibration key "mount_L". Fixed by this build: COMMAND 0x07
// (SET_HAND) cannot change it.
#define HAND 0

// This glove's divider resistors -- the ONE place to edit them.
// Enter each resistor's multimeter-measured value (10k parts are typically
// 9.8-10.2k and the ohms math, boot log, and NVS calibration signature all
// use these numbers). Changing a value invalidates the saved calibration.
static const float R_DIV[5] = {10000.0f, 10000.0f, 10000.0f, 10000.0f, 10000.0f};
//                              thumb     pointer   middle    ring      pinky
