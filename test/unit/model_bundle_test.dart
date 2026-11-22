import 'package:flutter_test/flutter_test.dart';
import 'package:talkhimik_app/domain/classifier/model_bundle.dart';
import 'package:talkhimik_app/domain/models/telemetry_packet.dart';

const labelsJson = '''
{
  "version": 1, "hand": "L", "rest_class": "_rest",
  "input_spec": {"order": ["ang_thumb","ang_pointer","ang_middle",
    "ang_ring","ang_pinky"], "units": 5, "variant": "A"},
  "classes": [
    {"index": 0, "label": "A", "word_id": 1},
    {"index": 1, "label": "D", "word_id": 4},
    {"index": 2, "label": "_rest", "word_id": 0}
  ],
  "confidence_floor": 0.7, "floor_precision_95": true,
  "trained_on": {"dataset_hash": "abc123", "signers": ["P-001"]}
}
''';

const weightsJson = '''
{
  "format": "mlp-weights-v1",
  "input_order": ["ang_thumb","ang_pointer","ang_middle","ang_ring",
    "ang_pinky"],
  "classes": ["A", "D", "_rest"],
  "layers": [
    {"weights": [[1, -1], [1, -1], [1, -1], [1, -1], [1, -1]],
     "bias": [0, 0]},
    {"weights": [[10, -10], [-10, 10]], "bias": [0, 0]}
  ]
}
''';

void main() {
  test('a valid pair assembles into a cross-checked bundle', () {
    final bundle = ModelBundle.assemble(labelsJson, weightsJson);
    expect(bundle, isNotNull);
    expect(bundle!.labels.classes.length, 3);
    expect(bundle.labels.classes[0].wordId, 1);
    expect(bundle.labels.classes[2].label, '_rest');
    expect(bundle.labels.confidenceFloor, 0.7);
    expect(bundle.labels.datasetHash, 'abc123');
    expect(bundle.labels.validFor(GloveHand.left), isTrue);
    expect(bundle.labels.validFor(GloveHand.right), isFalse);
  });

  test('corrupt labels.json yields null (never a partial model)', () {
    expect(ModelBundle.assemble('not json', weightsJson), isNull);
    expect(ModelBundle.assemble('{"hand": "L"}', weightsJson), isNull);
    expect(ModelBundle.assemble(labelsJson, '[]'), isNull);
  });

  test('labels and weights that disagree yield null', () {
    // Weights list one fewer class than labels.json.
    final fewerClasses = weightsJson.replaceAll(
        '"classes": ["A", "D", "_rest"]', '"classes": ["A", "D"]');
    expect(ModelBundle.assemble(labelsJson, fewerClasses), isNull);
    // Weights expect a shorter input vector than labels.json declares.
    final shorterInput = weightsJson.replaceAll(
        '"input_order": ["ang_thumb","ang_pointer","ang_middle","ang_ring",\n    "ang_pinky"]',
        '"input_order": ["ang_thumb"]');
    expect(ModelBundle.assemble(labelsJson, shorterInput), isNull);
  });

  test('trainedOnSummary is a one-line panel string', () {
    final spec = LabelsSpec.parse(labelsJson)!;
    expect(spec.trainedOnSummary, contains('abc123'));
    expect(spec.trainedOnSummary, contains('floor 0.7'));
  });

  test('motion_labels parse into per-letter pitch spans; absent = none', () {
    expect(LabelsSpec.parse(labelsJson)!.motionPitchSpan, isEmpty);
    final withMotion = labelsJson.replaceFirst('"rest_class": "_rest",',
        '"rest_class": "_rest", "motion_labels": '
        '{"J": {"pitch_span_deg": 35.5, "window_ms": 1500}},');
    expect(LabelsSpec.parse(withMotion)!.motionPitchSpan, {'J': 35.5});
    expect(LabelsSpec.parse(withMotion)!.motionPaths, isEmpty);
  });

  test('recorded movements parse; malformed ones are skipped', () {
    final spec = LabelsSpec.parse(labelsJson.replaceFirst(
        '"rest_class": "_rest",',
        '"rest_class": "_rest", "motion_labels": {'
            '"J": {"pitch_span_deg": 30, "paths": ['
            '{"tol_deg": 24, "points": [[0,0,1],[1,0,0]]},'
            '{"tol_deg": 24, "points": [[0,0,1],[1,0]]}, 7]},'
            '"K": {"pitch_span_deg": 20, "paths": []}},'))!;
    expect(spec.motionPaths.keys, ['J']);
    expect(spec.motionPaths['J']!.single.toleranceDeg, 24);
    expect(spec.motionPaths['J']!.single.points.last, [1, 0, 0]);
    expect(spec.motionPitchSpan, {'J': 30, 'K': 20});
  });
}
