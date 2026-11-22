<!--
  TALKHIMIK — System Architecture & Implementation Document
  Derived from: the Talkhimik thesis (Chapters 1–2 + planned Chapters 3–4)
  Items the thesis does not specify are marked [PROPOSED] — confirm with the team
  before treating them as final.
-->

# TALKHIMIK — System Architecture & Implementation

> Describes the firmware 1.2.0 stage. For the current glove contract and app,
> use [TALKHIMIK.md](TALKHIMIK.md).

**"FSL Smart Glove Bridging Silent Gestures to Spoken Filipino Words"**

| | |
|---|---|
| **Team** | Daryl D. Bacusmo · Dewey Raven S. Cabahug · Sheena Patricia Kaye Caneja · Joppy B. Vargas |
| **Adviser** | Engr. Nikko D. Alferez |
| **Institution** | Cebu Institute of Technology University — College of Engineering and Architecture |
| **Derived from** | Talkhimik thesis — Chapters 1–2 + planned Chapters 3–4 |

---

## 1. Project Overview

Talkhimik is a wearable Filipino Sign Language (FSL) smart glove that translates silent hand gestures into spoken Filipino/English words in real time. Sensor data from the gloves is classified on-glove by a quantized TensorFlow Lite Micro neural network running on the ESP32-S3, and the recognized sign is delivered over Bluetooth Low Energy to an Android app that displays the text and speaks it through a text-to-speech engine.

**Key numbers**

- Vocabulary: complete 28-letter FSL manual alphabet + curated high-frequency phrases (educational & healthcare contexts)
- Sensing: 10 flex sensors (5 per glove) + 2 MPU-6050 IMUs (one per wrist); current prototype stage: 2 BLE gloves × 5 sensors + IMU (§4.7)
- Processing: ESP32-S3 on-glove: acquisition + TensorFlow Lite Micro inference (no external processor)
- Wireless: BLE 5.0 LE end to end — label packets to the app, telemetry to the Web Bluetooth dev dashboard (§4.7); no cloud dependency
- Output: Filipino/English text + synthesized speech, with a per-prediction confidence badge
- Budget: ₱ 7,640 (see §10.2)
- Legal alignment: Republic Act No. 11106 (Filipino Sign Language Act)

---

## 2. High-Level Architecture

Talkhimik is organized as a three-layer architecture — hardware (sensing + feedback), firmware (on-glove acquisition + TensorFlow Lite Micro inference), and software (companion app) — linked by one BLE link to the phone plus a Web Bluetooth telemetry link to the development dashboard.

```
┌──────────────────────────────────────────────────────────┐
│  SOFTWARE LAYER — Android App (production) / Dashboard   │
│                                                          │
│  BLE GATT Client → Packet Validation → UI Display        │
│                                  (Filipino text +        │
│                                   confidence badge)      │
│  Text-to-Speech Engine → spoken Filipino / English       │
│  Session History Log → Session Summary & Export          │
│  Web dashboard (dev): Web Bluetooth → live hands + telemetry │
└──────────────────────────▲───────────────────────────────┘
                           │ BLE 5.0 LE: label + confidence
                           │ + timestamp (production)
                           │ BLE: telemetry + commands (dev)
┌──────────────────────────┴───────────────────────────────┐
│  FIRMWARE LAYER — ESP32-S3 on the glove                  │
│                                                          │
│  Boot Init → BLE Stack → Load Calibration (NVS flash)    │
│                                                          │
│  Polling Loop:                                           │
│   ADC + I²C Acquisition → Sliding Window Buffer          │
│      → TFLM Inference (INT8) → Label + Confidence        │
│   Confidence ≥ Threshold? ─yes→ Dispatch BLE Packet      │
│                          └no→ Discard & Re-poll          │
│                                                          │
│  Feedback Control: LED indicators + vibration motor      │
└──────────────────────────▲───────────────────────────────┘
                           │ analog + I²C (on-board)
┌──────────────────────────┴───────────────────────────────┐
│  HARDWARE LAYER — Talkhimik Smart Glove (×2 hands)       │
│                                                          │
│  5× Flex Sensors (finger bends) → 12-bit SAR ADC         │
│  MPU-6050 IMU (wrist orientation/motion) → I²C           │
│                                                          │
│  Power: LiPo battery → onboard regulator                 │
│  Feedback: 2× LED indicators, 1× vibration motor         │
└──────────────────────────────────────────────────────────┘
```

