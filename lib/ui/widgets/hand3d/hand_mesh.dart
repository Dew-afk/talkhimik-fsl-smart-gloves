import 'dart:math' as math;

import 'hand_orientation.dart';

const _deg = math.pi / 180;

/// How one flex reading (0–90°) spreads over a finger's three joints
/// (MCP, PIP, DIP). PIP leads and DIP lags in a natural curl; the glove has
/// one sensor per finger, so the split is fixed.
const fingerJointRatios = [1.0, 1.1, 0.7];

/// Anatomical joint limits (degrees) for MCP / PIP / DIP.
const fingerJointLimits = [90.0, 100.0, 70.0];

/// Thumb: CMC barely moves, MCP and IP do most of the curl.
const thumbJointRatios = [0.3, 0.6, 0.8];
const thumbJointLimits = [30.0, 60.0, 80.0];

/// Rig for one digit in the RIGHT-hand body frame (palm center = origin,
/// units ≈ palm length).
class _Digit {
  const _Digit(this.base, this.frame, this.lengths, this.radii);

  final Vec3 base;
  final Quat frame;
  final List<double> lengths; // 3 segments, base → tip
  final List<double> radii; // 4 joint radii, base → tip
}

final _digits = <_Digit>[
  // Thumb: anchored at the CMC on the radial side, turned forward-out and
  // rolled so its flexion axis curls it across the palm toward the pinky.
  _Digit(
    const Vec3(-0.18, 0.36, -0.06),
    Quat.axisAngle(Vec3.unitZ, 50 * _deg) *
        Quat.axisAngle(Vec3.unitY, 18 * _deg) *
        Quat.axisAngle(Vec3.unitX, -55 * _deg),
    const [0.36, 0.30, 0.25],
    const [0.13, 0.11, 0.095, 0.08],
  ),
  // Pointer, middle, ring, pinky: slight splay about Z.
  _Digit(const Vec3(0.50, 0.30, 0), Quat.axisAngle(Vec3.unitZ, 8 * _deg),
      const [0.44, 0.26, 0.19], const [0.095, 0.085, 0.075, 0.065]),
  _Digit(const Vec3(0.54, 0.10, 0), Quat.identity, const [0.49, 0.30, 0.21],
      const [0.10, 0.088, 0.078, 0.067]),
  _Digit(const Vec3(0.51, -0.10, 0), Quat.axisAngle(Vec3.unitZ, -6 * _deg),
      const [0.46, 0.28, 0.20], const [0.095, 0.083, 0.073, 0.063]),
  _Digit(const Vec3(0.44, -0.29, 0), Quat.axisAngle(Vec3.unitZ, -14 * _deg),
      const [0.36, 0.21, 0.18], const [0.08, 0.07, 0.062, 0.055]),
];

/// Palm + wrist profile along X: (x, half-width, half-thickness).
const _palmStations = [
  (-0.98, 0.0, 0.0),
  (-0.95, 0.20, 0.10),
  (-0.88, 0.27, 0.15),
  (-0.65, 0.30, 0.16),
  (-0.42, 0.38, 0.16),
  (-0.20, 0.43, 0.16),
  (0.15, 0.45, 0.15),
  (0.42, 0.44, 0.13),
  (0.55, 0.38, 0.11),
  (0.62, 0.25, 0.08),
  (0.65, 0.0, 0.0),
];

/// Every vertex stays within this distance of the origin (fit-to-canvas).
const handBoundingRadius = 1.65;

/// Triangle part ids: [palmPart] for palm/wrist, 0..4 for the fingers.
const palmPart = -1;

/// A posed hand in the BODY frame. Triangles wind counter-clockwise seen
/// from outside, so the renderer can cull back faces.
class HandMesh {
  HandMesh._(this.vertices, this.indices, this.parts, this.tips, this.bases);

  final List<Vec3> vertices;

  /// Three vertex indices per triangle.
  final List<int> indices;

  /// Part id per triangle ([palmPart] or a finger index).
  final List<int> parts;

  /// Fingertip and finger-base (MCP) points, thumb..pinky.
  final List<Vec3> tips;
  final List<Vec3> bases;

  int get triangleCount => parts.length;

