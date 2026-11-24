<!--
  TALKHIMIK — single source of documentation (2026-10, post-merge).
  Absorbs: TALKHIMIK_App_System.md, TALKHIMIK_Master_Integration.md §2–§9,
  ble-integration-checklist.md, and the thesis reference (originals are
  kept by the team, outside this repo).
-->

# TALKHIMIK — FSL Smart Glove System

**"Bridging silent gestures to spoken Filipino words"**

| | |
|---|---|
| **Team** | Daryl D. Bacusmo · Dewey Raven S. Cabahug · Sheena Patricia Kaye Caneja · Joppy B. Vargas (Team Sagbotics) |
| **Adviser** | Engr. Nikko D. Alferez — CIT University |
| **App** | `talkhimik_app` (Flutter) · **Firmware** | `firmware/` fw 1.3.0 (ESP32-S3 ×2; 1.2.0 still supported) |
| **App version** | 0.1.0+1 · Dart `^3.13.2` |

**Current stage:** two Seeed XIAO ESP32S3 BLE gloves (5 flex sensors +
MPU-6050/6500 each) stream telemetry to the app over BLE; the app renders
two animated hands, drives the firmware calibration wizard, records
calibration-aware datasets (CSV + sidecar), and recognizes static letters
ON THE PHONE (§13) — threshold rules today, a trained MLP from
`assets/models/` when one ships (§15). On-glove TFLM label packets remain
the next firmware stage (planned).

### Tech stack

| Part | Stack |
|---|---|
| **App** | Flutter 3.47 (stable) · Dart `^3.13.2` · Material 3, Inter font · Android target (Windows/web = mock gloves only) |
| App packages (`pubspec.yaml`) | `flutter_riverpod` 3.4.3 (state) · `flutter_blue_plus` 2.3.12 (BLE) · `hive_ce` 2.19.3 (event log) · `shared_preferences` 2.5.5 (settings, CAL_INFO cache) · `flutter_tts` 4.2.5 (speech) · `permission_handler` 12.0.3 (pinned: 13.x needs compileSdk 37) · `path_provider` 2.1.5 · `share_plus` ^13.3.1 · `meta` |
| App tests | `flutter_test` · `flutter_lints` ^6.0.0 |
| **Glove hardware** | 2 × Seeed XIAO ESP32S3 · 5 flex sensors (voltage divider → 12-bit ADC) · MPU-6050/6500 IMU (I²C, mounted upside down) · vibration motor |
| **Firmware** (`firmware/`) | Arduino (C++), Seeed ESP32 board package, board XIAO_ESP32S3 · NimBLE-Arduino 2.x (GATT server) · MPU6050_light (IMU) · `Preferences` (NVS: calibration, hand, mount) |
| **Web dashboard** | Single-file HTML + JS (`firmware/web/index.html`), Web Bluetooth, Chrome/Edge, served with `python -m http.server` |
| **ML pipeline** (`ml/`) | Python · numpy ≥ 1.26 (loader, splits, MLP, exports) · TensorFlow ≥ 2.16 optional (only for `.tflite` export) · on the phone the model runs as a pure-Dart MLP (§13, §15) |

---

## 1. Glove contract (byte-exact, little-endian) — SINGLE COPY

| Item | Value |
|---|---|
| Device name | `TALKHIMIK-L` (hand 0) / `TALKHIMIK-R` (hand 1) — full-name scan match |
| Service | `d84f9c2e-6b1a-4e57-9f3d-2a8c7e5b1f04` |
| TELEMETRY (read+notify) | `7a3e1b9c-2d4f-48a6-b7e2-5c9d0f8a3b61` |
| COMMAND (write / write-no-resp) | `3f8d2a6b-9c4e-4d7f-a1e3-6b5c8d0e2f49` |
| STATUS (read+notify) | `c2b6e8d4-1a7f-4c3e-9d5b-0f2a6e8c4d73` |
| CAL_INFO (read+notify) | `a1f2c3d4-5e6f-4a7b-8c9d-0e1f2a3b4c5d` |

One central per glove. MTU 247. Finger order everywhere: **thumb, pointer,
middle, ring, pinky** (0–4).

### TELEMETRY — 29 bytes, every 50 ms (SET_RATE 20–1000)

