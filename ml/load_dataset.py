"""C3 loader: folder of C2 exports (CSV + sidecar pairs) -> clean table.

Rules (all reported, none silent):
  * a CSV without its sidecar is EXCLUDED
  * sidecar calibration_id must match the CSV's calibration_id column
  * expected columns must exist (timestamp_ms, session_id, signer_id,
    hand, calibration_id, label, take_id)
  * sessions where any of the five needed fingers is invalid (its
    ang_<finger> column is missing) are EXCLUDED — the model needs all 5
  * rows with a bad quality flag (any valid-finger bit cleared) are dropped
  * Z is skipped (dynamic letter, no motion gate yet). J is KEPT: its
    handshape trains like any letter and train.py exports the movement the
    app checks before emitting it (as for every moving label)
  * labels with fewer than MIN_TAKES takes are dropped and reported
  * the special REST label `_rest` is kept as a normal class
  * other labels starting with `_` (`_wrong_<word>`, `_random`) are wrong
    moves: never training rows, only scored (train.score_wrong_moves)

Output columns (fixed contract for train.py):
  signer, session, take, hand, calibration_id, label,
  ang_thumb, ang_pointer, ang_middle, ang_ring, ang_pinky, roll, pitch
"""

import csv
import json
import os
import sys

FINGERS = ["thumb", "pointer", "middle", "ring", "pinky"]
SKIP_LABELS = {"Z"}
MOTION_LABELS = {"J"}  # always moving; others are detected (train.moving_labels)
REST_LABEL = "_rest"
MIN_TAKES = 5  # labels with fewer takes than this are dropped (reported)

REQUIRED_COLUMNS = [
    "timestamp_ms", "session_id", "signer_id", "hand",
    "calibration_id", "label", "take_id",
]


def _csv_rows(path):
    with open(path, newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def _sidecar_for(csv_path):
    base, _ = os.path.splitext(csv_path)
    return base + "_sidecar.json"


def is_wrong_move(label):
    return label.startswith("_") and label != REST_LABEL


def load_dataset(input_dir, wrong_moves=False):
    """Returns (rows, report). rows is a list of dicts in the output
    contract; report is a dict of loader decisions for report.md.
    wrong_moves=True returns only the wrong-move rows instead."""
    report = {
        "files_seen": 0, "missing_sidecar": [], "cal_id_mismatch": [],
        "missing_columns": [], "invalid_finger_sessions": [],
        "bad_quality_rows_dropped": 0, "labels_skipped": sorted(SKIP_LABELS),
        "low_take_labels_dropped": {}, "rows_total": 0,
    }
    rows = []
    for name in sorted(os.listdir(input_dir)):
        if not name.endswith(".csv") or name.endswith("index.json"):
            continue
        report["files_seen"] += 1
        csv_path = os.path.join(input_dir, name)
        sidecar_path = _sidecar_for(csv_path)
        if not os.path.exists(sidecar_path):
            report["missing_sidecar"].append(name)
            continue
        try:
            sidecar = json.load(open(sidecar_path, encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            report["missing_sidecar"].append(name + " (corrupt)")
            continue

        table = _csv_rows(csv_path)
        if not table:
            continue
        if any(c not in table[0] for c in REQUIRED_COLUMNS):
            report["missing_columns"].append(name)
            continue
        if str(table[0].get("calibration_id")) != str(
                sidecar.get("calibration_id")):
            report["cal_id_mismatch"].append(name)
            continue

        # Needed fingers: all five. Missing ang_<finger> column = the
        # session cannot train the model -> exclude, not guess.
        missing_fingers = [
            f for f in FINGERS if f"ang_{f}" not in table[0]]
        if missing_fingers:
            report["invalid_finger_sessions"].append(
                f"{name} (missing {','.join(missing_fingers)})")
            continue

        # Valid mask from the sidecar's per-finger blocks (thumb..pinky).
        finger_blocks = sidecar.get("fingers") or {}
        valid_mask = 0
        for i, f in enumerate(FINGERS):
            block = finger_blocks.get(f) or {}
            if block.get("valid"):
                valid_mask |= 1 << i
        for r in table:
            label = (r.get("label") or "").strip()
            if label in SKIP_LABELS:
                continue  # skipped silently per-spec, counted as labels_skipped
            if not label or is_wrong_move(label) != wrong_moves:
                continue
            # Bad quality flag: a valid-finger bit cleared -> glitch row.
            quality = int(r.get("quality_flag", "0") or "0", 0)
            if quality & valid_mask != valid_mask:
                report["bad_quality_rows_dropped"] += 1
                continue
            try:
                angles = [float(r[f"ang_{f}"]) for f in FINGERS]
            except (TypeError, ValueError):
                report["bad_quality_rows_dropped"] += 1
                continue
            if any(a < -0.5 or a > 90.5 for a in angles):
                report["bad_quality_rows_dropped"] += 1
                continue
            rows.append({
                "signer": r["signer_id"],
                "session": r["session_id"],
                "take": int(r["take_id"]),
                "hand": r["hand"],
                "calibration_id": int(r["calibration_id"]),
                "label": label,
                "ang_thumb": angles[0], "ang_pointer": angles[1],
                "ang_middle": angles[2], "ang_ring": angles[3],
                "ang_pinky": angles[4],
                "roll": float(r.get("roll", "0") or "0"),
                "pitch": float(r.get("pitch", "0") or "0"),
            })
            report["rows_total"] += 1

    # Low-take labels: count takes per label, drop below MIN_TAKES.
    takes = {}
    for r in rows:
        takes.setdefault(r["label"], set()).add(
            (r["session"], r["take"]))
    if wrong_moves:
        return rows, report  # scored take by take: few takes still count
    report["low_take_labels_dropped"] = {
        l: len(ts) for l, ts in sorted(takes.items())
        if len(ts) < MIN_TAKES}
    rows = [r for r in rows
            if len(takes[r["label"]]) >= MIN_TAKES]

    return rows, report


def write_clean_csv(rows, out_path):
    fields = ["signer", "session", "take", "hand", "calibration_id",
              "label", "ang_thumb", "ang_pointer", "ang_middle",
              "ang_ring", "ang_pinky", "roll", "pitch"]
    with open(out_path, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader()
        w.writerows(rows)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("usage: python load_dataset.py <input_dir> [out_clean.csv]")
        sys.exit(2)
    data, rep = load_dataset(sys.argv[1])
    out = sys.argv[2] if len(sys.argv) > 2 else "clean_dataset.csv"
    write_clean_csv(data, out)
    print(json.dumps(rep, indent=2))
    print(f"wrote {len(data)} rows -> {out}")
