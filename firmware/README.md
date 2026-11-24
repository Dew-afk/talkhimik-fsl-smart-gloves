# TALKHIMIK — BLE Glove Telemetry (2 hands)

FSL smart-glove stage 2: two Seeed XIAO ESP32S3 gloves (one per hand, 5 flex
sensors + MPU-6050/6500 each) stream telemetry to a single-file HTML dashboard
over **BLE** (Web Bluetooth). No Wi-Fi anywhere. Earlier prototypes (MQTT, then
USB-serial) are superseded.

## Folder layout

```
firmware/
├── glove-left/               # Arduino sketch — flash on the LEFT glove
│   ├── hand.h                # HAND 0 + this glove's R_DIV (the only per-glove file)
│   ├── config.h              # ALL pins, UUIDs, packet layouts, timing
│   ├── glove-left.ino        # setup/loop, packet builders, command handling
│   ├── flex.h / .cpp         # ADC reads (divider -> resistance)
│   ├── imu.h / .cpp          # MPU-6050/6500: R_MOUNT, gyro bias, fused roll/pitch/yaw
│   ├── calibration.h/.cpp    # flat/90 state machine + NVS persistence
│   └── ble_link.h/.cpp       # NimBLE GATT server (TELEMETRY/COMMAND/STATUS)
├── glove-right/              # same files; hand.h says HAND 1 — flash on the RIGHT glove
├── check_same.py             # confirms left and right differ only in hand.h
├── web/
│   └── index.html            # dashboard — open in Chrome/Edge
└── README.md
```

> Each `.ino` matches its folder name (`glove-left/glove-left.ino`): the Arduino
> build system requires it.
>
> **Edit both folders.** Any change outside `hand.h` must be copied to the
> other glove; `python firmware/check_same.py` lists anything that differs.

## Libraries (Arduino Library Manager)

| Library | Author | Why |
|---|---|---|
| **NimBLE-Arduino** (2.x) | h2zero | BLE GATT server — the sketch uses the 2.x callback signatures |
| **MPU6050_light** | rfetick | IMU (handles WHO_AM_I 0x68 and 0x70) |

## Board settings (Tools menu)

| Setting | Value |
|---|---|
| Board | **XIAO_ESP32S3** (install the Seeed ESP32 board package) |
| PSRAM | OPI PSRAM |
| USB CDC On Boot | Disabled (Serial is debug-only; BLE is the data path) |
| Flash size / partition | board defaults |

## Wiring (per glove — XIAO label → GPIO)

| Signal | XIAO pin | GPIO | Notes |
|---|---|---|---|
| Flex thumb | D0 | GPIO1 | ADC1_CH0 — 3.3 V → sensor → pin → 10 kΩ → GND |
| Flex pointer | D1 | GPIO2 | ADC1_CH1 |
| Flex middle | D2 | GPIO3 | ADC1_CH2 — strapping pin: analog input only (see note below) |
| Flex ring | D3 | GPIO4 | ADC1_CH3 |
| Flex pinky | D4 | GPIO5 | ADC1_CH4 |
| IMU SDA | D8 | GPIO7 | MPU-6050/6500 |
| IMU SCL | D9 | GPIO8 | |
| Vibration motor | D10 | GPIO9 | PWM → 47 kΩ → NPN base, flyback diode across motor |
| Status LED | (onboard) | GPIO21 | blinks while advertising, solid when connected |
| Battery sense | — | disabled | XIAO VBAT divider is on ADC2, blocked while the BLE radio is on → STATUS battery = 0xFF |

All ADC2 pins are avoided (disabled while the BLE radio is on). **D2 (GPIO3) is
a strapping pin** — it is used as analog input only; if the board fails to boot
or enter flash mode with the sensor connected, move that finger to D10 (GPIO9)
by changing one line in `config.h` (reassign the motor if you do).
All divider resistors are **10 kΩ** — `R_DIV[]` in `config.h` holds 10000 per
channel (put measured values back there if parts are ever swapped).

## Flashing each hand

1. Left glove: open `firmware/glove-left/glove-left.ino`. Right glove: open
   `firmware/glove-right/glove-right.ino`. The hand is fixed by the folder
   (fw 1.3.1+): no setting to change, and a hand saved by older firmware is
   ignored.
2. Upload, open the Serial Monitor at 115200 to see the boot/debug log
   (`[ble] advertising as TALKHIMIK-L`, IMU present, calibration state).

## Running the dashboard

```bash
cd web
python -m http.server 8000
# open http://localhost:8000 in Chrome or Edge
```

Web Bluetooth needs **Chrome/Edge on desktop or Android** and a secure context
(https or localhost; iOS Safari is unsupported). Click *Connect Left/Right*,
pick the glove from the chooser — it lands in its own slot based on its name.
The dashboard auto-reconnects with backoff when a glove walks out of range.

## Packet formats (the contract — firmware `config.h` ↔ dashboard JS)

Both ends implement the same tables; edit them together or they will drift.

### TELEMETRY — notify, 29 bytes, little-endian, default every 50 ms