**End-to-end pipeline**

```
Gesture Input → Sensor Acquisition → ML Classification → BLE Transmission → App Output → TTS Speech
```

---

## 3. Features

### 3.1 Core Features

| # | Feature | Description | Thesis ref |
|---|---------|-------------|------------|
| F1 | FSL gesture capture | 5 flex sensors per glove (one per finger) + wrist IMU capture handshape and motion | §2.1.1, §2.4 |
| F2 | Real-time classification | Quantized TensorFlow Lite Micro model classifies signs on the glove's own ESP32-S3 — no external PC, cloud, or Pi | §1.5.3–1.5.4, §2.1.2 |
| F3 | 28-letter FSL alphabet | Full Filipino Sign Language manual alphabet supported | §1.1, §1.4 |
| F4 | Phrase recognition | Curated high-frequency phrases for education and healthcare settings | §1.4 |
| F5 | Text output | Recognized gestures rendered as Filipino text with a confidence badge | §2.1.3 |
| F6 | Speech synthesis | Android TTS engine speaks the recognized sign in Filipino/English | §1.5.6, §2.1.3 |
| F7 | Wireless link | Single BLE hop: glove → Android app (label packets, production) · glove → web dashboard (telemetry, dev) | §2.1.4 |
| F8 | Per-user calibration | Calibration profile stores per-finger flat/90° ohms + raw ADC, span counts, R_DIV, validity mask, and a calibration_id (§5.2) | §1.7, §2.1.2 |
| F9 | Confidence gating | Predictions below the confidence threshold are reported as "unrecognized" instead of wrong output | §1.7, §2.1.2 |
| F10 | Session history | Every translation is logged locally; sessions end with a summary and log export | §2.1.3 |
| F11 | Portable power | LiPo battery makes the system wearable and untethered | §2.1.1 |
| F12 | Edge privacy | All processing stays on local devices — no cloud round-trip, no third party in the conversation | §1.3, §1.5.4 |

### 3.2 User Feedback Signals

| Signal | Meaning |
|--------|---------|
| LED indicators | Current: blinks while advertising, solid while connected (§4.7). Planned meanings: recognition success, calibration mode, low battery |
| Vibration motor | Current: fires on the VIBRATE command only (§4.7). Planned: tactile confirmation of recognized gesture |
| Confidence badge (app) | Shows how sure the model was of each prediction |
| Error toast (app) | Invalid/corrupted BLE packet received |
| "Unrecognized" output | Gesture below confidence threshold — signals re-sign |

### 3.3 Explicitly Out of Scope

- Non-Manual Signals (facial expressions, head movement, body posture)
- Vocabulary beyond the FSL alphabet + selected phrase set
- Continuous/rapid stylized signing (limited training data)
- iOS or cross-platform app (Android only)
- Offline buffering during BLE disconnects

---

## 4. Hardware Architecture

### 4.1 Component Inventory

| Component | Qty | Role |
|-----------|-----|------|
| Resistive flex sensors | 10 | Finger articulation — 5 per glove, one per finger |
| MPU-6050 IMU | 2 | 6-DOF wrist acceleration + rotation, one per wrist |
| ESP32-S3 (Seeed XIAO ESP32S3) | 2 | Glove MCU: 12-bit SAR ADC, I²C master, BLE 5.0 LE, on-glove TFLM inference |
| LiPo battery | 1 | Portable power source (onboard regulator) |
| Vibration motor | 1 | Haptic feedback |
| LED indicators | 2 | Visual status feedback |
| Wearable glove base | 1 | Sensor mounting platform |
| Jumper wires / connectors | 1 set | Interconnects |
| Resistors / passives | 1 set | Flex dividers 10 kΩ; motor base & LED current-limiting 47 kΩ |

### 4.2 Smart Glove Subsystem (per hand)

