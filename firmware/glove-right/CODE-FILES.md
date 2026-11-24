# glove firmware — file map (glove-left / glove-right)

Board: **Seeed XIAO ESP32S3** (one per hand) · Build: **Arduino IDE**
Folders: `firmware/glove-left/` and `firmware/glove-right/` (identical except `hand.h`; run `python firmware/check_same.py`)
Last updated: 2026-11-08

## Current pin map (`config.h`, PIN_MAP_VERSION 3)

| Function       | XIAO label | GPIO |
|----------------|------------|------|
| thumb flex     | D0         | 1    |
| pointer flex   | D1         | 2    |
| middle flex    | D3         | 4    |
| ring flex      | D4         | 5    |
| pinky flex     | D5         | 6    |
| IMU SDA        | D8         | 7    |
| IMU SCL        | D9         | 8    |
| motor          | D10        | 9    |
| LED            | onboard    | 21   |

Flex divider: `3.3 V → sensor → ADC pin → 10 kΩ (R_DIV[5]) → GND`.
All flex pins sit on **ADC1** (ADC2 is blocked while the BLE radio is on).
I2C must use the explicit pins (`Wire.begin(IMU_SDA_PIN, IMU_SCL_PIN)`) — never the XIAO defaults.

## Files

### `glove-left.ino` / `glove-right.ino` — main sketch
Setup, loop, and the data path. Named after its folder (Arduino requires the `.ino` name to match its folder).
- **`setup()`** — Serial 115200, pin-map + R_DIV boot logs, `flexBegin()`, `imuBegin()`, `calibrationLoad()`, `bleBegin()`, pushes CAL_INFO, prints the boot line (`fw=… hand=… calibrated=… cal_id=…`).
- **Packet builders** — `sendTelemetry()` (29-byte binary notify), `sendStatus()` (5-byte), `batteryPct()` (disabled by default: `PIN_BATTERY = -1` → 0xFF unknown).
- **`applyCommand()`** — dispatches the 9 COMMAND opcodes (calibration wizard, rate, zero yaw, hand, vibrate).
- **Feedback** — `ledUpdate()` (blink advertising / solid connected), `motorUpdate()` (PWM during VIBRATE).
- **`loop()`** — fully `millis()`-scheduled, no `delay()`: one flex channel per 10 ms tick (round-robin → full 5-finger scan ≈ 50 ms), IMU update every 10 ms (100 Hz), TELEMETRY every 50 ms, STATUS every 250 ms.

### `config.h` — every pin, UUID, and constant in one place
- Pin defines + `FLEX_PINS[5]` (order everywhere: thumb, pointer, middle, ring, pinky), `FLEX_NAMES[5]`, hand.h holds `HAND` and this glove's `R_DIV[5]` (measure your actual divider resistors and edit there only).
- `PIN_MAP_VERSION` — bump when the pin map changes; invalidates the saved NVS calibration (recalibration required after flash).
- BLE device name, 4 UUIDs (must match `web/index.html`), `FW_VERSION`.
- Timing constants, COMMAND opcodes, STATUS/error codes, packet layouts + lengths (TELEMETRY 29 B, STATUS 5 B, CAL_INFO 104 B).

### `flex.h` / `flex.cpp` — flex sensor ADC reads
- 12-bit ADC, 11 dB attenuation (handles both ESP32 Arduino core 2.x and 3.x).
- `flexReadAdc()` — discards a settling read, then averages `samples` reads (the 10 kΩ divider has ~7–9 kΩ source impedance).
- `adcToResistance()` — `R_sensor = R_DIV * (4095 − adc) / adc`, with guards for floating/shorted pins.
- `flexReadResistance()` — one pass + conversion.

### `imu.h` / `imu.cpp` — MPU-6050/6500 on I2C (wrist orientation)
- `MPU6050_light` library; `Wire.begin(IMU_SDA_PIN, IMU_SCL_PIN)` → **D8/D9**.
- `imuBegin()` — logs a full I²C bus scan, reads WHO_AM_I (accepts 0x68/0x70), then ~1 s gyro-offset calibration.
- `imuUpdate()` every 10 ms; `imuRollDeg/PitchDeg/YawDeg()`.
- Yaw drifts (no magnetometer) — the dashboard's ZERO_YAW command re-baselines it via `imuZeroYaw()`.
- If `WHO_AM_I=0x00` or the scan list is empty: check SDA→D8, SCL→D9, VCC→3V3, GND, and pull-ups (XIAO adds none on D8/D9; GY-521 boards have them onboard).

### `calibration.h` / `calibration.cpp` — flat/90° calibration + NVS
- State machine steps 1–10 (thumb-flat → pinky-90), driven by dashboard COMMAND writes.
- Quality gates: flat/bent resistance inside 1 kΩ–100 kΩ, 90° capture must differ ≥ 5 % from flat (else reject/redo), span ≥ 100 counts (else "weak" warning).
- Persistence: NVS namespace `talkhimik`, keys per finger name (`flat_thumb`, `bend_pinky`, …) so reordering `FLEX_PINS` never attaches a profile to the wrong sensor. Saved profile carries `pinmap` version and per-finger R_DIV; either changing invalidates it.
- `mapResistanceToAngle()` — linear map to 0–90°, works whether resistance rises or falls with bend.
- `calibrationSendInfo()` — builds the 104-byte CAL_INFO packet.

### `ble_link.h` / `ble_link.cpp` — NimBLE GATT server
- Service + 4 characteristics: TELEMETRY (notify), STATUS (notify), CAL_INFO (read + notify), COMMAND (write).
- Requests MTU 247 (the 29-byte telemetry packet needs it).
- NimBLE callbacks run in another task; commands are pushed to a FreeRTOS queue and applied in `loop()` context via `blePopCommand()`.
- Advertising name `TALKHIMIK-L` / `TALKHIMIK-R`; hand fixed by `hand.h` (SET_HAND for the other hand returns error 2).

## Boot sequence

`Serial 115200` → pin-map + R_DIV log → `flexBegin()` → `imuBegin()` (I²C scan + WHO_AM_I + gyro offsets) → `calibrationLoad()` (NVS) → `bleBegin()` → CAL_INFO push → boot line.

## Change log

| Date       | Change |
|------------|--------|
| 2026-11-07 | Fingers moved D0,D1,D2,D3,D4 → **D0,D1,D3,D4,D5** (GPIO 1,2,3,4,5 → 1,2,4,5,6); `PIN_MAP_VERSION` 2→3 (recalibrate after flash). IMU stayed on D8/D9. |

## Dependencies (Arduino Library Manager)

- **NimBLE-Arduino 2.x** (h2zero)
- **MPU6050_light** (rfetick — handles WHO_AM_I 0x68 and 0x70, so 6050 and 6500 both work)