| Offset | Type | Field |
|---|---|---|
| 0 | u8 | hand (0 = left, 1 = right) |
| 1–2 | u16 | seq (wraps; dashboard detects loss from gaps) |
| 3–7 | u8 ×5 | flex angles 0–90° — order **thumb, pointer, middle, ring, pinky** |
| 8–9 | i16 | roll ×10 (degrees·10, −1800..1800, body frame) |
| 10–11 | i16 | pitch ×10 (−900..900) |
| 12–13 | i16 | yaw ×10 (−1800..1800, gyro-integrated, drifts) |
| 14–23 | u16 ×5 | raw 12-bit ADC, same finger order |
| 24–27 | u32 | calibration_id (0 = never calibrated) |
| 28 | u8 | quality (bit0..4 = finger valid, bit5 = weak span warning) |

> 29 bytes needs the negotiated MTU (the firmware requests 247 up front).

> **ML note: roll wraps at ±180°.** With the palm up, roll flips between
> +179.9 and −179.9. ML features must use `sin(roll)`/`cos(roll)` or the
> gravity vector (`gx = sin(pitch)`, `gy = cos(pitch)·sin(roll)`,
> `gz = cos(pitch)·cos(roll)`), never raw roll degrees.

### STATUS — notify, 9 bytes, every 250 ms (bytes 0–4 unchanged; 5–8 added in fw 1.3.0)

| Offset | Type | Field |
|---|---|---|
| 0 | u8 | mode (0 = streaming, 1 = calibrating) |
| 1 | u8 | calibration step (0 = idle; 1–10 = thumb-flat … pinky-90) |
| 2 | u8 | battery % (0xFF = unknown) |
| 3 | u8 | flags (bit0 = flex uncalibrated, bit1 = IMU mount uncalibrated (config.h default R_MOUNT), bit2 = gyro bias not calibrated) |
| 4 | u8 | error (0 = none, 1 = capture while not calibrating, 2 = unknown command, 3 = 90° within 5% of flat — redo, 4 = resistance outside 1k..100k — finger fault, 5 = no IMU, 6 = pose \|a\| off 9.81 by >15%, 7 = poses not perpendicular, 8 = POSE2 before POSE1, 9 = gyro moving during bias capture, 10 = gyro not responding) |
| 5–8 | u32 | mount_calibration_id (0 = default R_MOUNT; random non-zero after each mount calibration) |

### CAL_INFO — read + notify, 104 bytes, pushed after each calibration save

Full calibration table so the dashboard always knows which profile produced a
sample. Read on connect; notified when a calibration run completes.

| Offset | Type | Field |
|---|---|---|
| 0 | u8 | valid mask (bit0..4 = finger passed quality checks) |
| 1 | u8 | weak mask (bit0..4 = span < 100 counts, warning only) |
| 2–5 | u32 | calibration_id (bumps on every calibration; 0 = never calibrated) |
| 6–25 | float ×5 | flat_ohm (thumb..pinky) |
| 26–45 | float ×5 | bent90_ohm |
| 46–55 | u16 ×5 | flat_adc |
| 56–65 | u16 ×5 | bent90_adc |
| 66–85 | float ×5 | R_DIV (the values used for this profile) |
| 86–95 | u16 ×5 | span_counts = \|bent90_adc − flat_adc\| |
| 96–103 | u8 ×8 | firmware version (ASCII, zero-padded) |

### COMMAND — write / write-without-response: u8 opcode + optional payload

| Opcode | Name | Payload |
|---|---|---|
| 0x01 | START_CALIBRATION | — |
| 0x02 | CAPTURE_FLAT | — (samples the current finger flat) |
| 0x03 | CAPTURE_90 | — (samples 90°; auto-advances finger) |
| 0x04 | CANCEL_CALIBRATION | — |
| 0x05 | SET_RATE | u16 LE ms (clamped 20–1000) |
| 0x06 | ZERO_YAW | — |
| 0x07 | SET_HAND | u8 — fw 1.3.1: hand fixed by the build; the other hand → error 2 |
| 0x08 | VIBRATE | u16 LE ms |
| 0x09 | CAPTURE_MOUNT_POSE1 | — (back of hand up, fingers forward, level, still 2 s) |
| 0x0A | CAPTURE_MOUNT_POSE2 | — (fingers straight up, still 2 s; solves + saves R_MOUNT) |
| 0x0B | CALIBRATE_GYRO | — (glove at rest 2 s; also runs at boot) |

### Calibration protocol

```
START → step 1 (thumb, flat) → CAPTURE_FLAT → step 2 (thumb 90°) → CAPTURE_90
     → step 3 (pointer, flat) → … → step 10 (pinky 90°) → CAPTURE_90
     → saved to NVS → mode back to streaming, step 0
```