- **Flex sensors** are mounted along the fingers; bending changes sensor resistance, which the ESP32-S3 digitizes through its onboard **12-bit SAR ADC** (higher resolution than the 10-bit MCP3008 used in earlier iterations, which was superseded — thesis §1.5.2.3).
- Each flex sensor forms a **voltage divider** with a per-finger **10 kΩ** resistor (3.3 V → sensor → ADC pin → 10 kΩ → GND). At 10 kΩ the output swings ~0.47 V across the sensor's ~25–60 kΩ range (≈585 ADC counts at 12-bit), and the ~7–9 kΩ Thévenin source impedance stays within the ESP32 ADC's ~10 kΩ guideline. Trade-off vs. the ~39 kΩ swing optimum (√(R_flat × R_bent)): about a third less swing and ~5× more divider current. The firmware holds the per-channel 10 kΩ value in `R_DIV[]` (the uncalibrated placeholder profile is 30 kΩ flat / 60 kΩ bent).
- **MPU-6050 IMU** sits on the back of the hand/wrist, read over **I²C**, capturing orientation, tilt, and rotation — essential for distinguishing signs that share a handshape but differ in palm direction or movement.
- The **ESP32-S3** runs the **quantized TensorFlow Lite Micro model** on the same readings and transmits the **recognized label** over **BLE 5.0 LE** to the companion app.

### 4.3 On-Glove Inference Subsystem

- The same **ESP32-S3** that digitizes the sensors runs the **quantized TensorFlow Lite Micro model** — acquisition and classification happen on one chip, on the glove (§1.5.3.3, §1.5.4).
- **NVS flash** stores the per-user calibration profile (survives reboots and re-flashes); the `.tflite` model ships with the firmware and is updated by re-flashing.

### 4.4 Feedback Circuit

Per the circuit design (thesis §2.5):

- **LED indicators** → ESP32-S3 GPIO output pins via **47 kΩ current-limiting resistors**.
- **Vibration motor** → driven by an **NPN transistor switch**; a **PWM signal from an ESP32-S3 GPIO** controls the transistor base through a **47 kΩ base resistor**; the motor runs from the **3.3 V supply**; a **flyback diode across the motor terminals** suppresses inductive voltage spikes.

### 4.5 Power Subsystem

- A **LiPo battery** feeds the **ESP32-S3** through its onboard regulator.
- Continuous runtime is battery-limited; recharging interrupts operation (§1.4).

### 4.6 Interconnect Summary

| From | Interface | To |
|------|-----------|-----|
| Flex sensors (×10) | Analog resistance | ESP32-S3 onboard 12-bit ADC |
| MPU-6050 (×2) | I²C | ESP32-S3 |
| ESP32-S3 (×2) | BLE 5.0 LE | Android app (label packets) |
| ESP32-S3 GPIO | 47 kΩ resistor → LED | 2 LED indicators |
| ESP32-S3 GPIO (PWM) | 47 kΩ → NPN base → 3.3 V motor + flyback diode | Vibration motor |
| LiPo battery | Onboard regulator | ESP32-S3 |

### 4.7 Current Prototype Stage (as built) — BLE Gloves

The working prototype is now two **Seeed XIAO ESP32S3** gloves (`talkhimik-ble/`), one per hand, each with **5 flex sensors** (thumb, pointer, middle, ring, pinky) and an **MPU-6050/6500** IMU, streaming over **BLE** to the web dashboard (Web Bluetooth API). No Wi-Fi, no MQTT, no wires. Earlier stages (pointer + thumb over MQTT, then a 4-finger USB-serial glove) are superseded.

| Finger | XIAO pin | GPIO | ADC channel |
|--------|----------|------|-------------|
| Thumb | D0 | 1 | ADC1_CH0 |
| Pointer | D1 | 2 | ADC1_CH1 |
| Middle | D2 | 3 | ADC1_CH2 (strapping pin — analog only) |
| Ring | D3 | 4 | ADC1_CH3 |
| Pinky | D4 | 5 | ADC1_CH4 |

