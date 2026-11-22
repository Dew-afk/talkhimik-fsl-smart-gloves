"""C3 trainer: grouped splits, small MLP (in -> 32 -> 32 -> softmax),
two input variants, class weights, light augmentation, early stopping,
evaluation, confidence-floor recommendation, and JSON/TFLite exports.

Normalization is baked INTO the first layer's weights (see
_bake_normalization), so the phone passes raw degrees — no preprocessing
anywhere. The same transformed weights ship as weights.json (the C4
pure-Dart fallback mirrors this exact forward pass).

usage: python train.py <input_dir> [--out out_dir] [--seed 7]
"""

import argparse
import hashlib
import json
import os
import struct
import zlib

import numpy as np

from load_dataset import (FINGERS, MOTION_LABELS, REST_LABEL, load_dataset,
                          write_clean_csv)

# FSL word_id contract — mirrors lib/domain/vocab/fsl_vocabulary.dart.
# Changing ids in the app requires changing this table too.
FSL_WORD_IDS = {
    "A": 1, "B": 2, "C": 3, "D": 4, "E": 5, "F": 6, "G": 7, "H": 8,
    "I": 9, "J": 10, "K": 11, "L": 12, "M": 13, "N": 14, "Ñ": 15,
    "NG": 16, "O": 17, "P": 18, "Q": 19, "R": 20, "S": 21, "T": 22,
    "U": 23, "V": 24, "W": 25, "X": 26, "Y": 27, "Z": 28,
    "Kumusta": 100, "Magandang umaga": 101, "Magandang hapon": 102,
    "Magandang gabi": 103, "Salamat": 104, "Walang anuman": 105,
    "Paalam": 106, "Oo": 107, "Hindi": 108, "Pasensya na": 109,
    "Tulong": 110, "Mahal kita": 111, "Ano ang pangalan mo?": 112,
    "Saan ang palikuran?": 113, "Gutom ako": 114, "Uhaw ako": 115,
    "Magkano?": 116,
}
REST_WORD_ID = 0
FIRST_PHRASE_ID = 100  # phrases are signed with movement

HIDDEN = [32, 32]
MAX_EPOCHS = 200
EARLY_STOP_PATIENCE = 10
AUG_ANGLE = 3.0
AUG_ROLL_PITCH = 5.0
MIN_SESSIONS_PER_HAND = 5
MIN_LABELS_PER_HAND = 3

INPUT_A = [f"ang_{f}" for f in FINGERS]
INPUT_B = INPUT_A + ["roll", "pitch"]
VARIANTS = {"A": INPUT_A, "B": INPUT_B}

MOTION_WINDOW_MS = 1500     # the app looks back this far for the motion
DEFAULT_MOTION_SPAN = 40.0  # only when no take has 2+ rows to measure


def motion_gates(rows):
    """Per motion label present: the pitch change (deg) the app must see
    within MOTION_WINDOW_MS before emitting it. Midway between still takes
    (letters and REST, not phrases, which move; 95th percentile span, so
    one fidgety REST take cannot raise it) and
    the motion label's smallest take span. Pitch, not roll (wraps at
    +/-180) or yaw (drifts)."""
    pitches = {}
    for r in rows:
        pitches.setdefault((r["label"], r["session"], r["take"]),
                           []).append(r["pitch"])
    spans = {k: max(v) - min(v) for k, v in pitches.items() if len(v) >= 2}
    still = sorted(s for (l, _, _), s in spans.items()
                   if l not in MOTION_LABELS
                   and FSL_WORD_IDS.get(l, 0) < FIRST_PHRASE_ID)
    still_hi = still[int(0.95 * (len(still) - 1))] if still else 0.0
    gates = {}
    for label in sorted({r["label"] for r in rows} & MOTION_LABELS):
        moving = [s for (l, _, _), s in spans.items() if l == label]
        gates[label] = (round((still_hi + min(moving)) / 2, 1) if moving
                        else DEFAULT_MOTION_SPAN)
    return gates


# ---------------------------------------------------------------- model

