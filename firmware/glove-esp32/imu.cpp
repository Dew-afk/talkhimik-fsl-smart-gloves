#include "imu.h"
#include "config.h"
#include <Arduino.h>
#include <Wire.h>
#include <Preferences.h>
#include <MPU6050_light.h>
#include <math.h>

// MPU6050_light is used only for init + raw reads (getAcc* in g, getGyro* in
// deg/s). Its own angle filter is ignored: it runs in the SENSOR frame, before
// any mount correction. Library gyro/accel offsets stay 0 so reads are raw.
static MPU6050 mpu(Wire);
static bool present = false;
static uint8_t mountHand = 0;            // hand R_MOUNT was loaded for (boot-time setting)

static float R[3][3] = R_MOUNT_DEFAULT;  // body = R * sensor
static bool mountCal = false;
static uint32_t mountId = 0;
static float accScale = 1.0f;            // global accel factor from POSE1
static float gyroBias[3] = {0, 0, 0};    // body frame, deg/s
static bool gyroCal = false;

static float up[3] = {0, 0, 1};          // fused gravity direction ("up") in body frame
static float yaw = 0.0f;
static uint32_t lastUs = 0;

static float u1[3];                      // POSE1 unit vector (sensor frame) = body +Z
static float pose1Mag = 0.0f;            // POSE1 mean |a| (m/s^2, unscaled)
static bool havePose1 = false;

// NVS: one blob per hand ("mount_L" / "mount_R"). Mirror-image gloves never
// share a matrix.
struct MountBlob { uint16_t version; uint8_t hand; float r[9]; float scale; uint32_t id; };

// ------------------------------- small math --------------------------------
static float dot3(const float a[3], const float b[3]) { return a[0]*b[0] + a[1]*b[1] + a[2]*b[2]; }
static float norm3(const float a[3]) { return sqrtf(dot3(a, a)); }
static void cross3(const float a[3], const float b[3], float o[3]) {
  o[0] = a[1]*b[2] - a[2]*b[1]; o[1] = a[2]*b[0] - a[0]*b[2]; o[2] = a[0]*b[1] - a[1]*b[0];
}
static void rotate(const float m[3][3], const float in[3], float out[3]) {
  for (int i = 0; i < 3; i++) out[i] = m[i][0]*in[0] + m[i][1]*in[1] + m[i][2]*in[2];
}
static float wrap180(float d) {
  while (d > 180.0f) d -= 360.0f;
  while (d <= -180.0f) d += 360.0f;
  return d;
}

// ------------------------------- sensor reads -------------------------------
static uint8_t readReg(uint8_t reg) {
  Wire.beginTransmission(0x68);
  Wire.write(reg);
  if (Wire.endTransmission(false) != 0) return 0;
  Wire.requestFrom(0x68, 1);
  return Wire.available() ? (uint8_t)Wire.read() : 0;
}

// Raw sensor frame: accel m/s^2 (no scale), gyro deg/s (no bias).
static void readSensor(float a[3], float g[3]) {
  mpu.update();
  a[0] = mpu.getAccX() * GRAVITY_MS2; a[1] = mpu.getAccY() * GRAVITY_MS2; a[2] = mpu.getAccZ() * GRAVITY_MS2;
  g[0] = mpu.getGyroX(); g[1] = mpu.getGyroY(); g[2] = mpu.getGyroZ();
}

// Body frame: R_MOUNT first, then accel scale and gyro bias (bias is body-frame).
static void readBody(float a[3], float g[3]) {
  float as[3], gs[3];
  readSensor(as, gs);
  rotate(R, as, a);
  rotate(R, gs, g);
  for (int i = 0; i < 3; i++) { a[i] *= accScale; g[i] -= gyroBias[i]; }
}

// Blocking average of IMU_CAL_SAMPLES sensor-frame reads at 10 ms.
static void averageSensor(float accMean[3], float gyroMean[3], float gyroStd[3]) {
  float sa[3] = {0}, sg[3] = {0}, sgg[3] = {0}, a[3], g[3];
  for (int n = 0; n < IMU_CAL_SAMPLES; n++) {
    readSensor(a, g);
    for (int i = 0; i < 3; i++) { sa[i] += a[i]; sg[i] += g[i]; sgg[i] += g[i]*g[i]; }
    delay(10);
  }
  for (int i = 0; i < 3; i++) {
    accMean[i] = sa[i] / IMU_CAL_SAMPLES;
    gyroMean[i] = sg[i] / IMU_CAL_SAMPLES;
    float var = sgg[i] / IMU_CAL_SAMPLES - gyroMean[i]*gyroMean[i];
    gyroStd[i] = sqrtf(var > 0 ? var : 0);
  }
}

