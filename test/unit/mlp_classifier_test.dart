import 'package:flutter_test/flutter_test.dart';
import 'package:talkhimik_app/domain/classifier/hand_frame.dart';
import 'package:talkhimik_app/domain/classifier/mlp_classifier.dart';
import 'package:talkhimik_app/domain/classifier/model_bundle.dart';
import 'package:talkhimik_app/domain/models/telemetry_packet.dart';

/// Golden vectors produced by the Python pipeline (numpy, seed 42):
/// a 5->4->3 MLP with normalization baked into layer 1. The Dart engine
/// must reproduce numpy's softmax outputs within 1e-4 on RAW degrees —
/// the same math the exported TFLite graph would compute.
const goldenWeightsJson = '''
{
  "format": "mlp-weights-v1", "variant": "A",
  "input_order": ["ang_thumb","ang_pointer","ang_middle","ang_ring",
    "ang_pinky"],
  "classes": ["A", "D", "_rest"],
  "layers": [
    {"weights": [
      [0.02236841769704142, -0.004990554496341731, 0.029279397553543828,
       0.016115032091141467],
      [-0.03681697865697291, 0.04314933599157954, 0.023691074868845387,
       0.025952280798233123],
      [-0.02760399521945902, -0.003682701097655026, -0.009590270133018578,
       0.03167746856859477],
      [0.009788781555051612, 0.021961146140862465, -0.0038501760988783515,
       -0.01855905425601716],
      [0.005571036496137154, -0.04451771488132685, 0.03343871646716087,
       0.013437941464133685]],
     "bias": [1.0310847053684304, -0.9365036974344821, -2.2853144507574337,
       -2.3749785040292957]},
    {"weights": [
      [0.5154660740717241, -0.5654192439263332, -0.06162072729953516],
      [-0.8447112861494601, -0.6401314738928846, 0.3389408003083809],
      [0.45321144720624007, 0.8656598142537582, -0.3225087686127691],
      [-0.2398620157667266, -0.05637168368425183, -0.5749873146296428]],
     "bias": [-0.07401569893290567, -0.004859014754813248,
       -0.05461813018982318]}
  ]
}
''';

const goldenLabelsJson = '''
{
  "version": 1, "hand": "L", "rest_class": "_rest",
  "input_spec": {"order": ["ang_thumb","ang_pointer","ang_middle",
    "ang_ring","ang_pinky"], "units": 5, "variant": "A"},
  "classes": [
    {"index": 0, "label": "A", "word_id": 1},
    {"index": 1, "label": "D", "word_id": 4},
    {"index": 2, "label": "_rest", "word_id": 0}
  ],
  "confidence_floor": 0.5, "floor_precision_95": true,
  "trained_on": {"dataset_hash": "golden0001", "signers": ["P-001"]}
}
''';

/// Two-hand test model: 'Salamat' scores with the LEFT glove's bend,
/// '_rest' otherwise (right glove ignored). 14 inputs, one dense layer.
ModelBundle twoHandBundle() {
  const order = [
    'L_ang_thumb', 'L_ang_pointer', 'L_ang_middle', 'L_ang_ring',
    'L_ang_pinky', 'L_roll', 'L_pitch',
    'R_ang_thumb', 'R_ang_pointer', 'R_ang_middle', 'R_ang_ring',
    'R_ang_pinky', 'R_roll', 'R_pitch',
  ];
  final orderJson = order.map((o) => '"$o"').join(',');
  final rows = [
    for (final o in order)
      o.startsWith('L_ang') ? '[0.05,-0.05]' : '[0,0]',
  ].join(',');
  return ModelBundle.assemble('''
{"version": 1, "hand": "LR", "rest_class": "_rest",
 "input_spec": {"order": [$orderJson], "units": 14, "variant": "2"},
 "classes": [{"index": 0, "label": "Salamat", "word_id": 104},
             {"index": 1, "label": "_rest", "word_id": 0}],
 "confidence_floor": 0.8, "floor_precision_95": true,
 "trained_on": {"dataset_hash": "two00001"}}
''', '''
{"input_order": [$orderJson], "classes": ["Salamat", "_rest"],
 "layers": [{"weights": [$rows], "bias": [-8, 0]}]}
''')!;
}

HandFrame pose(List<double> angles) => HandFrame(
      hand: GloveHand.left,
      angles: angles,
      rollDeg: 0,
      pitchDeg: 0,
      yawDeg: 0,
      validMask: 0x1F,
      calibrationId: 3,
      uncalibratedFlag: false,
      timestamp: DateTime.now(),
    );