| Off | Type | Field |
|---|---|---|
| 0 | u8 | hand (0 = L, 1 = R) |
| 1–2 | u16 | seq (wraps at 65536) |
| 3–7 | u8 ×5 | flex angle 0–90° |
| 8–9 / 10–11 / 12–13 | i16 ×3 | roll / pitch / yaw ×10 (degrees = value / 10; body frame) |
| 14–23 | u16 ×5 | raw 12-bit ADC |
| 24–27 | u32 | calibration_id (0 = never calibrated) |
| 28 | u8 | quality: bit0..4 = finger valid, bit5 = any weak span |

Reject frames ≠ 29 bytes.

fw 1.3.0 IMU (layout unchanged): every read goes through the mount matrix
`R_MOUNT` (default `MOUNT_FLIP_X`: ax, −ay, −az — the MPU is mounted upside
down), then accel scale + gyro bias, then a complementary filter (α 0.98) on
the gravity vector. Body frame: palm down, level, fingers forward → roll =
pitch = 0; pitch + = fingertips up. Roll/pitch are accel-referenced; yaw
integrates the gyro rate about vertical (drifts; ZERO_YAW re-baselines).
**Roll wraps at ±180°** and is undefined near pitch ±90° — ML features must
use sin/cos(roll) or the gravity vector, never raw roll degrees.

### STATUS — 9 bytes (fw 1.3.0) / 5 bytes (fw 1.2.0), every 250 ms

The app accepts ≥ 5 bytes; bytes 0–4 are identical in both versions, and
the mount id is read only when bytes 5–8 are present.

| Off | Type | Field |
|---|---|---|
| 0 | u8 | mode (0 streaming, 1 calibrating) |
| 1 | u8 | calibration step (0 idle; 1–10) |
| 2 | u8 | battery % (`0xFF` = unknown — the glove always sends this) |
| 3 | u8 | flags: bit0 = flex uncalibrated → placeholder angles · bit1 = IMU mount uncalibrated (config.h default R_MOUNT in use) · bit2 = gyro bias not calibrated (fw 1.3.0) |
| 4 | u8 | error: 0 none · 1 capture-not-calibrating · 2 unknown command · 3 90° within 5% of flat (redo) · 4 resistance outside 1k..100k (finger fault) · fw 1.3.0: 5 IMU missing · 6 mount pose \|a\| off 9.81 by > 15% (moving / bad sensor — redo) · 7 poses not perpendicular (\|u1·u2\| > 0.2 — redo pose 2) · 8 POSE2 before a good POSE1 · 9 gyro moving during bias capture (hold still, redo) · 10 gyro stuck (std dev ≈ 0 — sensor not responding) |
| 5–8 | u32 | mount_calibration_id (fw 1.3.0; 0 = default R_MOUNT, random non-zero once mount-calibrated) |

### CAL_INFO — 104 bytes, read on connect + notify on every save

| Off | Type | Field |
|---|---|---|
| 0 / 1 | u8 | valid mask / weak mask (bit0..4) |
| 2–5 | u32 | calibration_id |
| 6–25 | f32 ×5 | flat_ohm |
| 26–45 | f32 ×5 | bent90_ohm |
| 46–55 | u16 ×5 | flat_adc |
| 56–65 | u16 ×5 | bent90_adc |
| 66–85 | f32 ×5 | R_DIV (values used for this profile) |
| 86–95 | u16 ×5 | span_counts |
| 96–103 | u8 ×8 | firmware version, ASCII, zero-padded |

### COMMAND — u8 opcode + optional LE payload

| Op | Name | Payload |
|---|---|---|
| 0x01 | START_CALIBRATION | — |
| 0x02 | CAPTURE_FLAT | — |
| 0x03 | CAPTURE_90 | — |
| 0x04 | CANCEL_CALIBRATION | — |
| 0x05 | SET_RATE | u16 ms (clamped 20–1000) |
| 0x06 | ZERO_YAW | — |
| 0x07 | SET_HAND | u8 (0 L / 1 R; name updates on reboot) |
| 0x08 | VIBRATE | u16 ms |
| 0x09 | CAPTURE_MOUNT_POSE1 | — (fw 1.3.0; back of hand up, fingers forward, level, still 2 s) |
| 0x0A | CAPTURE_MOUNT_POSE2 | — (fw 1.3.0; fingers straight up, still 2 s; solves + saves R_MOUNT) |
| 0x0B | CALIBRATE_GYRO | — (fw 1.3.0; glove at rest 2 s; also runs at boot) |

