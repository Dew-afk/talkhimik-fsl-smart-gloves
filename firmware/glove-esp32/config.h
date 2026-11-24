// ============================================================================
// config.h — Talkhimik BLE glove: every pin, UUID, and constant in one place.
// Hardware: Seeed XIAO ESP32S3 (one per hand), 5 flex sensors + MPU-6050/6500.
// ============================================================================
#pragma once
#include <stdint.h>

// ---- Hand identity ---------------------------------------------------------
// 0 = left ("TALKHIMIK-L"), 1 = right ("TALKHIMIK-R"). This is the build-time
// default; the COMMAND 0x07 (SET_HAND) override is stored in NVS, wins at
// boot, and takes effect on the next reboot (the advertised name is set once
// at boot).
#define HAND_DEFAULT 0

// ---- Pin map (XIAO label -> GPIO) ------------------------------------------
// Flex dividers: 3.3 V -> sensor -> ADC pin -> 10 kOhm -> GND. All flex pins
// are ADC1 (usable while the BLE radio is on). The old D4/D5 I2C pins are now
// flex pins — the IMU moved to D8/D9, so always use Wire.begin(IMU_SDA_PIN,
// IMU_SCL_PIN), never the XIAO I2C defaults.
#define PIN_FLEX_THUMB     1   // D0
#define PIN_FLEX_POINTER   2   // D1
#define PIN_FLEX_MIDDLE    4   // D3
#define PIN_FLEX_RING      5   // D4
#define PIN_FLEX_PINKY     6   // D5
#define IMU_SDA_PIN        7   // D8
#define IMU_SCL_PIN        8   // D9
#define PIN_LED           21   // XIAO onboard LED (GPIO21)
#define PIN_MOTOR          9   // D10 — PWM -> 47 kOhm -> NPN base, flyback diode
                               // across the motor. Alternates: D6 (GPIO43), D7 (GPIO44).
                               // If the motor fails to start, check base drive current.
#define LED_ACTIVE_LOW     1   // XIAO onboard LED lights on LOW; set 0 if active-high

// Bump when the pin map changes — the saved NVS calibration stores this and is
// invalidated (recalibration required) when it no longer matches.
#define PIN_MAP_VERSION 3

// Battery: the XIAO's VBAT divider sits on ADC2, which is unusable while the
// BLE radio is on, so battery sensing is DISABLED by default (STATUS battery
// byte = 0xFF = unknown). Set this to an ADC pin only if you accept flaky
// reads; batteryPct() in the sketch implements the estimate.
#define PIN_BATTERY       -1

// ---- Flex channels ----------------------------------------------------------
// Order everywhere: thumb, pointer, middle, ring, pinky (calibration order and
// TELEMETRY packet order both follow this).
static const uint8_t FLEX_PINS[5] = {PIN_FLEX_THUMB, PIN_FLEX_POINTER,
                                     PIN_FLEX_MIDDLE, PIN_FLEX_RING, PIN_FLEX_PINKY};
static const char* FLEX_NAMES[5] = {"thumb", "pointer", "middle", "ring", "pinky"};
// Per-channel divider resistors — the ONE place to edit the divider value.
// Enter each resistor's multimeter-measured value (10k parts are typically
// 9.8-10.2k and the ohms math, boot log, and NVS calibration signature all
// use these numbers). Changing a value invalidates the saved calibration.
static const float R_DIV[5] = {10000.0f, 10000.0f, 10000.0f, 10000.0f, 10000.0f};
//                              thumb     pointer   middle    ring      pinky

// ---- BLE --------------------------------------------------------------------
#define DEVICE_NAME_PREFIX "TALKHIMIK"
// Random 128-bit UUIDs — MUST match web/index.html exactly (see README table).
#define SERVICE_UUID        "d84f9c2e-6b1a-4e57-9f3d-2a8c7e5b1f04"
#define TELEMETRY_CHAR_UUID "7a3e1b9c-2d4f-48a6-b7e2-5c9d0f8a3b61"
#define COMMAND_CHAR_UUID   "3f8d2a6b-9c4e-4d7f-a1e3-6b5c8d0e2f49"
#define STATUS_CHAR_UUID    "c2b6e8d4-1a7f-4c3e-9d5b-0f2a6e8c4d73"
#define CAL_INFO_CHAR_UUID  "a1f2c3d4-5e6f-4a7b-8c9d-0e1f2a3b4c5d"   // read + notify
#define FW_VERSION "1.3.0"        // sent in CAL_INFO + printed at boot

