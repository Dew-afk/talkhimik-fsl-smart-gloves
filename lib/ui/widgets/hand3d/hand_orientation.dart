import 'dart:math' as math;

/// Minimal 3-vector for the hand renderer. Axes follow the glove BODY frame
/// (docs §1, fw 1.3.0): +X fingertips, +Y toward the thumb side of a right
/// hand (left when palm down), +Z out of the back of the hand (up).
class Vec3 {
  const Vec3(this.x, this.y, this.z);

  final double x;
  final double y;
  final double z;

  static const zero = Vec3(0, 0, 0);
  static const unitX = Vec3(1, 0, 0);
  static const unitY = Vec3(0, 1, 0);
  static const unitZ = Vec3(0, 0, 1);

  Vec3 operator +(Vec3 o) => Vec3(x + o.x, y + o.y, z + o.z);
  Vec3 operator -(Vec3 o) => Vec3(x - o.x, y - o.y, z - o.z);
  Vec3 operator *(double s) => Vec3(x * s, y * s, z * s);

  double dot(Vec3 o) => x * o.x + y * o.y + z * o.z;
  Vec3 cross(Vec3 o) =>
      Vec3(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x);
  double get length => math.sqrt(dot(this));
  Vec3 get normalized {
    final l = length;
    return l == 0 ? this : this * (1 / l);
  }

  @override
  String toString() => 'Vec3($x, $y, $z)';
}

/// Unit quaternion (w, x, y, z). Rotations are slerped, never Euler-lerped,
/// so roll ±180° and pitch ±90° cannot flip the hand.
class Quat {
  const Quat(this.w, this.x, this.y, this.z);

  final double w;
  final double x;
  final double y;
  final double z;

  static const identity = Quat(1, 0, 0, 0);

  /// Right-hand rotation of [rad] about the unit [axis].
  factory Quat.axisAngle(Vec3 axis, double rad) {
    final s = math.sin(rad / 2);
    return Quat(math.cos(rad / 2), axis.x * s, axis.y * s, axis.z * s);
  }

  Quat operator *(Quat o) => Quat(
        w * o.w - x * o.x - y * o.y - z * o.z,
        w * o.x + x * o.w + y * o.z - z * o.y,
        w * o.y - x * o.z + y * o.w + z * o.x,
        w * o.z + x * o.y - y * o.x + z * o.w,
      );

  Vec3 rotate(Vec3 v) {
    // v' = v + 2w(q×v) + 2 q×(q×v), q = vector part.
    final q = Vec3(x, y, z);
    final t = q.cross(v) * 2;
    return v + t * w + q.cross(t);
  }

  double dot(Quat o) => w * o.w + x * o.x + y * o.y + z * o.z;

  /// Angle (radians) between two orientations, shortest arc.
  double angleTo(Quat o) => 2 * math.acos(dot(o).abs().clamp(0.0, 1.0));

  /// Shortest-arc spherical interpolation toward [o].
  Quat slerpTo(Quat o, double t) {
    var d = dot(o);
    var b = o;
    if (d < 0) {
      // q and −q are the same rotation: flip to take the short way.
      d = -d;
      b = Quat(-o.w, -o.x, -o.y, -o.z);
    }
    if (d > 0.9995) {
      return Quat(w + (b.w - w) * t, x + (b.x - x) * t, y + (b.y - y) * t,
              z + (b.z - z) * t)
          .normalized;
    }
    final theta = math.acos(d);
    final s = math.sin(theta);
    final a = math.sin((1 - t) * theta) / s;
    final c = math.sin(t * theta) / s;
    return Quat(a * w + c * b.w, a * x + c * b.x, a * y + c * b.y,
        a * z + c * b.z);
  }

  Quat get normalized {
    final l = math.sqrt(dot(this));
    return Quat(w / l, x / l, y / l, z / l);
  }
}

const _deg = math.pi / 180;

/// Body → world rotation from the firmware's Euler output:
/// R = Rz(yaw)·Ry(−pitch)·Rx(roll). This reproduces imu.cpp exactly: the
/// world "up" seen in the body frame is (sin p, cos p·sin r, cos p·cos r),
/// so roll = atan2(u.y, u.z) and pitch = atan2(u.x, √(u.y²+u.z²)).
Quat orientationFromImu(
        {required double rollDeg,
        required double pitchDeg,
        required double yawDeg}) =>
    Quat.axisAngle(Vec3.unitZ, yawDeg * _deg) *
    Quat.axisAngle(Vec3.unitY, -pitchDeg * _deg) *
    Quat.axisAngle(Vec3.unitX, rollDeg * _deg);

/// Pitch beyond which roll is noise (atan2 of two near-zero terms).
const rollHoldPitchDeg = 85.0;

/// Roll to render: near pitch ±90° the firmware's roll is undefined, so the
/// last trustworthy roll is kept instead of spinning the hand about its
/// finger axis.
double stableRoll(
        {required double previousRoll,
        required double roll,
        required double pitch}) =>
    pitch.abs() > rollHoldPitchDeg ? previousRoll : roll;
