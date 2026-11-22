<!--
  TALKHIMIK — Code Reference (as built)
  Documents the actual, working code in talkhimik-ble/ — firmware + web dashboard.
  Companion documents:
    - TALKHIMIK_System_Architecture.md — thesis-level architecture (the "what & why")
    - talkhimik-ble/README.md              — wiring, build steps, packet quickstart
  Where the three disagree, this file describes the code.
-->

# TALKHIMIK — Code Reference (as built)

> Describes the firmware 1.2.0 stage. For the current glove contract and app,
> use [TALKHIMIK.md](TALKHIMIK.md).

**Current stage:** two Seeed XIAO ESP32S3 BLE gloves (5 flex sensors + MPU-6050/6500 each) streaming to a single-file Web Bluetooth dashboard. No Wi-Fi, no MQTT, no Android app, no on-glove TFLM yet — those are later phases (§10.1 of the architecture doc).

| | |
|---|---|
| **Firmware** | `talkhimik-ble/firmware/glove-esp32/` — Arduino sketch, C/C++ |
| **Dashboard** | `talkhimik-ble/web/index.html` — vanilla JS, Web Bluetooth (Chrome/Edge) |
| **Firmware version** | `FW_VERSION` in `config.h` — currently `1.2.0` |

---

## 1. Repository Layout

```
talkhimik-ble/
├── firmware/
│   └── glove-esp32/          # Arduino sketch — flash per hand
│       ├── config.h          # ALL pins, UUIDs, packet layouts, timing, enums
│       ├── glove-esp32.ino   # setup/loop, packet builders, command handling, LED/motor
│       ├── flex.h / .cpp     # ADC reads (divider -> ohms, adc<->ohms conversion)
│       ├── imu.h / .cpp      # MPU-6050/6500 (roll/pitch/yaw, yaw zeroing)
│       ├── calibration.h/.cpp# flat/90 state machine + quality checks + NVS + CAL_INFO
│       └── ble_link.h/.cpp   # NimBLE GATT server (TELEMETRY/STATUS/CAL_INFO/COMMAND)
├── web/
│   └── index.html            # dashboard — open in Chrome/Edge
└── README.md                 # wiring, packet contract, build steps
```

> The sketch is named `glove-esp32.ino` because the Arduino build system requires the `.ino` file to match its folder name.

---

## 2. Build & Flash

**Libraries** (Arduino Library Manager): **NimBLE-Arduino 2.x** (h2zero), **MPU6050_light** (rfetick — handles WHO_AM_I 0x68 and 0x70, so 6050 and 6500 both work).

**Board settings:** Board `XIAO_ESP32S3` (Seeed ESP32 package) · PSRAM **OPI PSRAM** · USB CDC On Boot **Disabled** · flash/partition = board defaults.

**Per-hand flashing:** set `HAND_DEFAULT 0` (left) or `1` (right) in `config.h` and flash — or flash both the same and send COMMAND `0x07 SET_HAND` once (saved to NVS, name updates on reboot).

**Serial** is debug-only at 115200. Expected boot log:

```
[boot] R_DIV: thumb=10000.0 pointer=10000.0 middle=10000.0 ring=10000.0 pinky=10000.0
[boot] fw=1.2.0 hand=0 name=TALKHIMIK-L calibrated=1 cal_id=3
```

---

## 3. Firmware Reference

### 3.1 `config.h` — the single source of truth

Every pin, UUID, packet layout, and constant lives here. Contracts mirrored in `web/index.html` and `README.md` — **edit them together or they drift**.

**Pin map (XIAO label → GPIO)**

| Signal | XIAO pin | GPIO | Notes |
|---|---|---|---|
| Flex thumb | D0 | 1 | ADC1_CH0 |
| Flex pointer | D1 | 2 | ADC1_CH1 |
| Flex middle | D2 | 3 | ADC1_CH2 — strapping pin, analog input only |
| Flex ring | D3 | 4 | ADC1_CH3 |
| Flex pinky | D4 | 5 | ADC1_CH4 |
| IMU SDA / SCL | D8 / D9 | 7 / 8 | I²C |
| Status LED | onboard | 21 | active-low on the XIAO (`LED_ACTIVE_LOW 1`) |
| Vibration motor | D10 | 9 | PWM → 47 kΩ → NPN base, flyback diode |
| Battery sense | — | disabled | XIAO VBAT divider is on ADC2 (blocked while radio on) → STATUS battery `0xFF` |