// ---- Timing ------------------------------------------------------------------
#define TELEMETRY_RATE_MS   50   // default notify period (SET_RATE 0x05 overrides)
#define STATUS_RATE_MS     250   // STATUS is pushed at this fixed rate
#define IMU_RATE_MS         10   // 100 Hz IMU updates
#define FLEX_SAMPLES         8   // oversampling for the telemetry path
#define CALIBRATION_SAMPLES 30   // oversampling for calibration captures

// ---- COMMAND opcodes (u8 opcode + optional payload) --------------------------
enum CmdOpcode : uint8_t {
  CMD_START_CALIBRATION  = 0x01,  // no payload
  CMD_CAPTURE_FLAT       = 0x02,  // no payload — samples current finger flat
  CMD_CAPTURE_90         = 0x03,  // no payload — samples current finger bent 90 deg
  CMD_CANCEL_CALIBRATION = 0x04,  // no payload
  CMD_SET_RATE           = 0x05,  // u16 LE milliseconds (clamped 20..1000)
  CMD_ZERO_YAW           = 0x06,  // no payload
  CMD_SET_HAND           = 0x07,  // u8 hand (0=L, 1=R) — saved to NVS
  CMD_VIBRATE            = 0x08,  // u16 LE milliseconds
  CMD_CAPTURE_MOUNT_POSE1 = 0x09, // no payload — back of hand up, fingers forward, still 2 s
  CMD_CAPTURE_MOUNT_POSE2 = 0x0A, // no payload — fingers straight up, still 2 s; solves + saves R_MOUNT
  CMD_CALIBRATE_GYRO     = 0x0B   // no payload — glove at rest 2 s; re-measures gyro bias
};

// ---- IMU mount (sensor -> body frame) -----------------------------------------
// Body frame (right-handed, all outputs): palm down, hand level, fingers
// forward -> +X = toward fingertips, +Z = up out of the back of the hand,
// +Y = Z x X. In that pose roll = pitch = 0 and accel reads +9.81 on body Z.
// body = R_MOUNT * sensor, applied to accel AND gyro right after each read.
// Rows = body X/Y/Z axes written in sensor coordinates (must be a proper
// rotation: orthonormal, det +1). The two-pose calibration (0x09/0x0A)
// replaces this per hand in NVS; the default below is only the fallback.
#define MOUNT_FLIP_X   {{ 1, 0, 0}, { 0,-1, 0}, { 0, 0,-1}}  // upside down, flipped about X: ax,-ay,-az
#define MOUNT_FLIP_Y   {{-1, 0, 0}, { 0, 1, 0}, { 0, 0,-1}}  // upside down, flipped about Y: -ax,ay,-az
#define MOUNT_YAW_90   {{ 0, 1, 0}, {-1, 0, 0}, { 0, 0, 1}}  // right side up, sensor +Y toward fingertips
#define MOUNT_IDENTITY {{ 1, 0, 0}, { 0, 1, 0}, { 0, 0, 1}}
#define R_MOUNT_DEFAULT MOUNT_FLIP_X   // <- the one line to change
#define MOUNT_NVS_VERSION 1            // bump if the stored mount blob layout changes

// MPU6050_light config numbers. The library derives its LSB->unit factor from
// the same number and imuBegin() reads the registers back to confirm.
#define IMU_GYRO_CONFIG 1    // 1 = +/-500 dps (65.5 LSB per dps)
#define IMU_ACC_CONFIG  0    // 0 = +/-2 g (16384 LSB per g)
#define GRAVITY_MS2     9.80665f
#define IMU_CAL_SAMPLES 200  // 200 x 10 ms = 2 s for mount poses and gyro bias
#define MOUNT_G_TOL     0.15f  // reject a pose if |a| is off 9.81 by more than 15%
#define MOUNT_DOT_MAX   0.20f  // reject if |u1 . u2| > this (poses not perpendicular)
#define GYRO_STILL_STD  0.5f   // deg/s per axis; above = glove moving, reject bias
#define FILTER_ALPHA    0.98f  // complementary filter gyro weight (100 Hz)

