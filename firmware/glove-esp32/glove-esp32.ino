/*
 * TALKHIMIK — XIAO ESP32S3 BLE glove (one per hand)
 *
 * 5 flex sensors (thumb, pointer, middle, ring, pinky) on ADC1 + MPU-6050/6500
 * on I2C. Serves a NimBLE GATT server:
 *   - TELEMETRY: 29-byte binary notifications every 50 ms (configurable) —
 *                angles, raw ADC, calibration_id, per-finger quality mask
 *   - STATUS:    9-byte notifications (mode, calibration step, battery, flags,
 *                error, mount_calibration_id) — drives the dashboard's calibration wizard
 *   - CAL_INFO:  104-byte read/notify — the full calibration table
 *   - COMMAND:   write / write-without-response (calibration, rate, hand, ...)
 * Serial is used for debug logs only — the data path is BLE.
 *
 * NOTE: named glove-esp32.ino (not main.ino) because the Arduino build system
 * requires the .ino file name to match its folder name.
 */
#include <Arduino.h>
#include "config.h"
#include "flex.h"
#include "imu.h"
#include "calibration.h"
#include "ble_link.h"

static float flexAngles[5] = {0};          // 0..90 per finger
static uint16_t rawAdc[5] = {0};           // last averaged 12-bit ADC per finger
static uint16_t teleSeq = 0;               // wraps; dashboard detects gaps
static uint32_t teleRateMs = TELEMETRY_RATE_MS;
static uint8_t flexIdx = 0;                // round-robin channel index
static uint8_t lastError = ERR_NONE;
static uint32_t motorUntilMs = 0;          // VIBRATE end time (0 = off)

// ------------------------------- Packet builders ---------------------------
// Layouts are fixed in config.h and mirrored in web/index.html + README.

void sendTelemetry() {
  uint8_t pkt[TELEMETRY_LEN] = {0};
  pkt[0] = bleGetHand();                                  // u8 hand
  pkt[1] = teleSeq & 0xFF;                                // u16 seq LE
  pkt[2] = (teleSeq >> 8) & 0xFF;
  for (int i = 0; i < 5; i++) pkt[3 + i] = (uint8_t)flexAngles[i];   // u8 flex[5]
  int16_t r = (int16_t)constrain(imuRollDeg() * 10.0f, -32760.0f, 32760.0f);
  int16_t p = (int16_t)constrain(imuPitchDeg() * 10.0f, -32760.0f, 32760.0f);
  int16_t y = (int16_t)constrain(imuYawDeg() * 10.0f, -32760.0f, 32760.0f);
  memcpy(&pkt[8], &r, 2);                                 // i16 roll/pitch/yaw x10
  memcpy(&pkt[10], &p, 2);
  memcpy(&pkt[12], &y, 2);
  memcpy(&pkt[14], rawAdc, sizeof(rawAdc));               // u16 raw ADC[5]
  uint32_t cid = calibrationId();                         // u32 calibration_id
  pkt[24] = (uint8_t)(cid & 0xFF);
  pkt[25] = (uint8_t)((cid >> 8) & 0xFF);
  pkt[26] = (uint8_t)((cid >> 16) & 0xFF);
  pkt[27] = (uint8_t)((cid >> 24) & 0xFF);
  pkt[28] = calibrationValidMask() | (calibrationWeakMask() ? 0x20 : 0x00);  // quality
  teleSeq++;
  bleNotifyTelemetry(pkt, sizeof(pkt));
}

void sendStatus() {
  uint8_t pkt[STATUS_LEN];
  pkt[0] = calibrationIsActive() ? MODE_CALIBRATING : MODE_STREAMING;
  pkt[1] = calibrationStep();
  pkt[2] = batteryPct();
  pkt[3] = (calibrationIsComplete() ? 0 : STATUS_FLAG_UNCALIBRATED) |
           (imuMountCalibrated() ? 0 : STATUS_FLAG_MOUNT_UNCAL) |
           (imuGyroCalibrated() ? 0 : STATUS_FLAG_GYRO_UNCAL);
  pkt[4] = lastError;
  uint32_t mid = imuMountCalId();                         // u32 mount_calibration_id
  memcpy(&pkt[5], &mid, 4);                               // ESP32 is little-endian
  bleNotifyStatus(pkt, sizeof(pkt));
}

uint8_t batteryPct() {
#if PIN_BATTERY >= 0
  // XIAO VBAT divider ~1/2; map 3.3..4.2 V to 0..100 %. Approximation — and
  // note ADC2 is blocked while the BLE radio is on, so this is disabled by
  // default (PIN_BATTERY = -1 -> 0xFF unknown).
  int raw = analogRead(PIN_BATTERY);
  float v = raw * (3.3f / 4095.0f) * 2.0f;
  return (uint8_t)constrain((v - 3.3f) / (4.2f - 3.3f) * 100.0f, 0.0f, 100.0f);
#else
  return 0xFF;
#endif
}

// ------------------------------ Command handling ----------------------------
// Runs in loop() context only (commands are queued from the NimBLE task).