0x09–0x0B each block the glove ~2 s (telemetry pauses). Mount calibration is
saved per hand in NVS (`mount_L` / `mount_R`) using the **boot-time** hand:
after SET_HAND, reboot the glove before mount calibration. A fw 1.2.0 glove
answers 0x09–0x0B with error 2.

### Production label packet (planned)

7 bytes: word_id u16 + confidence u8 + timestamp_ms u32 (SRS Table III-2).
`GesturePacketCodec` + test are in place; the mock drives the transcript
through it. The phone-side recognizer (§13) drives the transcript today
and PAUSES itself the moment a real label packet arrives (glove takes
precedence, both paths feed the same transcript events).
word_id ranges: 1–28 letters, 100+ built-in phrases; 1000+ is used only on the
phone, for words added on the Record screen (the firmware never sends it).

---

## 2. Sensor math

Wiring: 3.3 V → flex sensor → ADC pin → `R_DIV` → GND.

```
R_sensor = R_DIV × (4095 − adc) / adc        // adc ≤ 0 → huge; adc ≥ 4095 → ~0
angle    = clamp( 90 × (R − R_flat) / (R_bent90 − R_flat), 0, 90 )   // degenerate span → 0
seqGap(last, now) = (now − last − 1) & 0xFFFF                        // wrap-safe
```

`R_flat`/`R_bent90`/`R_DIV` always come from CAL_INFO. Telemetry angles are
for display; the dataset recomputes ohm/angle from raw + CAL_INFO so files
re-derive from raw + sidecar alone. Golden vectors are unit-tested.

---

## 3. Architecture

Layers: **ui → application → domain ← data**. Composition root:
`lib/application/providers.dart`.

```
lib/
├── main.dart                      # Hive init → settings → 2 glove connections → runApp
├── core/constants/gatt_ids.dart   # §1 contract + reconnect policy (1,2,4,8,30 s)
├── domain/
│   ├── sensing/sensor_math.dart   # §2
│   ├── models/                    # HandState, CalInfoPacket, TelemetryPacket, DatasetSession, …
│   ├── repositories/              # LogStore, VocabularyRepository, CloudSync
│   └── vocab/                     # 28 letters + phrases (word_id → fil/eng)
├── data/
│   ├── codec/                     # telemetry/status/CAL_INFO + planned label packet
│   ├── dataset/dataset_file_writer.dart
│   ├── glove/                     # GloveConnection (BLE/mock/factory/permissions)
│   ├── storage/                   # HiveLogStore, CalInfo cache, settings
│   └── tts/
├── application/                   # controllers: glove, live, calibration, recorder, …
└── ui/screens/                    # home, live, calibration, collect, export, settings
```

### Two-glove model

- One connection per hand. The keep-area primary (`gloveConnectionProvider`)
  is the **left** glove (transcript/demo path); `rightGloveConnectionProvider`
  + `rightGloveControllerProvider` serve the right glove.
- Scans are UNFILTERED and match the full advertised name
  (`TALKHIMIK-L` / `-R`); GATT discovery validates the service.
- A telemetry `hand` byte disagreeing with the glove name → data trusted,
  mismatch badge shown.
- Factory: BLE on Android/iOS only; mock everywhere else (and with the
  Settings "Force mock" flag). Mock auto-connects both hands on web/Windows.
- Reconnect per hand: backoff 1→2→4→8→30 s, "connection lost" banner ≤ 3 s,
  stateless glove re-runs the full flow (C-F7).

### Connection sequence (hardened, fix B2)

Strictly sequential, per glove, with awaits and timeouts:
`connect → clearGattCache if bonded (Android, before discovery — never
createBond; system pairing is neither required nor depended on) →
discoverServices → validate the 4 characteristics → requestMtu(247),
REQUIRE ≥ 32 (retry once, else surface "Glove data link too small") →
setNotifyValue TELEMETRY → STATUS → CAL_INFO (each awaited, retried once,
failures surfaced) → subscribe via onValueReceived → READ STATUS + CAL_INFO
→ balanced priority → ready.`