static void seedFilter() {               // start the filter at the measured gravity
  float a[3], g[3];
  readBody(a, g);
  float n = norm3(a);
  if (n > 1.0f) for (int i = 0; i < 3; i++) up[i] = a[i] / n;
  lastUs = micros();
}

static void printMount(const char* tag) {
  Serial.printf("[imu] R_MOUNT (%s, hand %c, mount_calibration_id=%lu):\n", tag,
                mountHand ? 'R' : 'L', (unsigned long)mountId);
  for (int i = 0; i < 3; i++)
    Serial.printf("[imu]   body %c = [% .3f % .3f % .3f]\n", "XYZ"[i], R[i][0], R[i][1], R[i][2]);
}

// ------------------------------- NVS ---------------------------------------
static const char* mountKey() { return mountHand ? "mount_R" : "mount_L"; }

static bool loadMount() {
  Preferences p;
  p.begin("talkhimik", true);
  MountBlob b;
  bool ok = p.isKey(mountKey()) && p.getBytesLength(mountKey()) == sizeof(b) &&
            p.getBytes(mountKey(), &b, sizeof(b)) == sizeof(b) &&
            b.version == MOUNT_NVS_VERSION && b.hand == mountHand;
  p.end();
  if (!ok) return false;
  memcpy(R, b.r, sizeof(R));
  accScale = b.scale;
  mountId = b.id;
  return true;
}

static void saveMount() {
  MountBlob b = {MOUNT_NVS_VERSION, mountHand, {}, accScale, mountId};
  memcpy(b.r, R, sizeof(R));
  Preferences p;
  p.begin("talkhimik", false);
  p.putBytes(mountKey(), &b, sizeof(b));
  p.end();
}

// ------------------------------- public ------------------------------------
void imuBegin(uint8_t hand) {
  mountHand = hand & 0x01;
  Wire.begin(IMU_SDA_PIN, IMU_SCL_PIN);   // D4/D5 are flex pins now — never the defaults

  Serial.print("[i2c] scan:");
  for (uint8_t a = 1; a < 127; a++) {
    Wire.beginTransmission(a);
    if (Wire.endTransmission() == 0) Serial.printf(" 0x%02X", a);
  }
  Serial.println();

  uint8_t who = readReg(0x75);            // WHO_AM_I
  present = (who == 0x68 || who == 0x70);
  Serial.printf("[imu] WHO_AM_I=0x%02X %s\n", who,
                present ? "(accepted: 0x68/0x70)" : "- check SDA(D8)/SCL(D9) wiring");
  if (!present) return;

  mpu.begin(IMU_GYRO_CONFIG, IMU_ACC_CONFIG);
  // The library picks its LSB factor from the config number; confirm the chip
  // actually holds that range so the m/s^2 conversion is right.
  uint8_t afs = (readReg(0x1C) >> 3) & 0x03, fs = (readReg(0x1B) >> 3) & 0x03;
  Serial.printf("[imu] accel range +/-%dg (reg AFS_SEL=%u, expect %d) %s; gyro +/-%d dps (FS_SEL=%u, expect %d) %s\n",
                2 << afs, afs, IMU_ACC_CONFIG, afs == IMU_ACC_CONFIG ? "OK" : "MISMATCH",
                250 << fs, fs, IMU_GYRO_CONFIG, fs == IMU_GYRO_CONFIG ? "OK" : "MISMATCH");

  mountCal = loadMount();
  if (!mountCal) Serial.println("[imu] no stored R_MOUNT for this hand - using config.h R_MOUNT_DEFAULT (mount uncalibrated)");
  printMount(mountCal ? "NVS" : "default");
  Serial.printf("[imu] accel scale = %.4f%s\n", accScale, mountCal ? "" : " (default, run pose calibration)");

  imuCalibrateGyro();                     // 2 s, glove must be still at boot
  seedFilter();

  // Self-check: assumes the glove is palm down and level at boot.
  float a[3], g[3], s[3] = {0};
  for (int n = 0; n < 50; n++) { readBody(a, g); for (int i = 0; i < 3; i++) s[i] += a[i] / 50; delay(2); }
  float m = norm3(s), tilt = m > 0 ? acosf(constrain(s[2] / m, -1.0f, 1.0f)) * RAD_TO_DEG : 180.0f;
  bool pass = tilt < 10.0f && fabsf(m - GRAVITY_MS2) < 0.05f * GRAVITY_MS2;
  Serial.printf("[imu] self-check (palm down, level): expected body g = (0.00, 0.00, +9.81)  actual = (%.2f, %.2f, %+.2f) |a|=%.2f tilt=%.1f deg -> %s\n",
                s[0], s[1], s[2], m, tilt, pass ? "PASS" : "CHECK (not level, or mount/scale uncalibrated)");
}