void applyCommand(const BleCommand& c) {
  uint8_t err = ERR_NONE;
  switch (c.opcode) {
    case CMD_START_CALIBRATION:
      calibrationStart();
      break;
    case CMD_CAPTURE_FLAT:
      if (!calibrationCaptureFlat()) err = ERR_NOT_CALIBRATING;
      else err = calibrationLastError();
      break;
    case CMD_CAPTURE_90:
      if (!calibrationCapture90()) err = ERR_NOT_CALIBRATING;
      else err = calibrationLastError();
      break;
    case CMD_CANCEL_CALIBRATION:
      calibrationCancel();
      break;
    case CMD_SET_RATE:
      if (c.len >= 2) {
        uint16_t ms = c.payload[0] | ((uint16_t)c.payload[1] << 8);
        teleRateMs = constrain((uint32_t)ms, (uint32_t)20, (uint32_t)1000);
        Serial.printf("[cmd] telemetry rate = %lu ms\n", (unsigned long)teleRateMs);
      }
      break;
    case CMD_ZERO_YAW:
      imuZeroYaw();
      break;
    case CMD_SET_HAND:
      if (c.len >= 1) bleSetHand(c.payload[0]);
      break;
    case CMD_VIBRATE:
      if (c.len >= 2) {
        uint16_t ms = c.payload[0] | ((uint16_t)c.payload[1] << 8);
        motorUntilMs = millis() + ms;
      }
      break;
    case CMD_CAPTURE_MOUNT_POSE1:   // each blocks ~2 s (telemetry pauses, like flex captures)
      err = imuCaptureMountPose1();
      break;
    case CMD_CAPTURE_MOUNT_POSE2:
      err = imuCaptureMountPose2();
      break;
    case CMD_CALIBRATE_GYRO:
      err = imuCalibrateGyro();
      break;
    default:
      err = ERR_UNKNOWN_CMD;
      break;
  }
  lastError = err;
}

// --------------------------- LED + motor (feedback) -------------------------
// LED blinks while advertising, solid while a central is connected. The motor
// pulses for the duration of the last VIBRATE command.

void ledUpdate(uint32_t now) {
  static bool on = false;
  static uint32_t lastToggle = 0;
  bool lit;
  if (bleConnected()) {
    lit = true;
  } else {
    if (now - lastToggle >= 300) { lastToggle = now; on = !on; }
    lit = on;
  }
  digitalWrite(PIN_LED, lit ? (LED_ACTIVE_LOW ? LOW : HIGH)
                            : (LED_ACTIVE_LOW ? HIGH : LOW));
}

void motorUpdate(uint32_t now) {
  analogWrite(PIN_MOTOR, (motorUntilMs && now < motorUntilMs) ? 180 : 0);
}

// --------------------------------- Setup -----------------------------------
void setup() {
  Serial.begin(115200);
  Serial.printf("[boot] pin map v%d: flex={D0:%d,D1:%d,D3:%d,D4:%d,D5:%d} imu_sda=D8:%d imu_scl=D9:%d motor=D10:%d\n",
                PIN_MAP_VERSION, FLEX_PINS[0], FLEX_PINS[1], FLEX_PINS[2],
                FLEX_PINS[3], FLEX_PINS[4], IMU_SDA_PIN, IMU_SCL_PIN, PIN_MOTOR);
  Serial.printf("[boot] R_DIV: thumb=%.1f pointer=%.1f middle=%.1f ring=%.1f pinky=%.1f\n",
                R_DIV[0], R_DIV[1], R_DIV[2], R_DIV[3], R_DIV[4]);
  pinMode(PIN_LED, OUTPUT);
  pinMode(PIN_MOTOR, OUTPUT);

  flexBegin();
  calibrationLoad();
  bleBegin();               // loads the NVS hand setting
  imuBegin(bleGetHand());   // per-hand R_MOUNT; gyro bias blocks ~2 s (keep the glove still)
  calibrationSendInfo();    // push the current profile so CAL_INFO reads are fresh

  Serial.printf("[boot] fw=%s hand=%d name=%s calibrated=%d cal_id=%lu mount_cal=%d mount_calibration_id=%lu\n",
                FW_VERSION, bleGetHand(), bleDeviceName().c_str(),
                (int)calibrationIsComplete(), (unsigned long)calibrationId(),
                (int)imuMountCalibrated(), (unsigned long)imuMountCalId());
}

// ---------------------------------- Loop ------------------------------------
// Fully millis()-scheduled — no delay() pacing anywhere:
//   * one flex channel per 10 ms tick (round-robin -> full 5-finger scan
//     every ~50 ms, each read ~6 ms so the IMU keeps its 100 Hz)
//   * IMU update every 10 ms (>= 100 Hz)
//   * TELEMETRY notify at teleRateMs, STATUS notify every 250 ms
void loop() {
  uint32_t now = millis();
  static uint32_t lastImuMs = 0, lastFlexMs = 0, lastTeleMs = 0, lastStatusMs = 0;

  BleCommand cmd;
  while (blePopCommand(cmd)) applyCommand(cmd);

  if (now - lastImuMs >= IMU_RATE_MS) {
    lastImuMs = now;
    imuUpdate();
  }

  if (now - lastFlexMs >= IMU_RATE_MS) {
    lastFlexMs = now;
    rawAdc[flexIdx] = flexReadAdc(flexIdx, FLEX_SAMPLES);
    flexAngles[flexIdx] = mapResistanceToAngle(flexIdx, adcToResistance(flexIdx, rawAdc[flexIdx]));
    flexIdx = (flexIdx + 1) % 5;
  }

  if (now - lastTeleMs >= teleRateMs) {
    lastTeleMs = now;
    sendTelemetry();
  }

  if (now - lastStatusMs >= STATUS_RATE_MS) {
    lastStatusMs = now;
    sendStatus();
  }

  ledUpdate(now);
  motorUpdate(now);
}