Every step, notify result, frame count, and decode rejection (by reason:
length / exception / hand) is recorded in the per-hand `BleDiagnostics`
object and rendered under **Settings → Developer → BLE diagnostics** — also
with mock values in demo mode. Verbose `flutter_blue_plus` logs are enabled
in debug builds.

### Feature map

| Code | Feature | Where |
|---|---|---|
| FR-1..7 | Transcript, TTS, bubbles, confidence, vocabulary, corrections, reply | transcript/tts controllers (keep areas) |
| FR-8 | Firmware-driven 10-step calibration wizard, glove-authoritative | `calibration_controller.dart`, `calinfo_cache.dart` |
| FR-9 | Dataset recorder — 5 Hz labeled streams, CSV + sidecar | `dataset_recorder_controller.dart`, `dataset_file_writer.dart` |
| FR-10 | Hive event log + sync queue (C-S4) | `hive_log_store.dart` (boxes: events, syncQueue, sessions) |
| FR-12 | Status bar (both gloves aggregate) | `device_status_bar.dart` |
| FR-13 | Anonymized participant id + consent (shared_preferences only) | `settings_controller.dart`, `settings_service.dart` |
| FR-15 | TTS/settings | tts/settings controllers |
| FR-16 | Event CSV export | `export_controller.dart` |
| NFR-1/7/8/9 | Latency ≤ 500 ms · terminology · consent gate · 3 s banner | transcript, strings, recorder, glove |

---

## 4. Live screen (`/live`)

Two hand panels (side-by-side wide, tabbed L/R on phones), driven by
`liveControllerProvider` (HandState per hand: latest packets, wrap-safe
seq-gap loss, trailing-second update rate, mismatch flag):

- **HandView** — CustomPainter, 3-segment fingers, mirrored left, yaw
  in-plane + roll/pitch skew, ticker low-pass (roll/yaw take the shortest arc across ±180°), invalid ✗ / uncalibrated
  desaturated / stale 40 % opacity
- Finger bars (0–90°, invalid dimmed, weak amber) · raw ADC + Ω details
  (collapsed expander; recomputed via §2) · IMU tiles (yaw labelled
  relative — gyro-only)
- One merged health line: freshness (> 500 ms = stale), packet loss %,
  update rate — plus a stale chip and the hand-mismatch warning when they
  apply. Battery is hidden until the firmware actually reports it.
- Actions: Zero yaw (0x06), Record → `/collect`, calibration chip
  (cal_id + fw version) → `/calibration`

---

## 5. Calibration wizard (glove-authoritative)

- **The glove is the authority.** NVS holds the profile; the app mirrors
  CAL_INFO into `SharedPrefsCalInfoCache` (`calinfo.L` / `calinfo.R`) —
  shown while disconnected, never edited.
- Flow: Start (0x01) → step driven by STATUS (1–10; odd = flat → 0x02,
  even = 90° → 0x03) → after step 10 the firmware saves and pushes CAL_INFO
  with a bumped `calibration_id` → mode returns to 0 → **done**.
- The app never advances locally; Capture re-enables on the next STATUS or
  after a 1.5 s fallback. Completion = mode 0 **and** id greater than at
  start (0 → 1 works for first calibration).
- Errors: 3 → stay on step, "Bend further and try again." · 4 → firmware
  advances, "check wiring" noted on that finger · 1/2 → informational.
- Cancel (0x04) keeps the previous profile. Summary: per-finger
  valid/weak/flat Ω/90° Ω/span + header (cal_id, fw, R_DIV).

### Motion sensor setup (IMU mount, fw 1.3.0)

- Calibration screen, below the hand picker: one card per glove with
  "Check stillness sensor" (0x0B), Pose 1 (0x09), Pose 2 (0x0A) and the
  state from STATUS flags bit1 (set up / default). Widget keys
  `mount-<left|right>-<command name>`.
- STATUS has no mount progress field. `MountCalibrationController` takes
  each command's result from the error byte of the first STATUS after a
  300 ms stale window (the glove sends nothing during the ~2 s capture);
  15 s without one → "did not answer". From 4 s on it also READs STATUS
  every 1 s (`GloveConnection.refreshStatus`) in case NOTIFYs are not
  arriving — not sooner, since the stored value keeps the previous result
  until the capture ends. A failed command write shows "Could not reach
  the glove" at once. Errors 2, 5–10 map to plain messages
  (`AppStrings.mount*`). A good Pose 2 bumps `mount_calibration_id`.
