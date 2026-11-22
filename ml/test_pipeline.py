"""End-to-end pipeline verification (C3.7) on a synthetic dataset —
no real data, no pytest: `python test_pipeline.py` prints PASS or raises.

Covers:
  * loader validation (missing sidecar, missing finger columns, bad
    quality rows, low-take label drop, J/Z skip)
  * grouped split has no take/session leakage
  * training both variants converges on the synthetic clusters
  * exports load back and reproduce predictions within tolerance
"""

import json
import os
import re
import shutil
import sys
import tempfile

import numpy as np

import load_dataset
import synth
import train
from train import (INPUT_A, MLP, REST_LABEL, confidence_floor,
                   evaluate, export_labels, export_weights,
                   feature_matrix, motion_gates, motion_paths,
                   moving_labels, split_sessions,
                   train_mlp)


def _reload_model(weights_path):
    payload = json.load(open(weights_path, encoding="utf-8"))
    layers = [(np.array(l["weights"]), np.array(l["bias"]))
              for l in payload["layers"]]
    return MLP(layers, payload["classes"])


def main():
    tmp = tempfile.mkdtemp(prefix="talkhimik_pipeline_")
    try:
        data_dir = os.path.join(tmp, "data")
        out_dir = os.path.join(tmp, "out")
        synth.generate(data_dir, seed=7, sessions_per_label=2,
                       takes_per_session=2, hands=("L", "R"),
                       bad_row_every=17)

        # --- loader validation cases ---------------------------------
        rows, report = load_dataset.load_dataset(data_dir)
        assert report["files_seen"] >= len(synth.CLUSTERS) * 2
        assert report["bad_quality_rows_dropped"] > 0, "bad rows survive"
        assert report["missing_sidecar"] == []
        labels = {r["label"] for r in rows}
        assert "A" in labels and REST_LABEL in labels
        assert "Z" not in labels  # skipped (J is kept: motion-gated)

        # --- motion gate: midway between still takes and J's motion ----
        def take(label, t, pitches):
            return [{"label": label, "session": "S", "take": t,
                     "roll": 0, "pitch": p} for p in pitches]
        gate_rows = (take("A", 1, [0, 2, 4]) + take("B", 2, [10, 16])
                     + take("J", 3, [0, 40, 70]) + take("J", 4, [5, 90])
                     + take("J", 5, [7]))  # 1-row take: not measurable
        gates = motion_gates(gate_rows)
        assert gates == {"J": 37.0}, gates  # (p95 still 4 + min J 70) / 2
        # any label that moves is detected, gets its own gate and paths, and
        # does not raise J's gate; a fidgety REST never counts as moving
        words = (gate_rows + take("Salamat", 6, [30, 10, -30])
                 + take("Salamat", 7, [30, 30, 30])  # held still: no path
                 + take("Salamat", 8, [40, 0, -20])
                 + take(REST_LABEL, 9, [0, 40, 80]))
        assert moving_labels(words) == {"J", "Salamat"}
        assert motion_gates(gate_rows + take("Salamat", 6, [30, 10, -30])
                            ) == {"J": 37.0, "Salamat": 32.0}
        paths = motion_paths(words)
        assert sorted(paths) == ["J", "Salamat"]
        assert len(paths["Salamat"]) == 2
        first = paths["Salamat"][0]
        assert first["tol_deg"] == 24.0  # 0.4 x 60 deg
        assert len(first["points"]) == 5
        assert np.allclose(first["points"][0], [0.5, 0, 0.866], atol=1e-3)
        # the score follows the app: the movement speaks, its reverse not
        def moves(label, t, pitches):
            return [dict(r, **{f"ang_{x}": 0.0 for x in synth.FINGERS})
                    for r in take(label, t, pitches)]
        sal = lambda X: np.tile([0.1, 0.9], (len(X), 1))
        assert train.score_wrong_moves(
            moves("_wrong_Salamat", 1, [30, 20, 5, -10, -30])
            + moves("_wrong_Salamat", 2, [-30, -10, 5, 20, 30])
            + moves("_random", 3, [0, 0, 0]),
            sal, ["A", "Salamat"], "A", 0.5, {}, paths
        ) == {"_random": {"takes": 1, "same_word": 0, "any_word": 0},
              "_wrong_Salamat": {"takes": 2, "same_word": 1, "any_word": 1}}
        assert motion_gates(take("A", 1, [0, 3])) == {}
        assert report["low_take_labels_dropped"] == {}

        # CSV without its sidecar -> excluded + reported
        victim = next(f for f in os.listdir(data_dir)
                      if f.endswith("_sidecar.json"))
        os.remove(os.path.join(data_dir, victim))
        _, rep2 = load_dataset.load_dataset(data_dir)
        assert rep2["missing_sidecar"], "missing sidecar not reported"
        # restore
        synth.generate(data_dir, seed=7, sessions_per_label=2,
                       takes_per_session=2, hands=("L", "R"),
                       bad_row_every=17)

        # session with a missing ang column -> excluded + reported
        broken = os.path.join(data_dir, "talkhimik_L_S-broken_cal3.csv")
        with open(broken, "w", encoding="utf-8") as f:
            f.write("timestamp_ms,session_id,signer_id,hand,"
                    "calibration_id,label,take_id,raw_thumb,ohm_thumb,"
                    "ang_thumb,roll,pitch,yaw,quality_flag\n"
                    "1000,S-broken,P-001,L,3,A,1,500,10000.0,50.0,"
                    "0.0,0.0,0.0,31\n")
        with open(broken.replace(".csv", "_sidecar.json"), "w") as f:
            json.dump({"session_id": "S-broken", "signer_id": "P-001",
                       "hand": "L", "calibration_id": 3}, f)
        _, rep3 = load_dataset.load_dataset(data_dir)
        assert rep3["invalid_finger_sessions"], "invalid-finger session kept"

        # low-take label -> dropped + reported
        low = os.path.join(data_dir, "talkhimik_L_S-low_cal3.csv")
        with open(low, "w", encoding="utf-8") as f:
            f.write("timestamp_ms,session_id,signer_id,hand,"
                    "calibration_id,label,take_id,"
                    + ",".join(f"raw_{x}" for x in synth.FINGERS) + ","
                    + ",".join(f"ohm_{x}" for x in synth.FINGERS) + ","
                    + ",".join(f"ang_{x}" for x in synth.FINGERS)
                    + ",roll,pitch,yaw,quality_flag\n")
            for i in range(10):
                f.write(f"{1000+i*200},S-low,P-001,L,3,Q,1,"
                        f"{','.join(['500']*5)},{','.join(['10000.0']*5)},"
                        f"{','.join(['50.0']*5)},0.0,0.0,0.0,31\n")
        with open(low.replace(".csv", "_sidecar.json"), "w") as f:
            json.dump({"session_id": "S-low", "signer_id": "P-001",
                       "hand": "L", "calibration_id": 3}, f)
        _, rep4 = load_dataset.load_dataset(data_dir)
        assert "Q" in rep4["low_take_labels_dropped"], "low-take label kept"

        # --- grouped split: no leakage --------------------------------
        left = [r for r in rows if r["hand"] == "L"]
        tr, va, te = split_sessions(left, seed=7)
        assert not (tr & va) and not (tr & te) and not (va & te)
        label_sessions = {}
        for r in left:
            label_sessions.setdefault(r["label"], set()).add(r["session"])
        for l, ss in label_sessions.items():
            assert ss & tr, f"label {l} has no train sessions"

        # --- a label recorded in only one of 3 sessions must not crash ---
        # (the session split leaves test empty -> whole takes are split)
        sparse = os.path.join(tmp, "sparse")
        os.makedirs(sparse)
        rng = np.random.default_rng(7)
        for name, labels_in in (("S-1", ("A", "B")), ("S-2", ("A", "B")),
                                ("S-3", ("A", "Salamat"))):
            lines = [",".join(synth._header())]
            for li, label in enumerate(labels_in):
                center = synth.CLUSTERS.get(label, synth.CLUSTERS["V"])
                for t in range(1, 11):
                    take_rows = np.clip(rng.normal(center, 3, (3, 5)), 0, 90)
                    lines += synth._csv_lines(
                        name, "P-001", "L", 3, label, li * 10 + t,
                        take_rows, np.zeros((3, 2)))
            base = os.path.join(sparse, name)
            with open(base + ".csv", "w", encoding="utf-8") as f:
                f.write("\n".join(lines) + "\n")
            with open(base + "_sidecar.json", "w", encoding="utf-8") as f:
                json.dump(synth._sidecar(name, "P-001", "L", 3,
                                         len(lines) - 1), f)
        # wrong moves are scored, never trained (even under MIN_TAKES)
        with open(os.path.join(sparse, "S-3.csv"), "a",
                  encoding="utf-8") as f:
            f.write("\n".join(synth._csv_lines(
                "S-3", "P-001", "L", 3, "_wrong_A", 99,
                np.tile(synth.CLUSTERS["A"], (3, 1)), np.zeros((3, 2))))
                + "\n")
        sparse_out = os.path.join(tmp, "sparse_out")
        argv, sys.argv = sys.argv, ["train.py", sparse, "--out", sparse_out]
        try:
            train.main()
        finally:
            sys.argv = argv
        sparse_labels = json.load(open(
            os.path.join(sparse_out, "labels.json"), encoding="utf-8"))
        ids = {c["label"]: c["word_id"] for c in sparse_labels["classes"]}
        assert ids == {"A": 1, "B": 2, "Salamat": 104}, ids
        sparse_report = open(os.path.join(sparse_out, "report.md"),
                             encoding="utf-8").read()
        assert "| _wrong_A | 1 | 1 | 1 |" in sparse_report  # held like an A

        # --- word ids mirror the app vocabulary -----------------------
        vocab = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                             "..", "lib", "domain", "vocab",
                             "fsl_vocabulary.dart")
        app_ids = {name: int(i) for i, name in re.findall(
            r"wordId: (\d+), filipino: '([^']*)'",
            open(vocab, encoding="utf-8").read())}
        assert train.FSL_WORD_IDS == app_ids

        # --- train + evaluate both variants ---------------------------
        results = {}
        for variant in ("A", "B"):
            X = feature_matrix(left, variant)
            Xtr = feature_matrix(
                [r for r in left if r["session"] in tr], variant)
            Xva = feature_matrix(
                [r for r in left if r["session"] in va], variant)
            Xte = feature_matrix(
                [r for r in left if r["session"] in te], variant)
            classes = sorted({r["label"] for r in left})
            model, mu, sigma = train_mlp(
                Xtr,
                [r["label"] for r in left if r["session"] in tr],
                classes,
                Xva,
                [r["label"] for r in left if r["session"] in va],
                seed=7, input_has_roll_pitch=(variant == "B"))
            metrics = evaluate(model, (Xte - mu) / sigma,
                               [r for r in left if r["session"] in te])
            floor, table = confidence_floor(
                model, (Xte - mu) / sigma,
                [r for r in left if r["session"] in te])
            results[variant] = (model, mu, sigma, metrics, floor, table)
            print(f"variant {variant}: acc={metrics['accuracy']} "
                  f"floor={floor}")
            assert metrics["accuracy"] > 0.85, (
                f"variant {variant} failed to learn the synthetic "
                f"clusters: {metrics['accuracy']}")

        best_var = max(results, key=lambda v: results[v][3]["accuracy"])
        model, mu, sigma, metrics, floor, table = results[best_var]
        os.makedirs(out_dir, exist_ok=True)

        # --- export loads back and reproduces predictions -------------
        export_weights(model, mu, sigma,
                       os.path.join(out_dir, "weights.json"), best_var)
        payload = export_labels(
            os.path.join(out_dir, "labels.json"), "L", best_var,
            model.classes, floor, metrics,
            {"dataset_hash": "synthetic-test",
             "session_ids": sorted(tr | va | te),
             "calibration_ids": [3], "signers": ["P-001", "P-002"],
             "row_counts": {"L": len(left)}, "hands_trained": ["L"],
             "variant": best_var, "loso": {}})

        reloaded = _reload_model(os.path.join(out_dir, "weights.json"))
        Xte_raw = feature_matrix(
            [r for r in left if r["session"] in te], best_var)
        orig = model.predict_proba((Xte_raw - mu) / sigma)
        # reloaded weights are baked: raw degrees in, same numbers out.
        baked = reloaded.predict_proba(Xte_raw)
        assert np.allclose(orig, baked, atol=1e-6), (
            f"max diff {np.abs(orig - baked).max()}")

        # labels.json contract for C4
        spec = payload["input_spec"]
        assert spec["variant"] == best_var
        assert len(spec["order"]) == spec["units"]
        word_ids = {c["label"]: c["word_id"] for c in payload["classes"]}
        assert word_ids.get("A") == 1 and word_ids.get("D") == 4
        assert word_ids.get(REST_LABEL) == 0
        assert payload["confidence_floor"] is not None
        assert len(INPUT_A) == 5
        print(f"export load-back OK (variant {best_var}, "
              f"{len(model.classes)} classes)")
        print("ALL PIPELINE TESTS PASSED")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