class MLP:
    """layers: list of (W, b) for the hidden+output dense layers."""

    def __init__(self, layers, classes):
        self.layers = layers
        self.classes = classes

    def forward(self, X):
        a = X
        for W, b in self.layers[:-1]:
            a = np.maximum(0, a @ W + b)  # relu
        W, b = self.layers[-1]
        z = a @ W + b
        e = np.exp(z - z.max(axis=1, keepdims=True))
        return e / e.sum(axis=1, keepdims=True)

    def predict_proba(self, X):
        return self.forward(X)

    def predict(self, X):
        return np.array([self.classes[i]
                         for i in self.forward(X).argmax(axis=1)])


def _bake_normalization(layers, mu, sigma):
    """Fold input standardization into the first layer so the phone passes
    raw degrees: W1' = W1 / sigma, b1' = b1 - W1' @ mu."""
    W1, b1 = layers[0]
    sigma = np.maximum(sigma, 1e-6)
    W1n = W1 / sigma[:, None]
    layers[0] = (W1n, b1 - W1n.T @ mu)
    return layers


def train_mlp(X, y, classes, X_val, y_val, seed=7, epochs=MAX_EPOCHS,
              input_has_roll_pitch=False):
    """Adam + class weights + per-batch augmentation + early stopping.

    X/X_val are RAW degrees (no preprocessing): standardization happens
    inside, and augmentation is applied in raw units (+-3 deg angles,
    +-5 deg roll/pitch) BEFORE normalization. Returns (model, mu, sigma)
    so callers evaluate/export with the same statistics."""
    rng = np.random.default_rng(seed)
    mu = X.mean(axis=0)
    sigma = X.std(axis=0) + 1e-6
    Xn = (X - mu) / sigma
    Xvn = (X_val - mu) / sigma
    n, d = X.shape
    k = len(classes)
    y_idx = np.array([classes.index(c) for c in y])
    val_idx = np.array([classes.index(c) for c in y_val])

    # Class weights: w_c = n / (k * n_c).
    counts = np.bincount(y_idx, minlength=k).astype(float)
    weights = np.where(counts > 0, n / (k * np.maximum(counts, 1e-9)), 1.0)
    w_per_row = weights[y_idx]

    def init(layer_in, layer_out):
        bound = np.sqrt(6.0 / (layer_in + layer_out))
        W = rng.uniform(-bound, bound, (layer_in, layer_out))
        b = np.zeros(layer_out)
        return W, b

    layers = [init(d, HIDDEN[0])] + \
             [init(HIDDEN[i], HIDDEN[i + 1]) for i in range(len(HIDDEN) - 1)] + \
             [init(HIDDEN[-1], k)]
    params = [w for layer in layers for w in layer]
    m = [np.zeros_like(p) for p in params]
    v = [np.zeros_like(p) for p in params]

    def augment(batch_raw):
        """Noise in RAW degree space, then the same standardization the
        phone will never need (it is baked into the exported weights).
        Near-constant features (sigma < 1e-3) get no noise — dividing a
        few degrees by ~0 would explode the standardized batch."""
        out = batch_raw.copy()
        n_angles = len(INPUT_A)
        for j in range(out.shape[1]):
            if sigma[j] < 1e-3:
                continue
            scale = AUG_ANGLE if j < n_angles else AUG_ROLL_PITCH
            out[:, j] += rng.uniform(-scale, scale, len(batch_raw))
        return (out - mu) / sigma

    best_val = np.inf
    best_layers = None
    bad = 0
    for epoch in range(epochs):
        order = rng.permutation(n)
        Xs, ys, ws = X[order], y_idx[order], w_per_row[order]
        for i in range(0, n, 32):
            Xb = augment(Xs[i:i + 32])
            yb = ys[i:i + 32]
            wb = ws[i:i + 32]
            # forward
            a = Xb
            acts = [a]
            for W, b in layers[:-1]:
                a = np.maximum(0, a @ W + b)
                acts.append(a)
            W, b = layers[-1]
            z = a @ W + b
            e = np.exp(z - z.max(axis=1, keepdims=True))
            prob = e / e.sum(axis=1, keepdims=True)
            # grads (cross-entropy, class-weighted)
            g = prob.copy()
            g[np.arange(len(yb)), yb] -= 1
            g *= wb[:, None] / len(yb)
            grads = []
            dL = g
            grads.append((acts[-1].T @ dL, dL.sum(axis=0)))
            dA = dL @ W.T
            for li in range(len(layers) - 2, -1, -1):
                Wl, bl = layers[li]
                if li > 0:  # hidden layers are relu; the input layer is not
                    dA = dA * (acts[li] > 0)
                grads.append((acts[li].T @ dA, dA.sum(axis=0)))
                if li > 0:
                    dA = dA @ Wl.T
            grads.reverse()
            # adam
            flat = [g for gr in grads for g in gr]
            for pi in range(len(params)):
                m[pi] = 0.9 * m[pi] + 0.1 * flat[pi]
                v[pi] = 0.999 * v[pi] + 0.001 * flat[pi] ** 2
                mh = m[pi] / (1 - 0.9 ** (epoch + 1))
                vh = v[pi] / (1 - 0.999 ** (epoch + 1))
                params[pi] -= 0.001 * mh / (np.sqrt(vh) + 1e-8)
        # validation loss
        prob = MLP(layers, classes).predict_proba(Xvn)
        loss = -np.log(np.maximum(
            prob[np.arange(len(val_idx)), val_idx], 1e-9)).mean()
        if loss < best_val - 1e-4:
            best_val, bad = loss, 0
            best_layers = [(W.copy(), b.copy()) for W, b in layers]
        else:
            bad += 1
            if bad >= EARLY_STOP_PATIENCE:
                break
    return MLP(best_layers or layers, classes), mu, sigma