- fw 1.2.0 gloves (5-byte STATUS, no mount id) show an update note instead
  of the buttons. A note reminds the user to restart the glove after
  changing its hand.

---

## 6. Dataset recorder (5 Hz, calibration-aware)

- One session per (hand, calibration_id, mount_calibration_id) — a change
  in either id closes the file and opens a new one; files never mix
  calibrations (mount id from STATUS; null on fw 1.2.0). `cal_id == 0` blocks
  recording.
- Drops counted, never kept: raw 0/4095 on a **valid** finger (`adcRail`),
  wrap-safe seq gap > 3 (`seqGap`) between consecutive RECEIVED frames
  (not between samples: at 20 Hz vs 5 Hz those are normally 3 apart, so a
  late timer tick used to drop good rows). Re-sampling the same frame
  (glove stalled) writes nothing. During a take every skip shows a plain
  reason on the Record screen (cal_id 0, sensor at its limit, link loss,
  no new readings); the next written row clears it. Invalid fingers lose
  their columns.
- Takes: each Start press increments `take_id` (new session → 1); rows only
  flow while a labeled take runs; empty label blocked. Signer id =
  participantId (FR-13) or `anon-XXXX`. Consent gate unchanged (NFR-8).
- **Undo last take** (button after a take ends, with a confirm): deletes
  that take's rows from every session CSV it wrote to, rewrites the
  sidecars and rebuilds coverage. One level; works until the app restarts.
  Sidecars are also rewritten at every take end, so sessions are listed
  and shareable without pressing Stop.
- **Delete all recordings** (confirm; disabled while recording) wipes every
  CSV, sidecar and `index.json` — a clean restart after a recalibration.
- **Sidecar recovery**: on app start, a CSV with no sidecar (app killed
  before any take ended) gets one rebuilt from the CSV — ids from its first
  row, `rows` counted, finger `valid` = its `ang_` column exists, plus
  `"recovered": true`. Keeps Share and the coverage counts in agreement.
- Files (app-support `talkhimik_dataset/`):
  `talkhimik_<L|R>_<session_id>_cal<cal_id>.csv` + `_sidecar.json`.
  CSV header (§ thumb columns only if valid bit0, first in each group):
  `timestamp_ms, session_id, signer_id, hand, calibration_id, label,
  take_id, raw_*, ohm_*, ang_*, roll, pitch, yaw, quality_flag`.
  Sidecar: session/signer/hand/cal_id/mount_calibration_id/roll_note/rate/
  fw/recorded_at/rows/dropped {adcRail, seqGap}/r_div/fingers{valid,weak,
  flat/bent ohm+adc,span}. `roll_note` matches the web dashboard's text.
- Rows are appended as recorded (crash-safe); sessions list newest first
  with size, Share (`share_plus`) and Delete. Web/Windows without path
  provider: recording unsupported (graceful `UnsupportedError`).

---

## 7. Persistence & settings

- **Hive** (pure Dart; IndexedDB on web): `events`, `syncQueue` (C-S4),
  `sessions`. Participant id/consent live in shared_preferences only.
- **shared_preferences**: language/rate/voice/mute, large text,
  participantId, consentGiven/Date, forceMock + demoScenario (in the
  Settings "Developer" section), signing hand + phone-recognition toggle
  (Settings → Recognition / Developer, §13), calinfo.L/R.
- **Mock glove** (dev/demo/test): transcript scenarios (alphabet sweep,
  mixed confidence, random disconnect), animated telemetry, wizard with
  forced errors 3/4, loss bursts every 7 s, per hand.

---

## 8. Testing

262 tests, `flutter analyze` clean, per-phase commits.

- **Unit**: sensor-math golden vectors + seqGap wrap · codecs vs §1 ·
  wizard step/error/completion · recorder rules (cal change, cal 0 gate,
  rail/gap drops, take_id, consent, label) · writer goldens (exact header,
  sidecar keys, ohm/angle re-derive)
- **Widget**: live screen (both hands, stale, uncalibrated, mismatch,
  zero-yaw target) · calibration wizard prompts · collect gates
- **Integration**: mock end-to-end — calibrate → record → export →
  re-derive from raw + sidecar

### Hardware verification (staged, nRF Connect first)

