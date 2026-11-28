import 'dart:math' as math;

import 'gesture_classifier.dart';
import 'hand_frame.dart';
import 'model_bundle.dart';
import 'prediction.dart';
import 'recognition_constants.dart';

/// The C4 model engine: a pure-Dart forward pass over the exported MLP
/// weights (dense → relu ×2 → softmax, normalization baked into layer 1 —
/// the phone passes raw degrees, no preprocessing).
///
/// This is the spec's fallback path, chosen as the primary engine because
/// it builds on every platform with zero native dependencies and matches
/// the TFLite graph's math exactly (unit-tested against numpy golden
/// vectors). A TFLite engine can slot into [GestureClassifier] later
/// without touching the controller.
class DartMlpClassifier implements GestureClassifier {
  DartMlpClassifier(this.bundle);

  final ModelBundle bundle;

  @override
  String get source => RecognitionConstants.tfliteSource;

  @override
  String get modelVersion {
    final hash = bundle.labels.datasetHash;
    final short = hash.length > 8 ? hash.substring(0, 8) : hash;
    return 'mlp-$short';
  }

  @override
  String? get restLabel => bundle.labels.restClass;

  @override
  double get confidenceFloor => bundle.labels.confidenceFloor;

  @override
  Prediction? classifyFrame(HandFrame frame) => _predict(_features(frame));

  /// Two-hand models (labels.json hand 'LR', inputs L_*/R_*): one
  /// prediction from both gloves' frames.
  Prediction? classifyPair(HandFrame left, HandFrame right) =>
      _predict(_features(right, left: left, right: right));

  Prediction? _predict(List<double>? features) {
    if (features == null) return null; // input spec demands an unknown field
    final probs = _forward(features);

    var best = 0;
    for (var i = 1; i < probs.length; i++) {
      if (probs[i] > probs[best]) best = i;
    }
    final order = List<int>.generate(probs.length, (i) => i)
      ..sort((a, b) => probs[b].compareTo(probs[a]));
    final classes = bundle.weights.classes;
    return Prediction(
      label: classes[best],
      confidence: probs[best],
      source: source,
      className: classes[best],
      top3: [for (final i in order.take(3)) classes[i]],
    );
  }

  /// Raw softmax over all classes (index order = weights classes); null
  /// when the input spec demands a field [HandFrame] cannot provide.
  /// Public for the parity tests and the debug panel.
  List<double>? probabilityVector(HandFrame frame) {
    final features = _features(frame);
    if (features == null) return null;
    return _forward(features);
  }

  /// Input vector per labels.json's input_spec order. L_/R_ names read the
  /// [left]/[right] frame (two-hand models); null when that frame is absent.
  List<double>? _features(HandFrame frame,
      {HandFrame? left, HandFrame? right}) {
    final out = <double>[];
    for (final raw in bundle.labels.inputOrder) {
      var f = frame;
      var name = raw;
      if (raw.startsWith('L_') || raw.startsWith('R_')) {
        final side = raw.startsWith('L_') ? left : right;
        if (side == null) return null;
        f = side;
        name = raw.substring(2);
      }
      switch (name) {
        case 'ang_thumb':
          out.add(f.angles[0]);
        case 'ang_pointer':
          out.add(f.angles[1]);
        case 'ang_middle':
          out.add(f.angles[2]);
        case 'ang_ring':
          out.add(f.angles[3]);
        case 'ang_pinky':
          out.add(f.angles[4]);
        case 'roll':
          out.add(f.rollDeg);
        case 'pitch':
          out.add(f.pitchDeg);
        // World-up in the hand frame (ml/train.py _up_path): no roll wrap.
        case 'up_x':
          out.add(math.sin(f.pitchDeg * math.pi / 180));
        case 'up_y':
          out.add(math.cos(f.pitchDeg * math.pi / 180) *
              math.sin(f.rollDeg * math.pi / 180));
        case 'up_z':
          out.add(math.cos(f.pitchDeg * math.pi / 180) *
              math.cos(f.rollDeg * math.pi / 180));
        default:
          return null;
      }
    }
    return out;
  }

  List<double> _forward(List<double> x) {
    var a = x;
    final layers = bundle.weights.layers;
    for (var i = 0; i < layers.length - 1; i++) {
      final (w, b) = layers[i];
      a = _relu(_matvec(w, a, b));
    }
    final (w, b) = layers.last;
    return _softmax(_matvec(w, a, b));
  }

  static List<double> _matvec(
      List<List<double>> w, List<double> x, List<double> b) {
    final out = List<double>.filled(w[0].length, 0);
    for (var i = 0; i < w.length; i++) {
      final wi = w[i];
      final xi = x[i];
      for (var j = 0; j < out.length; j++) {
        out[j] += wi[j] * xi;
      }
    }
    for (var j = 0; j < out.length; j++) {
      out[j] += b[j];
    }
    return out;
  }

  static List<double> _relu(List<double> z) => [
        for (final v in z) v > 0 ? v : 0.0,
      ];

  static List<double> _softmax(List<double> z) {
    var max = z[0];
    for (final v in z) {
      if (v > max) max = v;
    }
    var sum = 0.0;
    final e = List<double>.filled(z.length, 0);
    for (var i = 0; i < z.length; i++) {
      e[i] = math.exp(z[i] - max);
      sum += e[i];
    }
    return [for (final v in e) v / sum];
  }
}
