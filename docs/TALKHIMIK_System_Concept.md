<!--
  TALKHIMIK — System Concept (stack-independent)
  The core ideas of the whole system, abstracted from the current ESP32/BLE/Web
  implementation, for porting or integrating into another tech stack.
  Details of the current build: TALKHIMIK_Code_Reference.md (code) and
  talkhimik-ble/README.md (contracts). Thesis-level rationale:
  TALKHIMIK_System_Architecture.md.
-->

# TALKHIMIK — System Concept

**What it is:** a wearable that turns Filipino Sign Language hand gestures into
text + speech. Sensors on two gloves measure finger bend and wrist motion; a
model classifies the gesture; the result is shown and spoken on a phone.

**The pipeline is always the same five stages, whatever the stack:**

```
Sense ──► Acquire ──► Calibrate ──► Classify ──► Output
flex + IMU   ADC/I2C     per-user      model      text + TTS
                         profile      (edge or
                                      host)
```

## 1. The concepts that matter (keep these in any port)

### C1 — Sensor → resistance → angle via a divider, calibrated per user

Each finger is a variable resistor in a voltage divider. You never trust raw
ADC: you convert to **ohms** with the divider formula
`R = R_DIV × (4095 − adc) / adc`, then map ohms → 0–90° **linearly between two
per-user anchor points** captured during calibration (finger flat, finger bent
90°):

```
angle = clamp( 90 × (R − R_flat) / (R_bent90 − R_flat), 0, 90 )
```

This one formula handles sensors whose resistance rises **or falls** with bend,
survives different sensor batches, and makes the recorded data portable across
users. The divider resistor value itself barely matters for accuracy because
the two-point calibration cancels scale errors — it matters for signal swing
and noise. (Current: 10 kΩ dividers, ESP32-S3 12-bit ADC, NVS-stored profile.)

### C2 — Calibration is versioned data, with quality gates

A calibration is not a "setting" — it is **data that downstream artifacts
depend on**. Every saved profile gets a monotonically increasing
`calibration_id`, and every recorded sample carries that id. Rules:

- a bend capture too close to flat (< 5%) → rejected, redo
- a finger reading outside plausible resistance (1k–100k Ω) → wiring fault →
  finger marked invalid and **excluded from recordings** (don't let one bad
  finger poison the dataset)
- too-small ADC swing (< 100 counts) → accepted with a warning flag
- changing the hardware constant (divider value) invalidates the profile →
  force recalibration

### C3 — Every sample is provably tied to the calibration that produced it

Dataset integrity rule: **never mix samples from different calibrations in one
file.** One session per (device, calibration_id); if the id changes
mid-session, close the file and start a new one. Each session exports:

- **CSV rows**: timestamp, session id, anonymous signer id, hand,
  calibration_id, label, take id, per-finger raw + ohm + angle, IMU angles,
  quality flag
- **sidecar JSON**: the full calibration table, divider values, per-finger
  quality metrics, sample rate, firmware version

And frames with disconnected sensors (raw 0/4095) or transport gaps are
dropped and **counted**, not silently kept. This is what makes the collected
data trainable and reproducible in any ML framework later.

### C4 — Separation of concerns across three layers

| Layer | Owns | Never does |
|---|---|---|
| **Sensing (hardware)** | flex sensors, IMU, feedback (LED/vibration), power | any logic |
| **Edge (MCU/firmware)** | acquisition, calibration state machine, angle mapping, classification (planned: quantized model on-device), transport | UI, storage beyond profile |
| **Host (app/dashboard)** | BLE client, visualization, calibration wizard UI, dataset recording, TTS, session history | raw sensor math beyond the documented formula |

The edge/host boundary is a **byte-level contract** (fixed little-endian
packets), not a shared library — either side can be replaced independently.

### C5 — Gated output: "unrecognized" beats wrong

Predictions below a confidence threshold are reported as *unrecognized*
instead of risking a wrong translation. The same idea applies to sensor faults
(C2): exclude, don't guess.

### C6 — Edge-first, no cloud dependency

Everything runs on the glove + the user's device. Data leaves only as the
user's exported files. This is both a privacy property and an architecture
decision: the pipeline must function with zero connectivity.

## 2. The transport contract (the only integration seam)

The current build uses **BLE GATT** with four channels per glove — this shape
maps to any bus (BLE, Wi-Fi, UART, WebSocket):

| Channel | Direction | Purpose | Equivalent in any stack |
|---|---|---|---|
| telemetry | device → host, periodic | angles + raw ADC + calibration_id + quality mask | sensor topic / stream |
| status | device → host, periodic | mode, calibration step, battery, flags, error | state topic |
| command | host → device, event | start/capture/cancel calibration, set rate, vibrate… | RPC / control topic |
| calibration info | device → host, on change | full calibration table + firmware version | config/manifest message |

Key transport rules worth keeping: packet = fixed binary layout + sequence
number (gap detection); the calibration table is **pushed on change** and
**readable anytime** so a reconnecting host always knows which profile
produced the samples it is about to receive.

## 3. What to change when you port (and what to keep)

| Concept | Current implementation | Portable idea |
|---|---|---|
| Edge MCU | Seeed XIAO ESP32-S3, Arduino, NimBLE | any MCU with ADC + I²C + a radio |
| Sensing | 5× resistive flex + MPU-6050 per glove | same sensors on any ADC; IMU interchangeable |
| Calibration store | NVS flash key/value | any persistent KV (EEPROM, file, cloud profile) |
| Transport | BLE GATT, binary LE packets | keep the 4-channel shape + seq numbers |
| Host | single-file JS dashboard (Web Bluetooth) | any app; keep wizard + recorder + sidecar logic |
| Classifier (current) | client-side threshold rules (10 classes) | replace with any model — the data format (C3) is what feeds it |
| Classifier (planned) | quantized TFLM on-glove | any edge runtime (ONNX Runtime, TFLite, CMSIS-NN) |
| Output | Android TTS (planned) | any TTS engine |

## 4. The minimum viable port, in order

1. Divider sensing + two-point calibration with quality gates (C1, C2) — the
   sensor truth.
2. The 4-channel transport contract with calibration_id in telemetry (C5 §2).
3. Calibration-aware dataset recorder with sidecar (C3) — you need data before
   any model.
4. Classifier + confidence gating (C5) — thresholds first, ML later.
5. Output (text + TTS) — last, it is pure host-side UI work.

## 5. Pointers

- `TALKHIMIK_Code_Reference.md` — the exact current implementation (constants,
  packet offsets, NVS keys, recorder schema)
- `talkhimik-ble/README.md` — wiring and the byte-level contract
- `TALKHIMIK_System_Architecture.md` — thesis-level rationale and future phases