# ---------------------------------------------------------------- split

def split_sessions(rows, seed=7):
    """Grouped split by SESSION (never by rows): ~70/15/15 with per-label
    coverage. A label holding only one session stays in train."""
    rng = np.random.default_rng(seed)
    sessions_by_label = {}
    for r in rows:
        sessions_by_label.setdefault(r["label"], set()).add(r["session"])
    all_sessions = sorted({s for ss in sessions_by_label.values()
                           for s in ss})
    rng.shuffle(all_sessions)
    single = {next(iter(ss)) for ss in sessions_by_label.values()
              if len(ss) == 1}
    candidates = [s for s in all_sessions if s not in single]
    test, val = set(), set()
    for s in candidates:
        if len(test) / max(len(all_sessions), 1) >= 0.15:
            break
        test.add(s)
    for s in candidates:
        if s in test:
            continue
        if len(val) / max(len(all_sessions), 1) >= 0.15:
            break
        val.add(s)
    # Guard: every label keeps at least one session in train.
    for label, ss in sessions_by_label.items():
        if not any(s not in test and s not in val for s in ss):
            victim = next((s for s in sorted(ss) if s in test),
                          next((s for s in sorted(ss) if s in val), None))
            test.discard(victim)
            val.discard(victim)
    train = set(all_sessions) - test - val
    return train, val, test


def rows_for(rows, session_set):
    return [r for r in rows if r["session"] in session_set]


def feature_matrix(rows, variant):
    cols = VARIANTS[variant]
    return np.array([[r[c] for c in cols] for r in rows], dtype=np.float32)


# ------------------------------------------------------------- evaluate

def evaluate(model, X, rows):
    y_true = [r["label"] for r in rows]
    prob = model.predict_proba(X)
    y_pred = [model.classes[i] for i in prob.argmax(axis=1)]
    classes = model.classes
    cm = np.zeros((len(classes), len(classes)), dtype=int)
    idx = {c: i for i, c in enumerate(classes)}
    for t, p in zip(y_true, y_pred):
        cm[idx[t]][idx[p]] += 1
    acc = (cm.diagonal().sum() / max(cm.sum(), 1)) if cm.sum() else 0.0
    per_class = {}
    for i, c in enumerate(classes):
        tp = cm[i][i]
        fp = cm[:, i].sum() - tp
        fn = cm[i].sum() - tp
        precision = tp / (tp + fp) if tp + fp else 0.0
        recall = tp / (tp + fn) if tp + fn else 0.0
        per_class[c] = {"precision": round(precision, 4),
                        "recall": round(recall, 4),
                        "f1": round(2 * precision * recall /
                                    (precision + recall), 4)
                        if precision + recall else 0.0}
    macro = {m: round(float(np.mean([per_class[c][m]
                                     for c in classes])), 4)
             for m in ("precision", "recall", "f1")}
    confusables = []
    for i in range(len(classes)):
        for j in range(len(classes)):
            if i != j and cm[i][j] > 0:
                confusables.append((classes[i], classes[j], int(cm[i][j])))
    confusables.sort(key=lambda x: -x[2])
    return {"accuracy": round(float(acc), 4), "per_class": per_class,
            "macro": macro, "confusion": cm, "classes": classes,
            "confusables": confusables[:5]}


