// imu.h — MPU-6050/6500 on I2C (wrist orientation: roll / pitch / yaw).
// All outputs are in the BODY frame (see config.h): raw sensor readings are
// rotated by the per-hand R_MOUNT, then scaled / de-biased, then fused.
#pragma once
#include <stdint.h>

// Wire.begin on IMU_SDA_PIN/IMU_SCL_PIN, I2C scan, WHO_AM_I (0x68/0x70),
// range read-back, loads R_MOUNT for `hand` from NVS (falls back to
// R_MOUNT_DEFAULT), measures gyro bias (2 s still), prints a self-check.
// Call after bleBegin() so the NVS hand setting is known.
void imuBegin(uint8_t hand);
bool imuPresent();

// Call every IMU_RATE_MS (10 ms -> 100 Hz).
void imuUpdate();

// Degrees. Roll -180..180 (wraps — ML must use sin/cos or gravity), pitch
// -90..90, yaw -180..180 (gyro-integrated, drifts; ZERO_YAW re-baselines).
float imuRollDeg();
float imuPitchDeg();
float imuYawDeg();
void imuZeroYaw();

// Blocking 2 s captures; return ERR_NONE or a StatusError code (config.h).
uint8_t imuCaptureMountPose1();   // back of hand up, fingers forward
uint8_t imuCaptureMountPose2();   // fingers straight up -> solves + saves R_MOUNT
uint8_t imuCalibrateGyro();       // glove at rest

uint32_t imuMountCalId();         // 0 = config.h default in use
bool imuMountCalibrated();
bool imuGyroCalibrated();