- **A.** nRF Connect: `TALKHIMIK-L/R` advertising §1 service; four
  characteristics; 29/9/104-byte frames (STATUS 5 on fw 1.2.0); opcodes
  0x01–0x0B; stateless reconnect.
- **B.** App static: BLE manifest permissions; Force mock off; analyze +
  tests green; `flutter build apk --debug`.
- **C.** Phone + glove: permissions → Scanning…→ Connected; battery "—"
  and Uncalibrated chip; Live hand moves; wizard steps 1–10 with `cal_id`
  bump; motion sensor setup: Pose 1 → Pose 2 → "set up" and a new
  `mount_calibration_id`, hand animation level with palm down; record
  labeled take → CSV + sidecar; connection-lost banner ≤ 3 s
  with 1→2→4→8→30 s backoff; walk out of range and back — no dupes.
  **On-device link diagnostics** (no frames? wrong MTU?): Settings →
  Developer → BLE diagnostics — report MTU, notify results, last payload
  length, reject reasons, bond state.
- **D.** Regression: Force mock on → demo still works end-to-end.

---

## 9. Definition of done

- ✅ Mock demonstrates every state on Windows/web without hardware.
- ✅ Keep areas (transcript/TTS/settings/Hive log/export/reconnect) behave
  as before; existing tests green.
- ✅ Zero connectivity — no network calls.
- ⚠️ Real glove flow (connect → live → wizard → record → export → re-derive)
  passes on the mock; hardware verification pending (§8 A–C).
- ⚠️ Both gloves simultaneously: code + tests ready; realme multi-connection
  unverified.

### Open items

- Production label packet (planned §1) — the firmware stage that replaces
  phone-side recognition; the app already handles both paths.
- TFLite engine on the phone — the trained model currently runs as a
  pure-Dart MLP (§15); `assets/models/talkhimik_letters.tflite` +
  a TFLite engine behind `GestureClassifier` are the upgrade path.
- Hardware verification on the realme phone with real gloves.

---

## 10. Dev environment & platforms

- **Android** (primary): SDK 36 + Temurin JDK 17 at `D:\Android`
  (`flutter config --android-sdk/--jdk-dir`); `flutter build apk` green;
  app installed on the realme field phone. BLE needs a physical phone.
- **Windows**: dev machine — mock gloves, full UI.
- **Web (`flutter run -d chrome`)**: mock gloves only; Hive in IndexedDB;
  TTS degrades; dataset recording unsupported. Demo: Home scenarios + Live
  two animated hands + mock wizard.
- **iOS**: no target — out of thesis scope.

---

## 11. Thesis pointers

The thesis-level narrative (architecture, phases, budget, ML pipeline) is kept
by the team, outside this repo. The firmware and web dashboard are in
[`firmware/`](../firmware/README.md) (wiring, build steps, packet
quickstart).

---

## 12. Design system (2026-10 refresh, v3)

Source of truth: `lib/core/theme/` — `AppColors` + `TalkhimikTokens` +
`TalkhimikText` + `TalkhimikMotion` ThemeExtensions. Identity: the three
signature blues — **sky `#54C5F8`, azure `#29B6F6`, navy `#01579B`** — on a
clean white field with crisp 45° diagonal slabs (`DiagonalSlab` /
`SlabBackdrop`) and a soft fold shadow where navy meets azure. LIGHT is the
primary theme; dark derives from the navy (`#06182B` / `#0C2540`) and
**follows the device setting** (`ThemeMode.system`).

**Rules baked in (AA):** sky and azure are fills only (≈1.9:1 / ≈2.3:1 on
white) — text on them is navy (`#0B2540`, 5.9:1). Cards/inputs carry the
1 dp `#3E7196` hairline (4.4:1) so the background → card → chip depth step
always reads. Confidence badges: green/amber/red + **✓ / ◐ / ! glyphs +
labels** (color never the only signal). Connected = filled brand-blue dot +
label; info = teal `#00796B` + ⓘ (distinct hue); Demo = neutral tag, mock
mode only; battery hidden when the firmware sends 0xFF (never a
placeholder).

### Typography & motion

- **Font**: Inter 400/500/600/700, bundled (`assets/fonts/`, OFL), never
  fetched (C6). Scale: display 36/44, title 24/20, body 16, label 14,
  caption 12. `transcriptHero` 44/700 (leading 1.05) for the latest sign —
  history steps down 24 → 18 at 70 %/50 % opacity; metrics/id use tabular
  figures.