  /// Poses the rig from flex angles (thumb..pinky, 0–90°). The left hand is
  /// the right hand mirrored across Y — the rotation math is shared.
  static HandMesh build(List<double> fingerDeg,
      {required bool left, bool compact = false}) {
    final b = _Builder(compact ? 6 : 10, compact ? 10 : 16,
        compact ? const [0.0, 45.0, 90.0] : const [0.0, 30.0, 60.0, 90.0]);
    b.lathe(Vec3.zero, Quat.identity, _palmStations, palmPart, b.palmSides,
        0.7);

    final tips = <Vec3>[];
    final bases = <Vec3>[];
    for (var i = 0; i < 5; i++) {
      final d = _digits[i];
      final ratios = i == 0 ? thumbJointRatios : fingerJointRatios;
      final limits = i == 0 ? thumbJointLimits : fingerJointLimits;
      final flex = fingerDeg[i].clamp(0.0, 90.0);
      var p = d.base;
      var frame = d.frame;
      bases.add(p);
      for (var j = 0; j < 3; j++) {
        final joint = math.min(flex * ratios[j], limits[j]) * _deg;
        // +rotation about local Y swings the tip toward −Z (the palm).
        frame = frame * Quat.axisAngle(Vec3.unitY, joint);
        b.capsule(p, frame, d.lengths[j], d.radii[j], d.radii[j + 1], i);
        p = p + frame.rotate(Vec3.unitX) * d.lengths[j];
      }
      tips.add(p + frame.rotate(Vec3.unitX) * d.radii[3]);
    }

    if (!left) {
      return HandMesh._(b.vertices, b.indices, b.parts, tips, bases);
    }
    Vec3 m(Vec3 v) => Vec3(v.x, -v.y, v.z);
    final idx = List<int>.of(b.indices);
    for (var t = 0; t < idx.length; t += 3) {
      // A mirror flips handedness: swap two corners to keep outward winding.
      final s = idx[t + 1];
      idx[t + 1] = idx[t + 2];
      idx[t + 2] = s;
    }
    return HandMesh._([for (final v in b.vertices) m(v)], idx, b.parts,
        [for (final v in tips) m(v)], [for (final v in bases) m(v)]);
  }
}

class _Builder {
  _Builder(this.sides, this.palmSides, this.capAngles);

  final int sides;
  final int palmSides;

  /// Polar angles (deg) for the rounded segment ends.
  final List<double> capAngles;

  final vertices = <Vec3>[];
  final indices = <int>[];
  final parts = <int>[];

  /// Rounded, tapered segment from [origin] along the frame's local X.
  void capsule(Vec3 origin, Quat frame, double length, double rA, double rB,
      int part) {
    final st = <(double, double, double)>[
      for (final a in capAngles)
        (-rA * math.cos(a * _deg), rA * math.sin(a * _deg),
            rA * math.sin(a * _deg)),
      for (final a in capAngles.reversed)
        (length + rB * math.cos(a * _deg), rB * math.sin(a * _deg),
            rB * math.sin(a * _deg)),
    ];
    lathe(origin, frame, st, part, sides, 1);
  }

  /// Rings of elliptic (superellipse [e]) cross-section at each station
  /// along local X, stitched into quads.
  void lathe(Vec3 origin, Quat frame, List<(double, double, double)> stations,
      int part, int n, double e) {
    final ax = frame.rotate(Vec3.unitX);
    final ay = frame.rotate(Vec3.unitY);
    final az = frame.rotate(Vec3.unitZ);
    double se(double v) => v.sign * math.pow(v.abs(), e).toDouble();
    final start = vertices.length;
    for (final (x, ry, rz) in stations) {
      final c = origin + ax * x;
      for (var k = 0; k < n; k++) {
        final phi = 2 * math.pi * k / n;
        vertices.add(c +
            ay * (se(math.cos(phi)) * ry) +
            az * (se(math.sin(phi)) * rz));
      }
    }
    for (var i = 0; i < stations.length - 1; i++) {
      for (var k = 0; k < n; k++) {
        final a = start + i * n + k;
        final b = start + i * n + (k + 1) % n;
        final c = a + n;
        final d = b + n;
        // Ring tangent × axis points outward (see hand_orientation axes).
        indices.addAll([a, b, c, b, d, c]);
        parts..add(part)..add(part);
      }
    }
  }
}
