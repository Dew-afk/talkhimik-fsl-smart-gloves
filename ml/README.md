# ml/ — TALKHIMIK letter training pipeline (C3)

Turns the phone's C2 exports (CSV + sidecar pairs + coverage index) into
a small letter model the app runs on-device (C4).

## Flow

```
Collect screen (app) --"Share all for training"--> folder/ (CSV + sidecar + index.json)
load_dataset.py  ->  clean_dataset.csv  (validated, Z skipped, J/Salamat motion-gated, _rest kept)
train.py         ->  out/{weights.json, labels.json, report.md,
                          MODEL_CARD.md, confusion_matrix.csv/png,
                          talkhimik_letters.tflite(+_int8, with TF)}
```

## Setup

```bash
cd ml
python -m venv .venv
.venv/Scripts/pip install -r requirements.txt      # Windows
# .venv/bin/pip install -r requirements.txt        # Linux/macOS
```

For the `.tflite` files also: `.venv/Scripts/pip install tensorflow`.

## Train

```bash
.venv/Scripts/python train.py <export-folder> --out out
```

Run the self-check (synthetic data, no real dataset needed):

```bash
.venv/Scripts/python test_pipeline.py
```

## What the pipeline does

- **Loader** (`load_dataset.py`): pairs CSVs with sidecars, validates
  calibration ids and columns, excludes sessions with an invalid finger,
  drops bad-quality rows, skips Z (dynamic, no gate yet), keeps J and
  Salamat (the handshape trains; `labels.json` `motion_labels` holds the pitch
  change the app requires before emitting them), keeps `_rest`,
  drops labels under 5 takes. Every decision lands in the report.
- **Features**: angles (5, degrees 0–90) for variant A; angles + roll +
  pitch for variant B. Yaw is never used (gyro drift). Normalization is
  **baked into the first layer's weights**, so the phone passes raw
  degrees — no preprocessing anywhere.
- **Splits**: grouped by session (never random rows), ~70/15/15 with
  per-label coverage; leave-one-signer-out reported when ≥ 2 signers
  exist. One signer → the report says cross-person generalization is
  untested.
- **Model**: MLP in → 32 → 32 → softmax, class weights, ±3° angle /
  ±5° roll-pitch augmentation, early stopping. `_rest` is a normal class.
- **Eval**: held-out accuracy, per-class P/R/F1, top confusable pairs,
  confusion matrix (CSV + PNG), variant A-vs-B comparison, and a
  confidence-floor recommendation (lowest threshold where held-out
  precision ≥ 95 %, with the coverage trade-off table).
- **Exports**: `weights.json` (MLP weights, normalization baked — the C4
  Dart fallback reads exactly this), `labels.json` (input spec, class →
  word_id map, confidence floor, trained-on summary, metrics),
  `talkhimik_letters.tflite` (float32) + `_int8.tflite` (for future
  on-glove TFLM; both need TensorFlow).

## Shipping a new model to the app (C4)

Copy `talkhimik_letters.tflite`, `labels.json`, and `weights.json` into
`app/assets/models/` and bump the asset entries in `pubspec.yaml`. The
app works with no model present (falls back to the C1 threshold rules).

## Files

| File | Purpose |
|---|---|
| `load_dataset.py` | C2 exports → clean table + loader report |
| `train.py` | splits, MLP training, eval, JSON exports, report |
| `export_tflite.py` | optional TF-based float32 + int8 conversion |
| `synth.py` | synthetic dataset generator (tests / smoke runs) |
| `test_pipeline.py` | end-to-end self-check, no real data needed |