- **Motion** (`TalkhimikMotion`): 100/180/280/420 ms · easeOutCubic/easeIn/
  elasticOut · `resolve()` zeroes durations under reduce-motion. What
  animates: slab entrances (staggered 60 ms), hero sign fade+rise, status
  pill label crossfade, busy-dot/recording pulses (gated off in tests and
  reduce-motion), banner slide+fade, wizard step slide, error-3 shake,
  checkmark draw + cal_id count-up, bubble entrances, pressed-scale + azure
  glow, shared fade-through transitions ≤ 280 ms. Haptics: capture
  accepted, calibration complete, recording start/stop.
- **Rejected**: idle slab drift (perpetual animation — conflicts with
  off-screen and settle guarantees), skeleton shimmer (needs a loading
  flag = logic change), TTS speaking bars (no completion signal), session
  card exit choreography (instant delete kept).

### UI/UX laws — how each is met

| Law | Implementation |
|---|---|
| Fitts | 48 dp min targets, dominant Connect/Listening pill in the thumb zone, one dominant action per screen |
| Hick | 4 labeled bottom-nav destinations, ≤ 2 app-bar actions, 1 primary + 1 secondary per screen |
| Jakob | App bar + labeled bottom nav + system back; controls are pills |
| Miller | ≤ 5 finger cards per ticker, one calibration step per screen, grouped More cards |
| Proximity/Similarity | Status + banner share a card; quick-reply chips styled like the input |
| Aesthetic-usability/Hierarchy | hero sign > title > body > caption; navy reserved for the main action and active states (Von Restorff) |
| Doherty | feedback < 400 ms; animations never block input |
| Postel/Error prevention | inline recovery copy for calibration errors 3/4, permissions, disconnects; battery never faked |
| Tesler | BLE jargon behind the details sheet; demo controls in Developer |
| Zeigarnik/Peak-end | progress ring n/10 + elastic checkmark completion |
| Serial-position | primary action in the thumb zone, secondary at the bottom edge |
| Recognition over recall | every icon has a label or tooltip; custom-painted widgets get Semantics labels |
| Accessibility | AA everywhere, non-color state cues, reduce-motion zeroing, large text verified at 1.0/1.3/2.0 × on 360 dp (all screens) |

---

## 13. Phone-side recognition (C1 + C4)

The recognizer turns real-glove telemetry into transcript events through
the SAME path the (planned) glove label packets use — one bubble, one TTS
speak, one Hive log row, one source of truth.

```
telemetry (20 Hz) ── signing hand (Settings → Recognition)
   → RefuseGate (cal_id 0 / uncalibrated / stale >500 ms / invalid finger)
   → classifier (ThresholdClassifier | DartMlpClassifier)
   → stabilizer (20-frame majority, release + min-gap rules)
   → RecognitionEventBus ──→ transcript bubble + TTS + Hive log
```

- **Gates (never guess, concept C5):** `RefuseGate` refuses uncalibrated
  gloves (cal_id 0 or STATUS bit0), frames older than 500 ms, and frames
  with an invalid finger in the quality byte. Reasons surface in the
  debug panel.
- **Stand-in classifier (C1):** 10 angle rules in ONE const table
  (`lib/domain/classifier/threshold_classifier.dart`), each mapped to a
  representative letter (A·B·F·D·V·U·W·I·Y·C). Merged classes are never
  presented as certain: confidence capped at 0.55. Rules are first-match
  in table order.
- **Trained model (C4):** `assets/models/weights.json` + `labels.json`
  run as a pure-Dart MLP (in → 32 → 32 → softmax; normalization baked
  into layer 1, so the phone passes raw degrees). Source
  `phone-tflite`, model version `mlp-<dataset_hash8>`. Below the
  labels.json confidence floor or on the `_rest` class nothing is
  emitted (it counts as a release). No model present / wrong hand /
  corrupt files → the threshold rules take over (`ClassifierFactory`).
- **Stabilizer constants** (`lib/domain/classifier/stabilizer.dart`):
  window 20 frames @ 20 Hz, majority ≥ 10 votes, release = neutral for
  ≥ 400 ms, min 400 ms between emissions; the same letter twice requires
  a release between; stale/disconnect resets the window. NFR-1 ≤ 500 ms
  is measured from the emission decision; the ~0.5 s hold-to-confirm is
  a documented trade-off.