// ---- STATUS field values ------------------------------------------------------
enum StatusMode : uint8_t { MODE_STREAMING = 0, MODE_CALIBRATING = 1 };
#define STATUS_FLAG_UNCALIBRATED 0x01   // bit0 of the STATUS flags byte
#define STATUS_FLAG_MOUNT_UNCAL  0x02   // bit1: no stored R_MOUNT, config.h default in use
#define STATUS_FLAG_GYRO_UNCAL   0x04   // bit2: gyro bias not measured (boot capture rejected)
enum StatusError : uint8_t {
  ERR_NONE = 0,
  ERR_NOT_CALIBRATING = 1,   // CAPTURE_* received while not in calibration mode
  ERR_UNKNOWN_CMD = 2,       // unrecognized opcode
  ERR_SPAN_TOO_SMALL = 3,    // 90 deg within 5% of flat (reject, redo capture)
  ERR_RESISTANCE_FAULT = 4,  // flat/90 deg outside 1k..100k ohm (finger fault)
  ERR_IMU_MISSING = 5,       // IMU command but no MPU on the bus
  ERR_MOUNT_GRAVITY = 6,     // pose |a| off 9.81 by > 15% (moving or bad sensor) — redo
  ERR_MOUNT_NOT_PERP = 7,    // |u1 . u2| > 0.2 — poses not perpendicular, redo pose 2
  ERR_MOUNT_SEQUENCE = 8,    // POSE2 sent before a good POSE1
  ERR_GYRO_MOVING = 9,       // gyro std dev too high during bias capture — hold still, redo
  ERR_GYRO_STUCK = 10        // gyro std dev exactly ~0 — sensor not responding
};

// ---- TELEMETRY packet layout (little-endian, 29 bytes total) -----------------
// 0    u8  hand (0=L, 1=R)
// 1..2 u16 seq (wraps; dashboard detects gaps)
// 3..7 u8  flex angles 0-90, order thumb, pointer, middle, ring, pinky
// 8..9 i16 roll  x10 (degrees * 10, -1800..1800, body frame)
// 10..11 i16 pitch x10 (-900..900)
// 12..13 i16 yaw   x10 (-1800..1800, gyro-integrated, drifts; ZERO_YAW re-baselines)
//   ML NOTE: roll wraps at +/-180 (palm up flips between +179.9 and -179.9).
//   Features must use sin/cos(roll) or the gravity vector, never raw roll degrees.
// 14..23 u16 raw ADC[5] (12-bit, same finger order)
// 24..27 u32 calibration_id (0 = never calibrated)
// 28    u8  quality byte (bit0..4 = finger valid, bit5 = weak span warning)
#define TELEMETRY_LEN 29
// ---- STATUS packet layout (9 bytes; bytes 0..4 unchanged, 5..8 appended) -----
// 0 u8 mode (0 streaming, 1 calibrating)
// 1 u8 calibration step (0 idle; 1..10 = thumb-flat .. pinky-90)
// 2 u8 battery % (0xFF = unknown)
// 3 u8 flags (bit0 flex uncalibrated, bit1 mount uncalibrated, bit2 gyro bias uncalibrated)
// 4 u8 error code (see StatusError)
// 5..8 u32 mount_calibration_id (0 = config.h default R_MOUNT in use)
#define STATUS_LEN 9
// ---- CAL_INFO packet layout (little-endian, 104 bytes total) -----------------
// Full calibration table, so the dashboard always knows which profile produced
// a sample (sidecar JSON + per-finger validity masking).
// 0      u8  valid mask (bit0..4 = finger passed quality checks)
// 1      u8  weak mask (bit0..4 = span < 100 counts, warning only)
// 2..5   u32 calibration_id
// 6..25  float flat_ohm[5]    (4 bytes each, LE)
// 26..45 float bent90_ohm[5]
// 46..55 u16 flat_adc[5]
// 56..65 u16 bent90_adc[5]
// 66..85 float R_DIV[5]
// 86..95 u16 span_counts[5]
// 96..103 u8 fw_version[8]    (ASCII, zero-padded)
#define CAL_INFO_LEN 104