def confidence_floor(model, X, rows):
    """Lowest threshold at which held-out precision >= 95%, plus the
    coverage trade-off table."""
    y_true = [r["label"] for r in rows]
    prob = model.predict_proba(X)
    idx = {c: i for i, c in enumerate(model.classes)}
    conf = np.max(prob, axis=1)
    pred = [model.classes[i] for i in prob.argmax(axis=1)]
    correct = np.array([p == t for p, t in zip(pred, y_true)])
    floor = None
    table = []
    for t in np.arange(0.50, 1.00, 0.01):
        keep = conf >= t
        if not keep.any():
            continue
        prec = float(correct[keep].mean())
        table.append({"threshold": round(float(t), 2),
                      "coverage_pct": round(100 * keep.mean(), 1),
                      "precision": round(prec, 4)})
        if floor is None and prec >= 0.95:
            floor = round(float(t), 2)
    return floor, table


# --------------------------------------------------------------- export

def export_weights(model, mu, sigma, out_path, variant):
    """Transformed weights: normalization baked into layer 1 (the phone
    passes raw degrees). mu/sigma recorded for provenance only."""
    baked = _bake_normalization(
        [(W.copy(), b.copy()) for W, b in model.layers], mu, sigma)
    payload = {
        "format": "mlp-weights-v1",
        "variant": variant,
        "input_order": VARIANTS[variant],
        "input_mean": mu.tolist(),
        "input_std": sigma.tolist(),
        "normalization": "baked_into_first_layer",
        "hidden": HIDDEN,
        "classes": model.classes,
        "layers": [{"weights": W.tolist(), "bias": b.tolist()}
                   for W, b in baked],
    }
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(payload, f, indent=2)
    return payload


def export_labels(out_path, hand, variant, classes, floor, metrics,
                  trained_on, motion=None):
    # The confusion matrix ships as CSV/PNG; keep labels.json JSON-safe.
    json_metrics = {k: v for k, v in metrics.items() if k != "confusion"}
    payload = {
        "version": 1,
        "hand": hand,
        "input_spec": {"order": VARIANTS[variant],
                       "units": len(VARIANTS[variant]),
                       "variant": variant},
        "classes": [{"index": i, "label": c,
                     "word_id": REST_WORD_ID if c == REST_LABEL
                     else FSL_WORD_IDS.get(c, 0)}
                    for i, c in enumerate(classes)],
        "confidence_floor": floor if floor is not None else 0.95,
        "floor_precision_95": floor is not None,
        "rest_class": REST_LABEL,
        "motion_labels": {l: {"pitch_span_deg": v,
                              "window_ms": MOTION_WINDOW_MS}
                          for l, v in (motion or {}).items()},
        "trained_on": trained_on,
        "metrics": json_metrics,
        "created_at": None,  # filled below (JSON-safe)
    }
    payload["created_at"] = _now_iso()
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(payload, f, indent=2)
    return payload


def _now_iso():
    import datetime
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def write_confusion_csv(cm, classes, path):
    with open(path, "w", encoding="utf-8") as f:
        f.write("label," + ",".join(classes) + "\n")
        for i, c in enumerate(classes):
            f.write(c + "," + ",".join(str(v) for v in cm[i]) + "\n")


def write_confusion_png(cm, classes, path):
    """Grayscale heatmap PNG (stdlib only): value -> gray, black border."""
    n = len(classes)
    cell, pad, size = 40, 2, n * 42 + 4
    img = np.full((size, size), 255, dtype=np.uint8)
    for i in range(n):
        for j in range(n):
            v = cm[i][j]
            g = 255 if v == 0 else max(40, 255 - int(
                215 * np.log1p(v) / np.log1p(max(cm.max(), 1))))
            img[pad + i * 42:pad + i * 42 + cell,
                pad + j * 42:pad + j * 42 + cell] = g

    def chunk(tag, data):
        c = tag + data
        return struct.pack(">I", len(data)) + c + struct.pack(
            ">I", zlib.crc32(c) & 0xFFFFFFFF)

    ihdr = struct.pack(">IIBBBBB", size, size, 8, 0, 0, 0, 0)
    raw = b"".join(bytes([0]) + row.tobytes() for row in img)
    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", ihdr)
           + chunk(b"IDAT", zlib.compress(raw, 9))
           + chunk(b"IEND", b""))
    with open(path, "wb") as f:
        f.write(png)


