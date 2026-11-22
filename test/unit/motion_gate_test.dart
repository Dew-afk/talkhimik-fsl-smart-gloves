import 'package:flutter_test/flutter_test.dart';
import 'package:talkhimik_app/domain/classifier/model_bundle.dart';
import 'package:talkhimik_app/domain/classifier/motion_gate.dart';

void main() {
  final t0 = DateTime(2026);
  DateTime at(int ms) => t0.add(Duration(milliseconds: ms));
  const gates = {'J': 35.0};

  test('a motion letter needs the trained pitch change; still letters never',
      () {
    final g = MotionGate()
      ..add(at(0), 10)
      ..add(at(100), 12);
    expect(g.allows('J', gates), isFalse); // held still: 2 deg
    expect(g.allows('A', gates), isTrue);
    g.add(at(400), 60);
    expect(g.span, 50);
    expect(g.allows('J', gates), isTrue);
  });

  test('frames older than the window are forgotten', () {
    final g = MotionGate()
      ..add(at(0), 0)
      ..add(at(200), 80);
    expect(g.allows('J', gates), isTrue);
    g.add(at(2000), 80); // the 0-deg frame is now > 1.5 s old
    expect(g.allows('J', gates), isFalse);
  });

  group('recorded movements (fingertips +30 deg down to -30 deg)', () {
    const paths = {
      'Salamat': [
        MotionPath([
          [0.5, 0, 0.866],
          [0, 0, 1],
          [-0.5, 0, 0.866],
        ], 24),
      ],
    };
    // The pitch change alone would pass: paths take precedence.
    bool made(List<double> pitches, {int stepMs = 100}) {
      final g = MotionGate();
      for (var i = 0; i < pitches.length; i++) {
        g.add(at(i * stepMs), pitches[i]);
      }
      return g.allows('Salamat', const {'Salamat': 15}, paths);
    }

    test('the same movement passes', () {
      expect(made([30, 20, 0, -20, -30]), isTrue);
    });

    test('backwards, half-way, lower down or too slow does not', () {
      expect(made([-30, -20, 0, 20, 30]), isFalse);
      expect(made([30, 20, 0]), isFalse);
      expect(made([-10, -30, -50, -70]), isFalse);
      expect(made([30, 20, 0, -20, -30], stepMs: 700), isFalse);
    });

    test('a new movement is needed after reset', () {
      final g = MotionGate();
      for (final (i, p) in [30.0, 0.0, -30.0].indexed) {
        g.add(at(i * 100), p);
      }
      expect(g.allows('Salamat', const {}, paths), isTrue);
      g.reset();
      g.add(at(400), -30);
      expect(g.allows('Salamat', const {}, paths), isFalse);
    });

    test('the tilt direction counts, not only pitch', () {
      final g = MotionGate();
      for (final (i, p) in [30.0, 0.0, -30.0].indexed) {
        g.add(at(i * 100), p, rollDeg: 90);
      }
      expect(g.allows('Salamat', const {}, paths), isFalse);
    });
  });
}
