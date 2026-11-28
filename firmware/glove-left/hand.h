#pragma once
// hand.h -- the ONLY file that differs between firmware/glove-left/ and
// firmware/glove-right/ (firmware/check_same.py enforces it). Edit everything
// else in BOTH folders.

// Left glove: advertises "TALKHIMIK-L", telemetry hand byte 0,
// mount calibration key "mount_L". Fixed by this build: COMMAND 0x07
// (SET_HAND) cannot change it.
// Flex pins (XIAO label -> GPIO). The left PCB is mirrored: thumb on D5,
// pinky on D0 (the reverse of the right glove). TELEMETRY order stays
// thumb..pinky either way.
#define PIN_FLEX_THUMB     6   // D5
#define PIN_FLEX_POINTER   5   // D4
#define PIN_FLEX_MIDDLE    4   // D3
#define PIN_FLEX_RING      2   // D1
#define PIN_FLEX_PINKY     1   // D0
// Bump when these pins change: the saved calibration stores it and is
// discarded (recalibrate) when it no longer matches. 4 = mirrored left map.
#define PIN_MAP_VERSION 4

#define HAND 0

// This glove's divider resistors -- the ONE place to edit them.
// Enter each resistor's multimeter-measured value (10k parts are typically
// 9.8-10.2k and the ohms math, boot log, and NVS calibration signature all
// use these numbers). Changing a value invalidates the saved calibration.
static const float R_DIV[5] = {10000.0f, 10000.0f, 10000.0f, 10000.0f, 10000.0f};
//                              thumb     pointer   middle    ring      pinky
