import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:talkhimik_app/ui/widgets/hand3d/hand_mesh.dart';
import 'package:talkhimik_app/ui/widgets/hand3d/hand_orientation.dart';

void expectVec(Vec3 v, Vec3 e) {
  expect(v.x, closeTo(e.x, 1e-9));
  expect(v.y, closeTo(e.y, 1e-9));
  expect(v.z, closeTo(e.z, 1e-9));
}

Quat imu(double r, double p, double y) =>
    orientationFromImu(rollDeg: r, pitchDeg: p, yawDeg: y);

void main() {
  test('0/0/0 is identity: palm down, fingers forward', () {
    final q = imu(0, 0, 0);
    expectVec(q.rotate(Vec3.unitX), Vec3.unitX);
    expectVec(q.rotate(Vec3.unitZ), Vec3.unitZ);
  });

  test('reproduces the firmware roll/pitch formulas (imu.cpp)', () {
    for (final (r, p) in [(30.0, 20.0), (-120.0, -45.0), (170.0, 60.0)]) {
      final q = imu(r, p, 37);
      // World up expressed in the body frame = inverse rotation of +Z.
      final inv = Quat(q.w, -q.x, -q.y, -q.z);
      final u = inv.rotate(Vec3.unitZ);
      expect(math.atan2(u.y, u.z) * 180 / math.pi, closeTo(r, 1e-6));
      expect(
          math.atan2(u.x, math.sqrt(u.y * u.y + u.z * u.z)) * 180 / math.pi,
          closeTo(p, 1e-6));
    }
  });

  test('roll ±180 turns the palm up', () {
    for (final r in [180.0, -180.0]) {
      // The back of the hand (+Z body) now faces the floor.
      expectVec(imu(r, 0, 0).rotate(Vec3.unitZ), const Vec3(0, 0, -1));
    }
  });

  test('pitch +90 points the fingertips up', () {
    expectVec(imu(0, 90, 0).rotate(Vec3.unitX), Vec3.unitZ);
    expectVec(imu(0, -90, 0).rotate(Vec3.unitX), const Vec3(0, 0, -1));
  });

  test('slerp across roll 179 → −179 takes the 2° short arc', () {
    final a = imu(179, 0, 0);
    final b = imu(-179, 0, 0);
    expect(a.angleTo(b), closeTo(2 * math.pi / 180, 1e-9));
    final mid = a.slerpTo(b, 0.5);
    // Midpoint is palm-up (roll 180), not palm-down (roll 0).
    expectVec(mid.rotate(Vec3.unitZ), const Vec3(0, 0, -1));
  });

  test('no NaN or flip near pitch ±90', () {
    var q = imu(10, 80, 0);
    for (var p = 80.0; p <= 90; p += 0.5) {
      final roll = stableRoll(previousRoll: 10, roll: p > 85 ? -170 : 10,
          pitch: p);
      final next = imu(roll, p, 0);
      q = q.slerpTo(next, 0.35);
      expect(q.w.isNaN, isFalse);
      // A roll jump from noise would show as a big step between ticks.
      expect(q.angleTo(next), lessThan(10 * math.pi / 180));
    }
    expect(stableRoll(previousRoll: 10, roll: -170, pitch: 89), 10);
    expect(stableRoll(previousRoll: 10, roll: -170, pitch: 40), -170);
  });

  test('the left hand is the right hand mirrored across Y', () {
    const fingers = [20.0, 40.0, 60.0, 80.0, 90.0];
    final r = HandMesh.build(fingers, left: false);
    final l = HandMesh.build(fingers, left: true);
    expect(l.vertices.length, r.vertices.length);
    for (var i = 0; i < r.vertices.length; i++) {
      expect(l.vertices[i].x, r.vertices[i].x);
      expect(l.vertices[i].y, -r.vertices[i].y);
      expect(l.vertices[i].z, r.vertices[i].z);
    }
    // Right thumb sits on +Y (left when palm down), left thumb on −Y.
    expect(r.tips[0].y, greaterThan(0));
    expect(l.tips[0].y, lessThan(0));
  });

  test('flexing a finger curls its tip toward the palm side', () {
    final flat = HandMesh.build(const [0, 0, 0, 0, 0], left: false);
    final bent = HandMesh.build(const [0, 90, 0, 0, 0], left: false);
    // A full 90° reading closes a fist: the tip folds back toward the wrist
    // and tucks under the palm (below the knuckle plane).
    expect(bent.tips[1].z, lessThan(flat.tips[1].z - 0.1));
    expect(bent.tips[1].x, lessThan(flat.tips[1].x - 0.8));
    // Other fingers do not move.
    expectVec(bent.tips[2], flat.tips[2]);
  });

  test('triangle budget: ≤ 3k full, fewer compact', () {
    const f = [0.0, 0.0, 0.0, 0.0, 0.0];
    final full = HandMesh.build(f, left: false);
    final compact = HandMesh.build(f, left: false, compact: true);
    expect(full.triangleCount, lessThanOrEqualTo(3000));
    expect(compact.triangleCount, lessThan(full.triangleCount));
  });
}