- **Signing hand:** Settings → Recognition → Signing hand (Auto = the
  only connected glove, else Right / Left / Right). Developer toggle
  "Phone recognition" (default ON for real gloves; forced OFF in mock
  mode — the mock drives its own transcript).
- **Precedence:** a real glove label packet pauses phone recognition
  until the next disconnect.
- **Debug panel** (Settings → Developer, and Live in debug builds):
  classifier, model version, trained-on summary, hand, raw class/letter/
  confidence, top-3, votes, gate reason, last emission — the tool for
  diagnosing "nothing appears".

## 14. Dataset coverage (C2)

- `talkhimik_dataset/index.json` is a derived cache (per label: takes,
  rows, hands, calibration ids, signers), rebuilt from the session CSVs
  when missing/corrupt and updated at take stop / session changes. The
  CSV/sidecar formats are untouched.
- The Collect screen shows a coverage card in four collapsible sections:
  Letters (28 + REST), Words and phrases (still), Words and phrases
  (movement), Error moves. Phrases start under movement; holding one moves it
  (`settings.stillPhrases`). Every bubble shows take counts and icon states — <5 takes "needs data",
  5–9 "ok", ≥10 "good"; Z is marked "later" (dynamic, no motion gate
  yet). J counts like any letter (motion-gated, see the pipeline facts).
  Constants live in `lib/data/dataset/coverage_index.dart`. Tapping a
  bubble selects that label for recording (locked while a take runs).
- REST is a first-class take, stored as label `_rest`.
- Error moves: one per moving phrase (`_wrong_<phrase>`) plus shared
  `_random`. The trainer never trains on them; `report.md` "Wrong moves"
  lists how many takes made the app speak (false positives).
- "Add a word" asks for Filipino, English and the section (still/movement).
  Words live in `settings.customWords` (ids never reused; deleting hides the
  word and keeps its recordings; adding it again restores it). They are spoken
  only after recording, training and installing a new model.
- "Share all for training" exports every CSV + sidecar + the coverage
  index + `words.json` (custom word ids, still phrases) through the share sheet (multi-file, no zip).

## 15. Training pipeline (`ml/`, C3) — how to ship a new model

```
1. collect    Collect screen → record takes (10+ per letter, REST too)
2. export     Collect → "Share all for training" → save the folder
3. train      ml/.venv: python train.py <folder> --out out
              (pip install -r requirements.txt; + tensorflow for .tflite)
4. install    copy out/weights.json + out/labels.json (+ .tflite) into
              assets/models/ and rebuild the app
5. test       Home with the real glove: debug panel shows
              phone-tflite + the model version
```

Pipeline facts: validation and every drop decision are reported
(missing sidecar, cal mismatch, invalid-finger sessions, bad-quality
rows, <5-take labels, Z skipped); **moving labels are motion-gated** (detected: the median
take turns the hand ≥ 20°; J always): their handshape trains like any label, and `motion_gates()` writes `labels.json`
`motion_labels: {"J": {"pitch_span_deg": x, "window_ms": 1500}}` with x
midway between still takes (letters and REST, not phrases; 95th-percentile pitch span) and that sign's
smallest take span. The app (`MotionGate`, recognition controller) emits it
only after the hand, within 2 s, passed all 5 tilt directions of one recorded
take in order (`paths`, tolerance 0.4 × the movement's size); models without
`paths` need a pitch change ≥ x in the last 1.5 s. A still handshape is neutral.
Tilt only: body height, straight slides and hand contact are not measured.
Pitch, because roll wraps at ±180 and yaw drifts. A hand whose
session split would leave train, val or test empty splits by take instead (report flags it optimistic); splits are grouped by SESSION
(~70/15/15, per-label coverage — never random rows) with
leave-one-signer-out when ≥ 2 signers (one signer → the report says
cross-person generalization is untested); two input variants are
compared (A = angles, B = angles + roll/pitch; yaw never used); outputs:
report.md, MODEL_CARD.md, confusion matrix CSV/PNG, weights.json,
labels.json (hand, input spec, class→word_id map, confidence floor,
trained-on summary, metrics), and .tflite when TensorFlow is installed.
`python test_pipeline.py` verifies the whole pipeline on synthetic data.