Quality checks during the run: a 90° capture within **5% of flat** is rejected
(STATUS error 3) — the wizard stays on that step for a redo. Fingers whose
flat/90° resistance lands outside **1k..100k ohm** are marked invalid (STATUS
error 4) and excluded from recordings; spans < 100 ADC counts are accepted with
a warning (weak mask bit). The profile stores flat/bent90 ohms + ADC, span
counts, R_DIV, and a calibration_id; changing `R_DIV[]` invalidates the profile
and forces recalibration.

### IMU mount calibration

The MPU-6050 is mounted upside down. Every reading goes through
`body = R_MOUNT · sensor` before bias removal, filtering and angle math.
**Body frame:** palm down, level, fingers forward → +X toward the fingertips,
+Z up out of the back of the hand, +Y = Z × X. In that pose roll = pitch = 0
and az = +9.81. Pitch is positive with the fingertips up. Roll is positive for
a right-hand rotation about +X.

- **Default:** `R_MOUNT_DEFAULT` in `config.h` (`MOUNT_FLIP_X` = ax, −ay, −az;
  `MOUNT_FLIP_Y` and `MOUNT_YAW_90` are listed as alternatives).
- **Two-pose calibration:** POSE1 averages 200 accel samples → u1 = body +Z.
  POSE2 does the same → u2 = body +X. Then Gram-Schmidt: X = u2 − (u2·Z)Z
  normalized, Z = u1, Y = Z × X. The capture is rejected if |u1·u2| > 0.2 or if
  |a| is more than 15% off 9.81. The POSE1 magnitude also sets one global accel
  scale (9.80665 / mean |a|). The firmware warns if it falls outside 0.9–1.1.
- **Storage:** NVS blob per hand (`mount_L` / `mount_R`) holds a version
  number, the matrix, the scale and the mount_calibration_id. The left and
  right gloves never share a matrix. The hand used is the boot-time setting.
- **Gyro bias:** measured at boot and on 0x0B. 2 s at rest, rejected if the
  std dev exceeds 0.5 °/s. It is subtracted after R_MOUNT.
- **Orientation:** a complementary filter (α = 0.98) on the gravity vector
  gives roll and pitch. Yaw integrates the gyro rate about vertical, so it
  drifts. ZERO_YAW re-baselines it. Roll is undefined at pitch ±90.
- **Recording:** a change in calibration_id or mount_calibration_id starts a
  new session file. Both ids are written to the sidecar JSON.

## GATT service

| Item | UUID |
|---|---|
| Service | `d84f9c2e-6b1a-4e57-9f3d-2a8c7e5b1f04` |
| TELEMETRY (read + notify) | `7a3e1b9c-2d4f-48a6-b7e2-5c9d0f8a3b61` |
| COMMAND (write + write-no-response) | `3f8d2a6b-9c4e-4d7f-a1e3-6b5c8d0e2f49` |
| STATUS (read + notify) | `c2b6e8d4-1a7f-4c3e-9d5b-0f2a6e8c4d73` |
| CAL_INFO (read + notify) | `a1f2c3d4-5e6f-4a7b-8c9d-0e1f2a3b4c5d` |

## Dashboard features

- Per-hand connection badge: state, freshness (ms since last packet),
  packet-loss % (from seq gaps), update rate (Hz), auto-reconnect with backoff
- Two animated hands (5 fingers each incl. thumb, left hand mirrored), per-finger
  angle bars, roll/pitch/yaw tiles, per-hand gesture classifier
- Calibration wizard driven by COMMAND/STATUS (thumb → pinky, flat then 90°)
- Classifier rules are an editable JSON config (thresholds per finger)
- Dataset recorder (calibration-aware sessions): samples every 200 ms (5 Hz)
  tied to the glove's calibration_id — one session per (hand, calibration_id);
  a calibration change mid-session closes the file and starts a new one. CSV
  columns `timestamp_ms, session_id, signer_id, hand, calibration_id, label,
  take_id, raw_/ohm_/ang_ per finger (thumb columns only when it passes the
  quality check), roll, pitch, yaw, quality_flag`, plus a per-session sidecar
  JSON (full calibration table, R_DIV, span_counts, firmware version). Frames
  with raw ADC 0/4095 on a valid finger or a seq gap > 3 are dropped and
  counted per session
- Signer ID input — anonymous, auto-generated when left blank
- **simulate** toggle generates fake packets for UI testing without hardware

## Assumptions

- Battery sensing disabled (ADC2 conflict) → STATUS battery 0xFF; hook in `config.h`.
- The hand is fixed by the flashed folder (`hand.h`); `SET_HAND` cannot change it.
- Yaw has no magnetometer reference — drifts; the dashboard can send `ZERO_YAW`.
- Exactly one central per glove (advertising stops on connect, restarts on disconnect).
- Gesture classes merge letters that differ only in thumb abduction/motion
  (U·H·K·P·R, D·G·L) and leave dynamic letters (J, Z) to the future IMU-aware model.
- The saved calibration profile is invalidated (recalibration required) when
  `R_DIV[]` or the pin map version changes, or when old profiles lack the
  cal_id/ADC keys.
- Fingers failing the resistance-range check are excluded from recordings via
  the valid mask (see the CAL_INFO table).