bool imuPresent() { return present; }

// Complementary filter on the gravity direction: gyro propagates the world
// "up" vector in the body frame (d(up)/dt = up x w), accel pulls it back.
// No Euler-angle state, so palm-up (roll +/-180) and pitch +/-90 cannot
// confuse the gyro integration. Yaw = gyro rate about world vertical.
void imuUpdate() {
  if (!present) return;
  uint32_t now = micros();
  float dt = (now - lastUs) * 1e-6f;
  lastUs = now;
  if (dt <= 0.0f || dt > 0.05f) dt = IMU_RATE_MS * 1e-3f;   // first tick / after a blocking capture

  float a[3], g[3], w[3], c[3];
  readBody(a, g);
  for (int i = 0; i < 3; i++) w[i] = g[i] * DEG_TO_RAD;
  cross3(up, w, c);
  for (int i = 0; i < 3; i++) up[i] += c[i] * dt;
  float an = norm3(a);
  if (an > 1.0f) for (int i = 0; i < 3; i++)
    up[i] = FILTER_ALPHA * up[i] + (1.0f - FILTER_ALPHA) * a[i] / an;
  float un = norm3(up);
  for (int i = 0; i < 3; i++) up[i] /= un;

  yaw = wrap180(yaw + dot3(g, up) * dt);
}

// atan2 keeps roll in -180..180 and pitch in -90..90 (pitch uses a
// non-negative denominator). Roll positive = right-hand rotation about +X.
float imuRollDeg()  { return present ? atan2f(up[1], up[2]) * RAD_TO_DEG : 0.0f; }
float imuPitchDeg() { return present ? atan2f(up[0], sqrtf(up[1]*up[1] + up[2]*up[2])) * RAD_TO_DEG : 0.0f; }
float imuYawDeg()   { return present ? yaw : 0.0f; }

void imuZeroYaw() {
  yaw = 0.0f;
  Serial.println("[imu] yaw zeroed");
}

uint8_t imuCalibrateGyro() {
  if (!present) return ERR_IMU_MISSING;
  float am[3], gm[3], gsd[3], b[3];
  averageSensor(am, gm, gsd);
  rotate(R, gm, b);                        // bias lives in the body frame (subtracted after R_MOUNT)
  float maxSd = fmaxf(gsd[0], fmaxf(gsd[1], gsd[2]));
  Serial.printf("[imu] gyro bias (body, deg/s) = (%.3f, %.3f, %.3f)  std = (%.3f, %.3f, %.3f)\n",
                b[0], b[1], b[2], gsd[0], gsd[1], gsd[2]);
  if (maxSd < 0.001f) {                    // real gyros always show some noise
    Serial.println("[imu] REJECT gyro bias: std dev ~0 on every axis - gyro not responding");
    return ERR_GYRO_STUCK;
  }
  if (maxSd > GYRO_STILL_STD) {
    Serial.printf("[imu] REJECT gyro bias: std %.3f > %.2f deg/s - glove moving, hold still and redo (0x0B)\n",
                  maxSd, GYRO_STILL_STD);
    return ERR_GYRO_MOVING;
  }
  memcpy(gyroBias, b, sizeof(b));
  gyroCal = true;
  Serial.println("[imu] gyro bias accepted");
  return ERR_NONE;
}