void main() {
  test('up_* inputs: roll +179 and -179 give the same features', () {
    final bundle = ModelBundle.assemble('''
{"version": 1, "hand": "L", "rest_class": "_rest",
 "input_spec": {"order": ["up_x", "up_y", "up_z"], "units": 3,
                "variant": "C"},
 "classes": [{"index": 0, "label": "A", "word_id": 1},
             {"index": 1, "label": "_rest", "word_id": 0}],
 "confidence_floor": 0.5, "floor_precision_95": true,
 "trained_on": {"dataset_hash": "up000001"}}
''', '''
{"input_order": ["up_x", "up_y", "up_z"], "classes": ["A", "_rest"],
 "layers": [{"weights": [[0, 0], [5, 0], [0, 0]], "bias": [0, 0]}]}
''')!;
    final c = DartMlpClassifier(bundle);
    HandFrame tilt(double roll) => HandFrame(
          hand: GloveHand.left,
          angles: const [0, 0, 0, 0, 0],
          rollDeg: roll,
          pitchDeg: 0,
          yawDeg: 0,
          validMask: 0x1F,
          calibrationId: 3,
          uncalibratedFlag: false,
          timestamp: DateTime.now(),
        );
    // up_y = sin(roll): +90 scores A, -90 scores REST; 179 ~ -179.
    expect(c.classifyFrame(tilt(90))!.label, 'A');
    expect(c.classifyFrame(tilt(-90))!.label, '_rest');
    expect(c.classifyFrame(tilt(179))!.confidence,
        closeTo(c.classifyFrame(tilt(-179))!.confidence, 0.05));
  });

  test('a two-hand model reads each glove from its own frame', () {
    final c = DartMlpClassifier(twoHandBundle());
    final fist = pose([50, 70, 70, 70, 70]);
    final flat = pose([5, 5, 5, 5, 5]);
    expect(c.classifyPair(fist, flat)!.label, 'Salamat');
    expect(c.classifyPair(flat, fist)!.label, '_rest'); // sides matter
    expect(c.classifyFrame(fist), isNull); // needs both gloves
  });

  final bundle = ModelBundle.assemble(goldenLabelsJson, goldenWeightsJson)!;
  final classifier = DartMlpClassifier(bundle);

  test('reproduces numpy golden outputs within 1e-4 on raw degrees', () {
    final cases = <(List<double>, List<double>)>[
      ([55, 70, 70, 70, 70],
          [0.18674484318360188, 0.7988518406023487, 0.01440331621404926]),
      ([60, 12, 72, 72, 72],
          [0.548655713479509, 0.3594801156123291, 0.09186417090816176]),
      ([10, 45, 10, 10, 10],
          [0.21977148922283013, 0.2713751216059959, 0.508853389171174]),
    ];
    for (final (input, expected) in cases) {
      final probs = classifier.probabilityVector(pose(input))!;
      expect(probs.length, 3);
      for (var i = 0; i < 3; i++) {
        expect(probs[i], closeTo(expected[i], 1e-4),
            reason: 'input $input class index $i');
      }
    }
  });

  test('classifyFrame returns the argmax with a sorted top3', () {
    final pred = classifier.classifyFrame(pose([55, 70, 70, 70, 70]))!;
    expect(pred.label, 'D'); // numpy argmax for the FIST-ish input
    expect(pred.confidence, closeTo(0.7988518406023487, 1e-4));
    expect(pred.top3, ['D', 'A', '_rest']); // sorted by confidence
    expect(pred.source, 'phone-tflite');
  });

  test('metadata: tflite source, mlp model version, floor and REST', () {
    expect(classifier.source, 'phone-tflite');
    expect(classifier.modelVersion, 'mlp-golden00');
    expect(classifier.restLabel, '_rest');
    expect(classifier.confidenceFloor, 0.5);
  });

  test('an unknown input field refuses instead of guessing', () {
    final weirdLabels = goldenLabelsJson.replaceAll('"ang_ring"', '"ang_z"');
    final weirdBundle =
        ModelBundle.assemble(weirdLabels, goldenWeightsJson)!;
    final weird = DartMlpClassifier(weirdBundle);
    expect(weird.probabilityVector(pose([55, 70, 70, 70, 70])), isNull);
    expect(weird.classifyFrame(pose([55, 70, 70, 70, 70])), isNull);
  });
}