# ---------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("input_dir")
    ap.add_argument("--out", default="out")
    ap.add_argument("--seed", type=int, default=7)
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)
    rows, loader_report = load_dataset(args.input_dir)
    clean_path = os.path.join(args.out, "clean_dataset.csv")
    write_clean_csv(rows, clean_path)
    with open(clean_path, "rb") as f:
        dataset_hash = hashlib.sha256(f.read()).hexdigest()[:16]

    signers = sorted({r["signer"] for r in rows})
    hands = sorted({r["hand"] for r in rows})
    if len(signers) < 2:
        print("NOTE: only one signer — cross-person generalization is "
              "untested (recorded in the report).")
    if not rows:
        raise SystemExit("loader produced no rows — nothing to train")

    hand_rows = {h: [r for r in rows if r["hand"] == h] for h in hands}
    train_hands = [h for h in hands
                   if len({r["session"] for r in hand_rows[h]})
                   >= MIN_SESSIONS_PER_HAND
                   and len({r["label"] for r in hand_rows[h]})
                   >= MIN_LABELS_PER_HAND]
    if not train_hands:
        # Fall back to the hand with the most rows (spec: train for the
        # hand that has data).
        train_hands = [max(hands, key=lambda h: len(hand_rows[h]))]
    canonical = max(train_hands, key=lambda h: len(hand_rows[h]))

    best = None  # (variant, model, mu, sigma, metrics, floor, floor_table)
    for hand in train_hands:
        hr = hand_rows[hand]
        sessions = split_sessions(hr, args.seed)
        if not all(sessions):
            # Train, val or test came out empty (too few sessions, or labels
            # recorded in only one): split whole TAKES instead. Takes from one
            # sitting share glove fit and posture, so held-out accuracy is
            # optimistic.
            hr = [dict(r, session=f"{r['session']}#take{r['take']}")
                  for r in hr]
            note = (f"hand {hand}: too few sessions per label - split by take; "
                    "held-out accuracy is OPTIMISTIC (same sitting)")
            loader_report.setdefault("split_notes", []).append(note)
            print("WARNING: " + note)
            sessions = split_sessions(hr, args.seed)
        for variant in ("A", "B"):
            X = feature_matrix(hr, variant)
            X_train = feature_matrix(rows_for(hr, sessions[0]), variant)
            X_val = feature_matrix(rows_for(hr, sessions[1]), variant)
            X_test = feature_matrix(rows_for(hr, sessions[2]), variant)
            classes = sorted({r["label"] for r in hr})
            model, mu, sigma = train_mlp(
                X_train,
                [r["label"] for r in rows_for(hr, sessions[0])],
                classes,
                X_val,
                [r["label"] for r in rows_for(hr, sessions[1])],
                seed=args.seed,
                input_has_roll_pitch=(variant == "B"))
            metrics = evaluate(model, (X_test - mu) / sigma,
                               rows_for(hr, sessions[2]))
            floor, floor_table = confidence_floor(
                model, (X_test - mu) / sigma, rows_for(hr, sessions[2]))
            candidate = (hand, variant, model, mu, sigma, metrics, floor,
                         floor_table)
            if best is None or metrics["accuracy"] > best[5]["accuracy"]:
                best = candidate

    hand, variant, model, mu, sigma, metrics, floor, floor_table = best
    trained_on = {
        "dataset_hash": dataset_hash,
        "session_ids": sorted({r["session"] for r in rows}),
        "calibration_ids": sorted({r["calibration_id"] for r in rows}),
        "signers": signers,
        "row_counts": {h: len(hand_rows[h]) for h in hands},
        "hands_trained": train_hands,
        "variant": variant,
        "loso": {},
    }

    # Leave-one-signer-out (report only; >= 2 signers).
    if len(signers) >= 2:
        loso = {}
        for left_out in signers:
            tr = [r for r in hand_rows[hand] if r["signer"] != left_out]
            seen = {r["label"] for r in tr}
            # Only labels the other signers also recorded can be scored.
            te = [r for r in hand_rows[hand]
                  if r["signer"] == left_out and r["label"] in seen]
            if not tr or not te:
                continue
            Xt = feature_matrix(tr, variant)
            Xe = feature_matrix(te, variant)
            m2, mu_l, sg_l = train_mlp(
                Xt, [r["label"] for r in tr],
                sorted({r["label"] for r in tr}),
                Xe, [r["label"] for r in te],
                seed=args.seed,
                input_has_roll_pitch=(variant == "B"))
            loso[left_out] = evaluate(m2, (Xe - mu_l) / sg_l, te)[
                "accuracy"]
        trained_on["loso"] = loso

    export_weights(model, mu, sigma,
                   os.path.join(args.out, "weights.json"), variant)
    motion = motion_gates(hand_rows[canonical])
    loader_report["motion_gates_pitch_deg"] = motion
    export_labels(os.path.join(args.out, "labels.json"),
                  canonical, variant, model.classes, floor, metrics,
                  trained_on, motion)
    write_confusion_csv(metrics["confusion"], metrics["classes"],
                        os.path.join(args.out, "confusion_matrix.csv"))
    write_confusion_png(metrics["confusion"], metrics["classes"],
                        os.path.join(args.out, "confusion_matrix.png"))

    report = _report_text(args, loader_report, hands, train_hands,
                          canonical, variant, metrics, floor, floor_table,
                          trained_on, signers)
    with open(os.path.join(args.out, "report.md"), "w",
              encoding="utf-8") as f:
        f.write(report)
    with open(os.path.join(args.out, "MODEL_CARD.md"), "w",
              encoding="utf-8") as f:
        f.write(report)
    print(report)

    # TFLite export (requires tensorflow; degrades loudly when absent).
    try:
        import export_tflite
        export_tflite.export(args.out, variant=variant,
                             weights_path=os.path.join(
                                 args.out, "weights.json"),
                             labels_path=os.path.join(
                                 args.out, "labels.json"),
                             clean_csv=clean_path,
                             representative_rows=20)
    except ImportError as e:
        print(f"TFLite export skipped: {e} "
              f"(pip install tensorflow to produce .tflite) — "
              f"weights.json remains the C4 fallback source.")