uint8_t imuCaptureMountPose1() {
  if (!present) return ERR_IMU_MISSING;
  float am[3], gm[3], gsd[3];
  averageSensor(am, gm, gsd);
  float m = norm3(am);
  Serial.printf("[mount] pose1 mean (sensor) = (%.2f, %.2f, %.2f) |a|=%.3f\n", am[0], am[1], am[2], m);
  if (fabsf(m - GRAVITY_MS2) > MOUNT_G_TOL * GRAVITY_MS2) {
    Serial.println("[mount] REJECT pose1: |a| off 9.81 by >15% - hold still and redo");
    havePose1 = false;
    return ERR_MOUNT_GRAVITY;
  }
  for (int i = 0; i < 3; i++) u1[i] = am[i] / m;
  pose1Mag = m;
  havePose1 = true;
  Serial.println("[mount] pose1 OK - now point fingers straight up and send POSE2");
  return ERR_NONE;
}

uint8_t imuCaptureMountPose2() {
  if (!present) return ERR_IMU_MISSING;
  if (!havePose1) return ERR_MOUNT_SEQUENCE;
  float am[3], gm[3], gsd[3];
  averageSensor(am, gm, gsd);
  float m = norm3(am);
  Serial.printf("[mount] pose2 mean (sensor) = (%.2f, %.2f, %.2f) |a|=%.3f\n", am[0], am[1], am[2], m);
  if (fabsf(m - GRAVITY_MS2) > MOUNT_G_TOL * GRAVITY_MS2) {
    Serial.println("[mount] REJECT pose2: |a| off 9.81 by >15% - hold still and redo");
    return ERR_MOUNT_GRAVITY;
  }
  float u2[3];
  for (int i = 0; i < 3; i++) u2[i] = am[i] / m;
  float d = dot3(u1, u2);
  if (fabsf(d) > MOUNT_DOT_MAX) {
    Serial.printf("[mount] REJECT pose2: |u1.u2| = %.2f > %.2f - fingers not straight up, redo pose2\n",
                  fabsf(d), MOUNT_DOT_MAX);
    return ERR_MOUNT_NOT_PERP;             // keep pose1, only pose2 needs a redo
  }

  // Gram-Schmidt: Z = u1, X = u2 minus its Z component, Y = Z x X.
  float X[3], Y[3], newR[3][3];
  for (int i = 0; i < 3; i++) X[i] = u2[i] - d * u1[i];
  float xn = norm3(X);
  for (int i = 0; i < 3; i++) X[i] /= xn;
  cross3(u1, X, Y);
  for (int i = 0; i < 3; i++) { newR[0][i] = X[i]; newR[1][i] = Y[i]; newR[2][i] = u1[i]; }

  // Re-express the existing body-frame gyro bias in the new body frame:
  // b_new = R_new * R_old^T * b_old (avoids a forced gyro recalibration).
  float bs[3], bn[3];
  for (int i = 0; i < 3; i++) bs[i] = R[0][i]*gyroBias[0] + R[1][i]*gyroBias[1] + R[2][i]*gyroBias[2];
  rotate(newR, bs, bn);
  memcpy(gyroBias, bn, sizeof(bn));

  memcpy(R, newR, sizeof(R));
  accScale = GRAVITY_MS2 / pose1Mag;
  do { mountId = esp_random(); } while (mountId == 0);   // random: unique across gloves/hands
  mountCal = true;
  havePose1 = false;
  saveMount();

  printMount("calibrated");
  Serial.printf("[mount] accel scale = %.4f (9.80665 / %.3f)%s\n", accScale, pose1Mag,
                (accScale < 0.9f || accScale > 1.1f) ? "  WARN: outside 0.9-1.1, check sensor/range" : "");
  float zb[3];                             // check: pose1 must map to body +Z
  rotate(R, u1, zb);
  Serial.printf("[mount] check: R*u1 = (%.3f, %.3f, %.3f), expect (0, 0, 1)\n", zb[0], zb[1], zb[2]);
  seedFilter();
  return ERR_NONE;
}

uint32_t imuMountCalId()   { return mountId; }
bool imuMountCalibrated()  { return mountCal; }
bool imuGyroCalibrated()   { return gyroCal; }