All flex pins sit on **ADC1** (ADC2 is unusable while the BLE radio is on); D2/GPIO3 (middle finger) is a strapping pin used as **analog input only** — if boot/flash misbehaves, move that finger to D10/GPIO9 by changing one line in `config.h`. The old D4/D5 I²C pins are now flex pins, so the IMU lives on D8/D9 and `Wire.begin` must always pass the explicit pins.

**Flex dividers** — 3.3 V → sensor → ADC pin → `R_DIV` → GND:

```c
static const float R_DIV[5] = {10000.0f, 10000.0f, 10000.0f, 10000.0f, 10000.0f};
```

`R_DIV[]` is the **one place** to edit the divider value (enter each resistor's multimeter-measured value). It feeds the ohms math, the boot log, and the NVS calibration signature — changing it invalidates the saved calibration.

**Timing**

| Constant | Value | Meaning |
|---|---|---|
| `TELEMETRY_RATE_MS` | 50 | TELEMETRY notify period (COMMAND 0x05 overrides, clamp 20–1000) |
| `STATUS_RATE_MS` | 250 | STATUS notify period (fixed) |
| `IMU_RATE_MS` | 10 | IMU update + one flex channel read per tick |
| `FLEX_SAMPLES` | 8 | ADC oversampling for the telemetry path |
| `CALIBRATION_SAMPLES` | 30 | ADC oversampling for calibration captures (10 ms spacing) |

**Enums** — COMMAND opcodes and STATUS field values are listed in §5.2 / §5.3.

### 3.2 `glove-esp32.ino` — boot, loop, packets, feedback

**Boot order** (`setup()`): Serial 115200 → print `R_DIV` → pin modes → `flexBegin()` → `imuBegin()` (gyro offset calc blocks ~1 s) → `calibrationLoad()` → `bleBegin()` → `calibrationSendInfo()` → boot summary line.

**Loop scheduler** — fully `millis()`-based, no `delay()`:

| Task | Cadence | What |
|---|---|---|
| `blePopCommand` + `applyCommand` | every loop | drain the NimBLE→FreeRTOS command queue |
| `imuUpdate()` | 10 ms | MPU update (≥100 Hz) |
| one flex channel | 10 ms (round-robin) | `flexReadAdc` → `adcToResistance` → `mapResistanceToAngle`; full 5-finger scan ≈ every 50 ms |
| `sendTelemetry()` | 50 ms (configurable) | 29-byte notify |
| `sendStatus()` | 250 ms | 5-byte notify |
| `ledUpdate()` / `motorUpdate()` | every loop | LED blinks while advertising, solid when connected; motor PWM 180/255 while `motorUntilMs` |

**Packet builders** — `sendTelemetry()` / `sendStatus()` serialize exactly the layouts in §5 (LE byte order, layouts commented in `config.h`).

**Command handling** (`applyCommand`) — runs in loop context only (commands arrive from the NimBLE task via an 8-slot FreeRTOS queue). CAPTURE_* map calibration errors: out-of-sequence → `ERR_NOT_CALIBRATING`, otherwise `calibrationLastError()` (span reject / resistance fault).

**Feedback** — `ledUpdate()` blinks every 300 ms while advertising, solid on connect (active-low aware). `motorUpdate()` drives `analogWrite(PIN_MOTOR, 180)` until the last VIBRATE duration expires.

### 3.3 `flex.h` / `flex.cpp` — ADC and ohms math

| Function | Behavior |
|---|---|
| `flexBegin()` | 12-bit resolution + 11 dB attenuation on all flex pins (core 2.x/3.x compatible) |
| `uint16_t flexReadAdc(finger, samples=8, sampleDelayUs=500)` | Discard settling read → 2 ms channel settle → average `samples` reads → 0..4095 |
| `float adcToResistance(finger, adc)` | `R = R_DIV[finger] * (4095 - adc) / adc`, guarded: adc ≤ 0 → huge R, adc ≥ 4095 → ~0 R |
| `float flexReadResistance(finger, ...)` | `adcToResistance(flexReadAdc(...))` — used by calibration captures |

Wiring fact baked into the formula: the **sensor is on the 3.3 V side, `R_DIV` to GND**, so `R_sensor = R_DIV × (4095 − adc) / adc`.

### 3.4 `imu.h` / `imu.cpp`

| Function | Behavior |
|---|---|
| `imuBegin()` | `MPU6050 mpu(Wire)` via MPU6050_light; `chip <= 2` ⇒ present (6050/9250/6500); `calcGyroOffsets()` ≈ 1 s at boot |
| `imuUpdate()` | `mpu.update()` at 100 Hz from the loop |
| `imuRollDeg/PitchDeg/YawDeg()` | filtered angles from MPU6050_light; yaw is gyro-only (drifts — no magnetometer) |
| `imuZeroYaw()` | stores the current yaw as offset (COMMAND 0x06) |

### 3.5 `calibration.h` / `calibration.cpp` — state machine, quality, NVS, CAL_INFO

**State machine** — driven by COMMAND writes from the dashboard wizard:

```
START → step 1 (thumb, waiting FLAT) → CAPTURE_FLAT → step 2 (thumb, waiting 90)
      → CAPTURE_90 → step 3 (pointer, FLAT) → … → step 10 (pinky 90)
      → CAPTURE_90 → quality-gate → save to NVS → mode streaming, step 0
```

- CAPTURE_* out of sequence returns `false` (→ `ERR_NOT_CALIBRATING`).
- Each capture stores **ohms** (`flatRes`/`bendRes`) **and raw ADC** (`flatAdc`/`bendAdc`).
- CANCEL discards the run and keeps the previous profile.

**Quality checks** (thresholds defined at the top of `calibration.cpp`):

| Check | Rule | Action |
|---|---|---|
| Resistance range | flat or 90° outside **1 kΩ–100 kΩ** | finger marked invalid (excluded from recordings), STATUS error 4 |
| 5% span | 90° within **5%** of flat | capture **rejected** — wizard stays on the step for a redo, STATUS error 3 |
| Span counts | `\|bent90_adc − flat_adc\|` < **100 counts** | accepted with a warning (weak mask bit) |

Faulted fingers never trip the 5% reject (they advance instead of looping forever). The angle map is linear and works whether resistance **rises or falls** with bend:

```c
a = clamp(90 * (R - flat) / (bent90 - flat), 0, 90)   // degenerate span → 0
```

**`calibrationSave()`** bumps `calId`, persists everything, and pushes CAL_INFO. **`calibrationLoad()`** returns false (⇒ uncalibrated, STATUS bit0, placeholder angles) when keys are missing **or** the stored `R_DIV` differs from the current `R_DIV` by > 1 Ω per channel **or** the stored `PIN_MAP_VERSION` differs — i.e. changing `R_DIV[]` or the pin map forces recalibration.

### 3.6 `ble_link.h` / `ble_link.cpp` — NimBLE GATT server

| Item | Behavior |
|---|---|
| `bleBegin()` | loads hand from NVS, `NimBLEDevice::init(name)`, MTU 247, creates the 4-characteristic service (§5.1), advertises name + service UUID |
| `GloveServerCallbacks` | on connect: stop advertising; on disconnect: restart (one central per glove, auto re-pair) |
| `GloveCmdCallbacks::onWrite` | copies opcode + payload into an 8-slot FreeRTOS queue (NimBLE 2.x signature) |
| `blePopCommand()` | drained by `loop()` |
| `bleNotifyTelemetry/Status(data, len)` | `notify(data, len)` while connected |
| `bleNotifyCalInfo(data, len)` | `setValue(data, len)` **always** (so READ works even while disconnected) + `notify()` when connected |
| `bleGetHand/bleSetHand` | hand byte; SET_HAND persists to NVS, name updates next reboot |

---

## 4. NVS Layout (Preferences namespace `"talkhimik"`)

| Key | Type | Meaning |
|---|---|---|
| `hand` | u8 | 0 = L, 1 = R (SET_HAND override; wins at boot) |
| `flat_<finger>` / `bend_<finger>` | float | flat / 90° resistance (ohms) |
| `flata_<finger>` / `benda_<finger>` | u16 | raw ADC at flat / 90° |
| `span_<finger>` | u16 | `\|bent90_adc − flat_adc\|` |
| `rdiv_<finger>` | float | `R_DIV` value used when the profile was captured (signature) |
| `cal_id` | u32 | calibration id — **bumps on every saved calibration** |
| `valid` | u8 | bitmask, bit0..4 = finger passed quality checks |
| `pinmap` | u8 | `PIN_MAP_VERSION` at capture time — mismatch invalidates the profile |

Per-finger keys use `FLEX_NAMES` (`thumb`, `pointer`, …), so reordering `FLEX_PINS` never attaches a profile to the wrong sensor. Profiles without `cal_id`/ADC keys (pre-1.2.0) are rejected → recalibration required.

---

## 5. BLE Contract (firmware `config.h` ↔ dashboard JS)

### 5.1 GATT service

| Characteristic | UUID | Properties |
|---|---|---|
| Service | `d84f9c2e-6b1a-4e57-9f3d-2a8c7e5b1f04` | — |
| TELEMETRY | `7a3e1b9c-2d4f-48a6-b7e2-5c9d0f8a3b61` | read + notify |
| COMMAND | `3f8d2a6b-9c4e-4d7f-a1e3-6b5c8d0e2f49` | write + write-without-response |
| STATUS | `c2b6e8d4-1a7f-4c3e-9d5b-0f2a6e8c4d73` | read + notify |
| CAL_INFO | `a1f2c3d4-5e6f-4a7b-8c9d-0e1f2a3b4c5d` | read + notify |

### 5.2 TELEMETRY — notify, 29 bytes, little-endian, every 50 ms

| Offset | Type | Field |
|---|---|---|
| 0 | u8 | hand (0 = left, 1 = right) |
| 1–2 | u16 | seq (wraps; dashboard detects gaps) |
| 3–7 | u8 ×5 | flex angles 0–90°, order thumb, pointer, middle, ring, pinky |
| 8–9 | i16 | roll ×10 |
| 10–11 | i16 | pitch ×10 |
| 12–13 | i16 | yaw ×10 |
| 14–23 | u16 ×5 | raw 12-bit ADC, same finger order |
| 24–27 | u32 | calibration_id (0 = never calibrated) |
| 28 | u8 | quality (bit0..4 = finger valid, bit5 = any weak span) |

> 29 bytes needs the negotiated MTU — the firmware requests 247 up front.

### 5.3 STATUS — notify, 5 bytes, every 250 ms

| Offset | Type | Field |
|---|---|---|
| 0 | u8 | mode (0 = streaming, 1 = calibrating) |
| 1 | u8 | calibration step (0 idle; 1–10 = thumb-flat … pinky-90) |
| 2 | u8 | battery % (0xFF = unknown) |
| 3 | u8 | flags (bit0 = uncalibrated, placeholder angles in use) |
| 4 | u8 | error: 0 none · 1 capture while not calibrating · 2 unknown command · 3 90° within 5% of flat (redo) · 4 resistance outside 1k..100k (finger fault) |

### 5.4 COMMAND — write / write-no-response: u8 opcode + optional payload

| Opcode | Name | Payload |
|---|---|---|
| 0x01 | START_CALIBRATION | — |
| 0x02 | CAPTURE_FLAT | — (samples current finger flat) |
| 0x03 | CAPTURE_90 | — (samples 90°; auto-advances) |
| 0x04 | CANCEL_CALIBRATION | — |
| 0x05 | SET_RATE | u16 LE ms (clamped 20–1000) |
| 0x06 | ZERO_YAW | — |
| 0x07 | SET_HAND | u8 (0 = L, 1 = R; NVS, name updates on reboot) |
| 0x08 | VIBRATE | u16 LE ms |

### 5.5 CAL_INFO — read + notify, 104 bytes

| Offset | Type | Field |
|---|---|---|
| 0 | u8 | valid mask (bit0..4 = finger passed quality checks) |
| 1 | u8 | weak mask (bit0..4 = span < 100 counts) |
| 2–5 | u32 | calibration_id |
| 6–25 | float ×5 | flat_ohm (thumb..pinky) |
| 26–45 | float ×5 | bent90_ohm |
| 46–55 | u16 ×5 | flat_adc |
| 56–65 | u16 ×5 | bent90_adc |
| 66–85 | float ×5 | R_DIV (values used for this profile) |
| 86–95 | u16 ×5 | span_counts |
| 96–103 | u8 ×8 | firmware version (ASCII, zero-padded) |

Pushed after every calibration save and stored for READ even while disconnected.

---

## 6. Dashboard (`web/index.html`) — module map

One self-contained file, no build step, no dependencies.

| Section | What it does |
|---|---|
| `CONFIG` / `PKT` | UUIDs + packet offsets — mirror of `config.h` (§5). `SEQ_GAP_MAX = 3` |
| `newHand()` / `HANDS` | per-hand state: BLE handles, angles, `raw[]`, `calId`, `validMask`, `quality`, parsed `cal` (CAL_INFO), `fwVersion`, `lastGap`, badge counters |
| `ingestTelemetry()` | parses the 29-byte frame; seq-gap loss accounting → `lastGap` |
| `ingestStatus()` / `parseCalInfo()` | 5-byte STATUS; 104-byte CAL_INFO into `hand.cal` |
| `connectGlove()` / `bindGlove()` / `scheduleReconnect()` | device chooser (`namePrefix` filter), characteristic lookup + subscriptions (telemetry/status/cal-info), CAL_INFO read on connect, auto-reconnect with exponential backoff (0.5 s..8 s, 5 attempts) |
| hand rendering | SVG hands (left mirrored), per-finger angle bars, roll/pitch/yaw tiles, zero-yaw button |
| gesture classifier | `DEFAULT_RULES` — 10 threshold classes (FIST, B, F, D-G-L, V, U-K-P, W, I, Y, C), editable JSON, majority vote over a 20-sample ring (≥10) |
| calibration wizard | radio per hand, START/CAPTURE/CANCEL driven by COMMAND + STATUS; error 3/4 messages from `wizExtra()` |
| dataset recorder | calibration-aware sessions (§7) |
| simulate toggle | `fakePacket()` (29-byte, incl. a demo loss burst every 7 s) + `fakeCalInfo()` + `fakeStatus()` |

---

## 7. Dataset Recorder Contract

**Engine** (`index.html`): samples every **200 ms (5 Hz)** per connected glove.

- **One session per (hand, calibration_id).** `ensureSession()` compares the telemetry `calId` to the active session — on a change it closes the session and starts a new one, so **files never mix calibrations**.
- **Frame drop rules** (counted per session, shown live, written to the sidecar):
  - raw ADC **0 or 4095** on any *valid* finger → dropped (`adcRail`)
  - seq gap **> 3** → dropped (`seqGap`)
- **Signer ID** — free-text but meant to be anonymous; auto-generated `anon-XXXX` when blank. Never a name.
- **Take** — each Start press increments `take_id` within the session (new session starts at 1).

**CSV columns** (per session export):

```
timestamp_ms, session_id, signer_id, hand, calibration_id, label, take_id,
raw_pointer, raw_middle, raw_ring, raw_pinky,
ohm_pointer, ohm_middle, ohm_ring, ohm_pinky,
ang_pointer, ang_middle, ang_ring, ang_pinky,
roll, pitch, yaw, quality_flag
```

`raw_thumb, ohm_thumb, ang_thumb` columns are inserted **only when the thumb passes the quality check** (valid mask bit0). `ohm`/`ang` are computed dashboard-side from raw ADC + the session's CAL_INFO (`R = R_DIV×(4095−adc)/adc`; `ang = clamp(90×(R−flat)/(bent90−flat), 0, 90)`). `quality_flag` = the telemetry quality byte.

**Sidecar JSON** (one per session, alongside the CSV):

```json
{
  "session_id": "S-...",
  "signer_id": "anon-XXXX",
  "hand": "L",
  "calibration_id": 3,
  "sample_rate_hz": 5,
  "firmware_version": "1.2.0",
  "recorded_at": "ISO-8601",
  "rows": 240,
  "dropped_frames": 2,
  "dropped": { "adcRail": 1, "seqGap": 1 },
  "r_div": [10000, ...],
  "fingers": {
    "thumb":    { "valid": false, "weak": false, "flat_ohm": ..., "bent90_ohm": ...,
                  "flat_adc": ..., "bent90_adc": ..., "span_counts": ... },
    "pointer":  { ... }, "middle": { ... }, "ring": { ... }, "pinky": { ... }
  }
}
```

**File names:** `talkhimik_<L|R>_<session_id>_cal<cal_id>.csv` / `..._sidecar.json`.

---

## 8. End-to-End Data Flow

```
flex sensors ──ADC1──► flexReadAdc (×8 avg) ──► adcToResistance ──► mapResistanceToAngle
MPU-6050 ────I2C────► imuUpdate (100 Hz) ──► roll/pitch/yaw
                                        │
        TELEMETRY 29 B (50 ms): angles + raw ADC + cal_id + quality
        STATUS      5 B (250 ms): mode/step/battery/flags/error
        CAL_INFO  104 B (on change): full calibration table
                                        │  BLE (NimBLE ↔ Web Bluetooth)
                                        ▼
        dashboard: visualizer · classifier · calibration wizard · dataset recorder
                                        │
                                        ▼
        CSV per (hand, calibration_id) session + sidecar JSON
```

---

## 9. Contract Consistency Checklist

When editing any of these, update all three together — they are the same tables:

| Contract | `config.h` | `web/index.html` | `README.md` |
|---|---|---|---|
| Pins / GPIO | §pin map | — | Wiring table |
| UUIDs | `*_UUID` defines | `CONFIG` | GATT service table |
| TELEMETRY offsets | layout comment | `PKT` | Packet formats |
| STATUS / CAL_INFO offsets | layout comments | `PKT` | Packet formats |
| COMMAND opcodes | `CmdOpcode` | `CMD` | Packet formats |
| Quality thresholds | `calibration.cpp` defines | — | Calibration protocol |

**Known deviations from the architecture doc:** none at the current stage — §4.7 of `TALKHIMIK_System_Architecture.md` describes exactly this build. Later stages (on-glove TFLM, Android app, ml/ scripts) exist only as plans (§8, §10.1 of that doc).