def _report_text(args, loader_report, hands, train_hands, canonical,
                 variant, metrics, floor, floor_table, trained_on,
                 signers):
    lines = ["# Training report — talkhimik letters (C3)", "",
             f"dataset: {args.input_dir}",
             f"hands in data: {hands} · hands trained: {train_hands}",
             f"canonical export hand: {canonical} · variant: {variant}",
             f"signers: {len(signers)}"]
    if len(signers) < 2:
        lines.append("**Cross-person generalization is UNTESTED** — only "
                     "one signer in the dataset.")
    else:
        lines.append("leave-one-signer-out accuracy: " + ", ".join(
            f"{s}={v:.3f}" for s, v in trained_on["loso"].items()))
    lines += ["", "## Loader", json.dumps(loader_report, indent=2), "",
              "## Evaluation (held-out test sessions)",
              f"overall accuracy: {metrics['accuracy']}",
              f"macro P/R/F1: {metrics['macro']}", "",
              "| class | precision | recall | f1 |", "|---|---|---|---|"]
    for c, m in metrics["per_class"].items():
        lines.append(f"| {c} | {m['precision']} | {m['recall']} | "
                     f"{m['f1']} |")
    lines += ["", "## Most confusable pairs",
              *(f"- {a} → {b}: {n}" for a, b, n in
                metrics["confusables"]), "",
              "## Confidence floor (held-out precision >= 95%)",
              f"floor: {floor if floor is not None else 'unreachable'}"
              f"{' (no threshold reaches 95% precision)' if floor is None else ''}",
              "",
              "| threshold | coverage % | precision |",
              "|---|---|---|"]
    lines += [f"| {t['threshold']} | {t['coverage_pct']} | "
              f"{t['precision']} |" for t in floor_table]
    return "\n".join(lines) + "\n"


if __name__ == "__main__":
    main()
