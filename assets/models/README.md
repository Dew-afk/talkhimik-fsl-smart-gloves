# assets/models/ — shipped recognition model (C4)

Place the trained model's files here (produced by `ml/train.py`, see
`ml/README.md` for the collect → export → train flow):

- `labels.json` — metadata: hand, input spec, class → word_id map,
  confidence floor, trained-on summary, metrics.
- `weights.json` — the MLP weights (normalization baked into layer 1;
  the phone passes raw degrees). This is what the current pure-Dart
  engine runs.

The app works with NO model present: `ClassifierFactory` falls back to
the C1 threshold rules, and the debug panel shows which classifier is
active.
