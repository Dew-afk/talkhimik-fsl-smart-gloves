import 'dart:convert';

import '../models/telemetry_packet.dart';

/// One class row of labels.json (C3 export contract).
class ModelClass {
  const ModelClass(this.index, this.label, this.wordId);

  final int index;
  final String label;
  final int wordId;
}

/// One recorded movement: world-up directions (hand frame) to pass in order,
/// each within [toleranceDeg].
class MotionPath {
  const MotionPath(this.points, this.toleranceDeg);

  final List<List<double>> points;
  final double toleranceDeg;

  /// Null when [json] is not a usable path.
  static MotionPath? parse(Object? json) {
    if (json is! Map) return null;
    final tol = json['tol_deg'];
    final raw = json['points'];
    if (tol is! num || raw is! List || raw.length < 2) return null;
    final points = <List<double>>[];
    for (final p in raw) {
      if (p is! List || p.length != 3 || p.any((v) => v is! num)) return null;
      points.add([for (final v in p) (v as num).toDouble()]);
    }
    return MotionPath(points, tol.toDouble());
  }
}

/// Parsed labels.json — the model's metadata contract (C4).
class LabelsSpec {
  const LabelsSpec({
    required this.version,
    required this.hand,
    required this.variant,
    required this.inputOrder,
    required this.classes,
    required this.confidenceFloor,
    required this.floorPrecision95,
    required this.restClass,
    required this.datasetHash,
    this.motionPitchSpan = const {},
    this.motionPaths = const {},
  });

  final int version;
  final String hand; // 'L' | 'R'
  final String variant; // 'A' (angles) | 'B' (angles + roll/pitch)
  final List<String> inputOrder;
  final List<ModelClass> classes;
  final double confidenceFloor;
  final bool floorPrecision95;
  final String restClass;
  final String datasetHash;

  /// Motion letters (labels.json `motion_labels`): label → the pitch change
  /// in degrees required before it may be emitted (see MotionGate).
  final Map<String, double> motionPitchSpan;

  /// Moving labels → their recorded movements. Takes precedence over
  /// [motionPitchSpan]; absent in models trained before it existed.
  final Map<String, List<MotionPath>> motionPaths;

  /// One-line trained-on summary for the debug panel.
  String get trainedOnSummary =>
      'dataset $datasetHash · hand $hand · $variant · '
      '${classes.length} classes · floor $confidenceFloor';

  bool validFor(GloveHand hand) =>
      this.hand == (hand == GloveHand.left ? 'L' : 'R');

  /// Null when the JSON is not a valid labels.json.
  static LabelsSpec? parse(String json) {
    try {
      final root = jsonDecode(json);
      if (root is! Map<String, Object?>) return null;
      final spec = root['input_spec'];
      if (spec is! Map<String, Object?>) return null;
      final order = spec['order'];
      final classRows = root['classes'];
      if (order is! List || classRows is! List) return null;
      final classes = <ModelClass>[];
      for (final c in classRows) {
        if (c is! Map<String, Object?>) return null;
        classes.add(ModelClass(
          (c['index'] as num?)?.toInt() ?? classes.length,
          c['label'] as String? ?? '',
          (c['word_id'] as num?)?.toInt() ?? 0,
        ));
      }
      if (classes.isEmpty) return null;
      final trainedOn = root['trained_on'];
      final hash = trainedOn is Map<String, Object?>
          ? (trainedOn['dataset_hash'] as String? ?? 'unknown')
          : 'unknown';
      final motion = <String, double>{};
      final paths = <String, List<MotionPath>>{};
      final rawMotion = root['motion_labels'];
      if (rawMotion is Map<String, Object?>) {
        for (final e in rawMotion.entries) {
          final span = (e.value as Map?)?['pitch_span_deg'];
          if (span is num) motion[e.key] = span.toDouble();
          final rawPaths = (e.value as Map?)?['paths'];
          if (rawPaths is List) {
            final parsed =
                rawPaths.map(MotionPath.parse).whereType<MotionPath>().toList();
            if (parsed.isNotEmpty) paths[e.key] = parsed;
          }
        }
      }
      return LabelsSpec(
        version: (root['version'] as num?)?.toInt() ?? 1,
        hand: root['hand'] as String? ?? '',
        variant: spec['variant'] as String? ?? 'A',
        inputOrder: order.cast<String>(),
        classes: classes,
        confidenceFloor: (root['confidence_floor'] as num?)?.toDouble() ?? 0.95,
        floorPrecision95: root['floor_precision_95'] == true,
        restClass: root['rest_class'] as String? ?? '_rest',
        datasetHash: hash,
        motionPitchSpan: motion,
        motionPaths: paths,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Parsed weights.json — the baked (normalization folded into layer 1)
/// MLP the pure-Dart engine runs.
class ModelWeights {
  const ModelWeights({
    required this.layers,
    required this.classes,
    required this.inputOrder,
  });

  /// One entry per dense layer: (weights in×out, bias out).
  final List<(List<List<double>>, List<double>)> layers;
  final List<String> classes;
  final List<String> inputOrder;

  static ModelWeights? parse(String json) {
    try {
      final root = jsonDecode(json);
      if (root is! Map<String, Object?>) return null;
      final rawLayers = root['layers'];
      final classes = root['classes'];
      final order = root['input_order'];
      if (rawLayers is! List || classes is! List || order is! List) {
        return null;
      }
      final layers = <(List<List<double>>, List<double>)>[];
      for (final l in rawLayers) {
        if (l is! Map<String, Object?>) return null;
        final w = l['weights'];
        final b = l['bias'];
        if (w is! List || b is! List) return null;
        layers.add((
          [for (final row in w) (row as List).cast<num>().map(
              (n) => n.toDouble()).toList()],
          b.cast<num>().map((n) => n.toDouble()).toList(),
        ));
      }
      if (layers.isEmpty) return null;
      return ModelWeights(
        layers: layers,
        classes: classes.cast<String>(),
        inputOrder: order.cast<String>(),
      );
    } catch (_) {
      return null;
    }
  }

  /// The labels spec and the weights must describe the same model.
  bool compatibleWith(LabelsSpec spec) =>
      classes.length == spec.classes.length &&
      inputOrder.length == spec.inputOrder.length;
}

/// A loaded, cross-checked model: metadata + weights.
class ModelBundle {
  const ModelBundle({required this.labels, required this.weights});

  final LabelsSpec labels;
  final ModelWeights weights;

  /// Null when either file is missing/corrupt or the two disagree.
  static ModelBundle? assemble(String labelsJson, String weightsJson) {
    final labels = LabelsSpec.parse(labelsJson);
    final weights = ModelWeights.parse(weightsJson);
    if (labels == null || weights == null) return null;
    if (!weights.compatibleWith(labels)) return null;
    return ModelBundle(labels: labels, weights: weights);
  }
}
