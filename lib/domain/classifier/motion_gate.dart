import 'dart:math' as math;

import 'model_bundle.dart';

/// Moving signs: the model knows only the handshape, so a moving label is
/// emitted only after the hand made one of its recorded movements
/// (labels.json `motion_labels`): the same tilt directions, in order.
/// Models without recorded movements fall back to a minimum pitch change.
/// Tilt only: height, sliding and yaw (drifts) are not measured.
class MotionGate {
  MotionGate({
    this.window = const Duration(milliseconds: 2000),
    this.spanWindow = const Duration(milliseconds: 1500),
  });

  /// How far back a movement may start.
  final Duration window;

  /// Look-back of the pitch-change fallback.
  final Duration spanWindow;

  final List<(DateTime, double, List<double>)> _frames = [];

  /// Records one frame and forgets frames older than [window].
  void add(DateTime at, double pitchDeg, {double rollDeg = 0}) {
    final p = pitchDeg * math.pi / 180, r = rollDeg * math.pi / 180;
    _frames.add((
      at,
      pitchDeg,
      [math.sin(p), math.cos(p) * math.sin(r), math.cos(p) * math.cos(r)],
    ));
    while (at.difference(_frames.first.$1) > window) {
      _frames.removeAt(0);
    }
  }

  /// Max − min pitch over [spanWindow] (0 with fewer than 2 frames).
  double get span {
    if (_frames.isEmpty) return 0;
    final now = _frames.last.$1;
    var lo = _frames.last.$2, hi = lo;
    for (final (at, p, _) in _frames) {
      if (now.difference(at) > spanWindow) continue;
      if (p < lo) lo = p;
      if (p > hi) hi = p;
    }
    return hi - lo;
  }

  /// Whether [label] may be emitted now: always for a still label; for a
  /// moving one only once its movement was made.
  bool allows(
    String label,
    Map<String, double> minSpanByLabel, [
    Map<String, List<MotionPath>> pathsByLabel = const {},
  ]) {
    final paths = pathsByLabel[label];
    if (paths != null) return paths.any(_followed);
    final min = minSpanByLabel[label];
    return min == null || span >= min;
  }

  bool _followed(MotionPath path) {
    final minCos = math.cos(path.toleranceDeg * math.pi / 180);
    var i = 0;
    for (final p in path.points) {
      while (i < _frames.length && _dot(_frames[i].$3, p) < minCos) {
        i++;
      }
      if (i == _frames.length) return false;
    }
    return true;
  }

  static double _dot(List<double> a, List<double> b) =>
      a[0] * b[0] + a[1] * b[1] + a[2] * b[2];

  void reset() => _frames.clear();
}