- All flex pins sit on **ADC1** (ADC2, GPIO11–20, is disabled while the radio is on; middle finger D2/GPIO3 is a strapping pin, used as analog input only — fallback D10/GPIO9 if boot/flash misbehaves). IMU on I²C: SDA D8 (GPIO7), SCL D9 (GPIO8) — the old D4/D5 I²C pins are now flex pins.
- Per-finger **10 kΩ** voltage divider (3.3 V → sensor → ADC pin → 10 kΩ → GND); `R_DIV[]` in `config.h` holds 10000 per channel.
- Firmware: flat / 90° calibration in thumb → pointer → middle → ring → pinky order, persisted in **NVS flash** under per-finger-name keys (ohms + raw ADC + span counts + R_DIV + calibration_id), then **NimBLE** GATT streaming (§4.7.1). Quality checks per finger: a 90° capture within 5% of flat is rejected and redone; flat/90° outside 1k..100k Ω marks the finger invalid (excluded from recordings, e.g. a wiring fault); span < 100 ADC counts warns but accepts. Changing `R_DIV[]` or the pin map version invalidates the saved profile and forces recalibration. Uncalibrated gloves stream placeholder-based angles flagged by a STATUS bit instead of failing.
- Web dashboard (single `web/index.html`, Web Bluetooth API, Chrome/Edge): two per-hand connect buttons, connection badges (freshness, packet-loss %, update rate), two animated hands, calibration wizard driven by COMMAND/STATUS, editable classifier rules, calibration-aware dataset recorder, simulate toggle.
- Feedback: onboard LED blinks while advertising / solid when connected; vibration motor on D10 (GPIO9) via PWM → 47 kΩ → NPN base.
- Battery sensing disabled (the XIAO's VBAT divider is on ADC2) → STATUS battery = 0xFF unknown.

#### 4.7.1 BLE GATT Service (per glove)

| Characteristic | UUID | Properties |
|---|---|---|
| Service | `d84f9c2e-6b1a-4e57-9f3d-2a8c7e5b1f04` | — |
| TELEMETRY | `7a3e1b9c-2d4f-48a6-b7e2-5c9d0f8a3b61` | read + notify |
| COMMAND | `3f8d2a6b-9c4e-4d7f-a1e3-6b5c8d0e2f49` | write + write-without-response |
| STATUS | `c2b6e8d4-1a7f-4c3e-9d5b-0f2a6e8c4d73` | read + notify |
| CAL_INFO | `a1f2c3d4-5e6f-4a7b-8c9d-0e1f2a3b4c5d` | read + notify |

- **TELEMETRY**: 29-byte little-endian packet every 50 ms (configurable): u8 hand, u16 seq (loss detection), u8 flex[5] 0–90°, i16 roll/pitch/yaw ×10, u16 raw ADC[5], u32 calibration_id, u8 quality byte (per-finger valid mask + weak-span bit). The full offset table lives in `talkhimik-ble/README.md` — the contract shared with the dashboard parser.
- **COMMAND** opcodes: START_CALIBRATION 0x01 · CAPTURE_FLAT 0x02 · CAPTURE_90 0x03 · CANCEL_CALIBRATION 0x04 · SET_RATE 0x05 · ZERO_YAW 0x06 · SET_HAND 0x07 · VIBRATE 0x08.
- **STATUS** (5 bytes): mode, calibration step, battery %, flags (bit0 = uncalibrated), error code (0x03 = 90° within 5% of flat — redo, 0x04 = resistance outside 1k..100k — finger fault) — pushed every 250 ms and drives the dashboard wizard.
- **CAL_INFO** (104 bytes, read + notify): the full calibration table — per-finger flat/bent90 ohms + ADC, span counts, R_DIV, calibration_id, valid/weak masks, firmware version — pushed after each calibration save so the dashboard always knows which profile produced a sample.
- Device name `TALKHIMIK-L` / `TALKHIMIK-R` from the build-time `HAND` constant (NVS-overridable via SET_HAND); advertising restarts automatically after disconnect; exactly one central per glove.

#### 4.7.2 Prototype Gesture Classifier

With all five finger angles per hand, the 28-letter FSL alphabet collapses into ten separable classes (threshold rules, 0–90° per finger, editable JSON in the dashboard):

| Class | Rule (thumb / pointer / middle / ring / pinky) | FSL letters |
|-------|-----------------------------------------------|-------------|
| FIST | 45 / 65 / 65 / 65 / 65 min | A · E · O · S · M · N · T · X |
| B | thumb ≥ 65, fingers < 25 | B |
| F | all < 45/25/25/25/25 | F |
| D-G-L | thumb ≥ 45, pointer < 25, rest ≥ 65 | D · G · L |
| V | thumb ≥ 65, pointer + middle < 25, rest ≥ 65 | V |
| U-K-P | thumb < 45, pointer + middle < 25, rest ≥ 65 | U · H · K · P · R |
| W | thumb < 65, pointer + middle + ring < 25, pinky ≥ 45 | W |
| I | thumb ≥ 65, pinky < 25, rest ≥ 65 | I |
| Y | thumb < 25, pinky < 25, rest ≥ 65 | Y |
| C | all in 25–65 | C |

Letters that differ only in thumb abduction or hand orientation (U·H·K·P·R, D·G·L) and dynamic letters (J, Z — need the IMU trajectory) still merge; the client-side classifier is temporary until the on-glove TFLM model (§8) replaces it.

---

## 5. Firmware Architecture

Firmware responsibilities live entirely on the glove's ESP32-S3 (§2.1.2).

### 5.1 ESP32-S3 Firmware (on-glove, single domain)

Responsibilities: acquire, normalize, infer, gate, dispatch, and provide feedback.

```
on_boot:
    init_adc_i2c()                        # 12-bit SAR ADC + I²C
    start_ble_stack()
    load_calibration_from_nvs()           # flat/90° ohms + ADC, spans, R_DIV, cal_id

loop:
    samples[0..4] = adc_read(flex_sensor[0..4])   # 12-bit SAR ADC
    imu_data      = i2c_read(mpu6050)             # accel + gyro
    window.append(normalize(samples, imu_data, profile))  # sliding window
    features = extract_features(window)           # time-series features
    label, confidence = tflm_model(features)      # quantized INT8 inference

    if confidence >= THRESHOLD:
        feedback(success)                 # LED + vibration
        ble_send(label, confidence, timestamp)    # → Android app
    else:
        discard()                         # avoid false outputs; re-poll
```

- Current stage: the working dev firmware reads **5 flex sensors per glove** on ADC1 and streams BLE GATT telemetry to the Web Bluetooth dashboard (§4.7); on-glove TFLM inference and BLE label dispatch to the Android app follow the Phase 3–4 plan (§10.1).
- The **Recognition Confidence Threshold** is a project-defined constant (§1.7); below it, the system reports "unrecognized".
- Toolchain: **C/C++ — Arduino or ESP-IDF**, with the TensorFlow Lite Micro runtime (§1.5.3.3).

### 5.2 Calibration Profiles

Per-user profiles generated during the calibration procedure store, per finger:

- **flat and 90° resistance baselines** in ohms plus the **raw ADC counts** behind them
- **span counts** (|bent90_adc − flat_adc|), the **R_DIV values** used at capture time, and a **validity mask**

Each saved calibration bumps a **calibration_id**, and quality checks run per finger (§4.7): a 90° capture within 5% of flat is rejected and redone, resistance outside 1 kΩ–100 kΩ marks the finger invalid (excluded from recordings), and spans under 100 ADC counts warn. The firmware derives a **linear resistance → angle map** from the two baselines — works whether resistance rises or falls with bend.

Purpose: compensate for sensor placement variation and flex-sensor drift between users and across sessions (§1.7, §2.7.4). The profile lives in **NVS flash** on the ESP32-S3 and survives reboots and re-flashes; changing `R_DIV[]` invalidates the saved profile and forces recalibration.

---

## 6. Software Architecture — Companion Android App

### 6.1 Application Flow

```
Launch → Scan & Pair (BLE) ──► Listening Loop ──► ... ──► End Session
                                   │
                 packet = ble_receive()
                        │
              valid(packet)? ──no──► error toast → continue
                        │yes
        ├─ UI: display Filipino text + confidence badge
        ├─ TTS: speak text (Filipino/English)
        └─ Log: append to local session history file

End Session → Session Summary → Export Logs → Safe BLE Unbind → Idle
```

### 6.2 Modules

| Module | Responsibility |
|--------|----------------|
| BLE GATT client | Scan, pair, connect, receive recognized-label notifications from the glove |
| Packet validator | Check packet structure; trigger error toast on invalid data |
| Translation view | Render Filipino text + confidence badge |
| TTS controller | Android Text-to-Speech engine, Filipino/English voices |
| Session logger | Local session history file per session |
| Session summary | End-of-session screen with compiled logs + export |
| Settings | Calibration interface, basic options |

- Language: **Kotlin or Java** *[PROPOSED — not specified in the thesis]*
- Uses Android BLE APIs and the Android Text-to-Speech engine.

---

## 7. Communication & Data Flow

### 7.1 Communication Links

| Link | Transport | Payload |
|------|-----------|---------|
| Glove (ESP32-S3) → Android app | BLE 5.0 LE (production) | Predicted label + confidence + timestamp |
| Glove (ESP32-S3) → web dashboard | BLE — Web Bluetooth (development, current) | Per-finger angles + raw ADC + IMU roll/pitch/yaw + calibration_id (§4.7.1); supersedes the thesis's MQTT/Wi-Fi dev channel (§4.7) |

### 7.2 Packet Schemas

**Telemetry frame — development link (current, binary BLE)**

The live development link is the binary GATT contract in §4.7.1 — the 29-byte little-endian TELEMETRY frame (u8 hand · u16 seq · u8 flex[5] angles · i16 roll/pitch/yaw ×10 · u16 raw ADC[5] · u32 calibration_id · u8 quality), the 5-byte STATUS frame, the 104-byte CAL_INFO table, and 1-byte-opcode COMMAND frames; the full offset tables live in `talkhimik-ble/README.md`. The earlier JSON-over-MQTT telemetry frame (Wi-Fi) is superseded (§4.7).

**Recognition packet — production link (BLE to the app)**

*[PROPOSED — the thesis defines packet contents but not exact formats; confirm with the team]*

```json
{
  "label": "KUMUSTA",
  "confidence": 0.94,
  "ts_ms": 1725460000123,
  "model": "lstm_v2"
}
```

### 7.3 Failure Modes

| Error mode | Definition (§1.7) |
|------------|-------------------|
| Misclassification | Correct packet, wrong label from the vocabulary set |
| Communication failure | BLE disconnect, power depletion, or hardware fault — no output reaches the app |

Known constraints: no offline buffering on disconnect; disconnection loses real-time translation (§1.4).

---

## 8. Machine Learning Pipeline

### 8.1 Dataset — Talkhimik Gesture Dataset (§1.7)

- Raw flex-sensor (ADC + ohm + angle) and IMU time-series recordings
- Every sample tied to the glove's calibration profile: `session_id`, `signer_id` (anonymous, never a name), `calibration_id`, `take_id`, `quality_flag`
- Per-session sidecar JSON: full calibration table, R_DIV values, per-finger span counts, sample rate, firmware version
- Frames with disconnected sensors (raw ADC 0/4095) or sequence gaps beyond the threshold are dropped and counted per session; files never mix calibrations
- Label annotations (letter / phrase)
- Used for training, validation, and cross-user testing

### 8.2 Preprocessing

- Per-user calibration normalization (linear resistance → angle map against the saved flat/90° baselines, §5.2)
- Sliding-window buffer over the digitized sensor stream
- Time-series feature extraction from the window

### 8.3 Model Architectures (§1.5.3.2)

| Task | Architecture | Notes |
|------|--------------|-------|
| Static handshapes (alphabet letters) | MLP / feedforward | Fixed feature vector, computationally light |
| Motion / phrase-level signs | 1D CNN and/or LSTM | Temporal patterns; LSTM preferred for phrase signing |

Related-work baselines for context: Austria et al. camera-ANN ≈ 87.5% (FSL subset) [13]; Mohandes et al. CyberGlove+HMM ≈ 96.5% [14]; Oz et al. glove+LSTM ≈ 93.51% (20 ASL words) [15].

### 8.4 Training → Deployment

```
PC (PyTorch)                        ESP32-S3 on the glove
  Train on labeled dataset   →      Convert PyTorch → ONNX → TensorFlow Lite
  Validate (train/test split)       Quantize to INT8 (a few hundred KB)
  Evaluate metrics                  Flash with firmware — on-glove TFLM inference
```

- Model size matters: the weights must fit the ESP32-S3's flash and RAM (§1.5.3.3); quantization costs ~1–2% accuracy, measured in §3.5.1.
- Cross-user generalization is a known challenge — mitigated by per-user calibration profiles and a dedicated cross-user validation phase (§1.6, §3.5.3).

### 8.5 Evaluation Metrics

Accuracy · Precision · Recall · F1-score · Confusion matrix (identifies commonly confused letters/phrases)

---

## 9. Technology Stack (Consolidated)

| Layer | Component | Technology |
|-------|-----------|------------|
| **Hardware** | Bend sensing | Resistive flex sensors (×10) |
| | Motion sensing | MPU-6050 6-DOF IMU (×2) |
| | Glove MCU | ESP32-S3 (Seeed XIAO ESP32S3) — 12-bit SAR ADC, I²C, BLE 5.0 LE |
| | Edge compute | ESP32-S3 (acquisition + inference, on-glove) |
| | Power | LiPo battery |
| | Feedback | LEDs (×2), vibration motor (×1) |
| **Firmware** | Firmware language | C/C++ — Arduino or ESP-IDF |
| | ML runtime | TensorFlow Lite Micro (quantized INT8) |
| | Wireless | BLE 5.0 LE (GATT server); dev dashboard over Web Bluetooth (MQTT superseded — §4.7) |
| | Storage | Per-user calibration profile in NVS flash |
| **Software** | Platform | Android |
| | Language | Kotlin or Java *[to confirm]* |
| | Wireless | Android BLE APIs (GATT client) |
| | Speech | Android Text-to-Speech engine (Filipino/English) |
| | Storage | Local session history log + export |
| **ML** | Framework | PyTorch (training) → ONNX → TensorFlow Lite (deployment) |
| | Models | MLP · 1D CNN · LSTM |
| | Features | Sliding-window time-series features |
| | Metrics | Accuracy, precision, recall, F1, confusion matrix |
| **Comms** | Production / Dev | BLE 5.0 LE both ways — label packets to the app, telemetry to the Web Bluetooth dashboard (§1.5.5, §4.7) |

---

## 10. Implementation Plan

### 10.1 Phases (from thesis Gantt charts, §2.3.2)

| Phase | Window | Tasks |
|-------|--------|-------|
| 3 — Hardware Development | Jun–Sep 2026 | Glove fabrication & sensor mounting · ESP32 firmware & BLE setup · Circuit integration & power management · Hardware prototype ready · Hardware unit testing |
| 4 — ML & Software *(parallel with Phase 3)* | Jun–Sep 2026 | FSL data collection & labeling · Model training · Companion app development · TTS integration · ML model deployed |
| 5 — Integration & Testing | Sep–Nov 2026 | System integration · User testing with FSL community · Calibration & accuracy evaluation · System evaluation complete |
| 6 — Final Documentation & Defense | Sep 2026–Jan 2027 | Chapter 3 (Results & Analysis) · Chapter 4 (Conclusion) · Full documentation & revisions · Final manuscript submission · Final defense (Nov 2026) |

### 10.2 Budget

| Material/Resource | Qty | Cost (₱) |
|-------------------|-----|----------|
| Flex sensors | 10 | 6,000 |
| MPU-6050 / MPU-9250 IMU | 2 | 300 |
| ESP32-S3 | 2 | 600 |
| LiPo battery | 1 | 250 |
| Vibration motor | 1 | 80 |
| LED indicators | 2 | 10 |
| Wearable glove base | 1 | 200 |
| Jumper wires / connectors | 1 set | 150 |
| Resistors / passive components | 1 set | 50 |
| **Total** | | **₱ 7,640** |

### 10.3 Proposed Repository Layout

*[PROPOSED — not specified in the thesis]*

```
talkhimik/
├── talkhimik-ble/          # current stage: BLE gloves + Web Bluetooth dashboard
│   ├── firmware/glove-esp32/  # XIAO ESP32S3: ADC + I²C + NimBLE GATT server
│   ├── web/index.html         # dashboard: telemetry, wizard, recorder
│   └── README.md              # wiring, packet formats, build steps
├── ml/
│   ├── data/               # Talkhimik Gesture Dataset (labeled, anonymized)
│   ├── train/              # PyTorch training & evaluation scripts
│   └── models/             # exported .pth → ONNX → .tflite (quantized)
├── app/                    # Android companion application (production BLE link)
└── docs/                   # test protocols, calibration guide, data sheets
```

---

## 11. Testing & Evaluation Strategy

| Test | Focus | Key outputs |
|------|-------|-------------|
| Unit (§2.7.1) | Sensors, BLE, app, TTS in isolation | Pass/fail per component |
| Integration (§2.7.2) | Sensor→TFLM→BLE→App→TTS cohesion | Packet loss, sync errors, delays |
| Functional (§2.7.3) | Requirements in Table 2.6 | Met / partially met / not met |
| Non-functional (§2.7.4) | Accuracy, latency, calibration stability, reliability, usability, battery | Accuracy %, ms latency, drift %, runtime hours |
| ML evaluation (§2.7.5) | Model quality on held-out data | Accuracy, precision, recall, F1, confusion matrix, cross-user |
| UAT (§2.7.6) | 5-point Likert: ease, comfort, responsiveness, accuracy, satisfaction | Mean scores per criterion |
| System (§2.7.7) | Full end-to-end pipeline in classroom/clinic simulations | Trial success rate |
| Stress (§2.7.8) | Prolonged operation, repeated signs, long BLE sessions | Overheating, degradation, stability |

Target metrics are recorded in Chapter 3 (Results & Analysis) once data gathering is complete.

---

## 12. Known Limitations & Risks

| Limitation (§1.4) | Risk | Mitigation / Status |
|-------------------|------|---------------------|
| No Non-Manual Signals | Simplified translations | Documented scope; future work (§13) |
| Fixed vocabulary | Signs outside set unrecognized | Curated alphabet + phrases for target settings |
| Flex-sensor drift / hysteresis, IMU bias | Accuracy decay over time | Per-user calibration profiles; recalibration interval from stability testing |
| Battery-limited runtime | Interruptions | LiPo + onboard regulator; battery test in §2.7.4 |
| BLE dependency, no offline buffering | Lost translation on disconnect | Documented error mode; future work (§13) |
| Android only | No iOS coverage | Future work (§13) |
| Small training population | Cross-user generalization | Cross-user validation phase + calibration (§3.5.3) |
| Rapid/continuous signing | Lower accuracy | Out of scope; LSTM architecture as future direction |
| INT8 quantization | ~1–2% accuracy cost vs. full precision | Accepted trade for on-glove inference; quantified in §3.5.1 |

---

## 13. Future Work / Roadmap

From the planned recommendations (§4.3):

1. Capture **Non-Manual Signals** (facial expression, head tracking) for fuller translations
2. **Expand vocabulary** and support continuous signing (LSTM/sequential decoding)
3. Grow the **training dataset** (more signers) for cross-user generalization
4. Upgrade **sensors** to reduce drift (calibration-free bend sensors, additional axes)
5. Add **offline buffering + automatic BLE reconnection**
6. **iOS / cross-platform** companion app
7. **Over-the-air (OTA) model updates** so the on-glove TFLite model can be retrained and redeployed without re-flashing firmware
8. **Deployment studies** in partner schools/hospitals with certified FSL interpreters

---

## Appendix — Mapping to the Thesis Document

| This document | Thesis section |
|---------------|----------------|
| §1 Overview | Abstract, §1.1–1.2 |
| §2 High-Level Architecture | §2.1 System Architecture, §2.2 Block Diagram |
| §3 Features | §2.1.3, §2.6.3, Fig 2.6.1–2.6.3 |
| §4 Hardware Architecture | §2.4 Prototype Design, §2.5 Circuit Design, §1.5.2 |
| §5 Firmware Architecture | §2.1.2, §2.6 (flowcharts), §1.5.4 |
| §6 Software Architecture | §2.1.3, Fig 2.6.3 |
| §7 Communication & Data Flow | §2.1.4, §1.5.5 |
| §8 Machine Learning Pipeline | §1.5.3, §2.7.5, §1.7 |
| §9 Technology Stack | §2.1.5 |
| §10 Implementation Plan | §2.3 Project Management |
| §11 Testing & Evaluation | §2.7 Testing and Data Gathering |
| §12 Limitations & Risks | §1.4 Scopes and Limitations |
| §13 Future Work | §4.3 Recommendations for Future Work |
