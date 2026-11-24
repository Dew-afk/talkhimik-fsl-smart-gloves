import 'dart:math' as math;
import 'dart:ui';

import 'hand_mesh.dart';
import 'hand_orientation.dart';

const _deg = math.pi / 180;

/// Default camera: behind and above the wrist, looking down the fingers —
/// the wearer's own view of the back of their hand.
const baseCameraTiltDeg = -35.0;

/// Limit for the user's vertical drag, relative to the default view.
const maxOrbitTiltDeg = 80.0;

const _cameraDistance = 5.0;

/// Key light in view space (upper-left, toward the viewer).
final _light = const Vec3(-0.35, 0.55, 0.75).normalized;
const _ambient = 0.42;

/// World → screen for one canvas. View space: x right, y up, z toward the
/// viewer; the camera sits at (0, 0, [_cameraDistance]).
class HandProjector {
  HandProjector(Size size, Quat orientation,
      {double orbitYawDeg = 0, double orbitTiltDeg = 0})
      : _center = Offset(size.width / 2, size.height / 2),
        // Fit the bounding sphere at its nearest (most magnified) depth so
        // no vertex leaves the canvas at any orientation or orbit.
        _scale = math.min(size.width, size.height) /
            2 *
            0.94 /
            (handBoundingRadius *
                _cameraDistance /
                (_cameraDistance - handBoundingRadius)),
        _rotation = Quat.axisAngle(
                Vec3.unitX,
                (baseCameraTiltDeg +
                        orbitTiltDeg.clamp(-maxOrbitTiltDeg, maxOrbitTiltDeg)) *
                    _deg) *
            // World +X (fingers) → screen up, +Y → screen left, +Z → viewer.
            Quat.axisAngle(Vec3.unitZ, 90 * _deg) *
            // Turntable orbit about world vertical.
            Quat.axisAngle(Vec3.unitZ, orbitYawDeg * _deg) *
            orientation;

  final Offset _center;
  final double _scale;
  final Quat _rotation;

  Vec3 toView(Vec3 body) => _rotation.rotate(body);

  Offset project(Vec3 view) {
    final k = _cameraDistance / (_cameraDistance - view.z) * _scale;
    return Offset(_center.dx + view.x * k, _center.dy - view.y * k);
  }

  /// Screen length of [r] body units at depth [view] (marker sizing).
  double pixels(double r, Vec3 view) =>
      r * _cameraDistance / (_cameraDistance - view.z) * _scale;
}

/// Draws [mesh] flat-shaded with back faces culled and the rest sorted far
/// → near (painter's algorithm), in ONE drawVertices call. [colorFor] gives
/// each part's base color (alpha kept); parts in [wireframeMask] (bit per
/// finger) are drawn as a faint fill plus outline in [wireColor].
void paintHandMesh(
  Canvas canvas,
  HandMesh mesh,
  HandProjector projector, {
  required Color Function(int part) colorFor,
  int wireframeMask = 0,
  Color wireColor = const Color(0xFF01579B),
  bool Function(int part)? include,
}) {
  final view = [for (final v in mesh.vertices) projector.toView(v)];
  const eye = Vec3(0, 0, _cameraDistance);
  final tris = <(double, int, double)>[]; // depth, triangle, light
  for (var t = 0; t < mesh.triangleCount; t++) {
    if (include != null && !include(mesh.parts[t])) continue;
    final a = view[mesh.indices[t * 3]];
    final b = view[mesh.indices[t * 3 + 1]];
    final c = view[mesh.indices[t * 3 + 2]];
    final n = (b - a).cross(c - a);
    final len = n.length;
    if (len < 1e-12) continue; // degenerate cap triangle
    if (n.dot(a - eye) >= 0) continue; // facing away
    final lambert = math.max(0.0, n.dot(_light) / len);
    tris.add(((a.z + b.z + c.z) / 3, t, _ambient + (1 - _ambient) * lambert));
  }
  tris.sort((p, q) => p.$1.compareTo(q.$1));

  final positions = <Offset>[];
  final colors = <Color>[];
  final wire = Path();
  for (final (_, t, light) in tris) {
    final part = mesh.parts[t];
    final pts = [
      for (var k = 0; k < 3; k++) projector.project(view[mesh.indices[t * 3 + k]])
    ];
    final wired = part >= 0 && wireframeMask & (1 << part) != 0;
    final base = colorFor(part);
    final shaded = Color.from(
      alpha: wired ? base.a * 0.15 : base.a,
      red: (base.r * light).clamp(0.0, 1.0),
      green: (base.g * light).clamp(0.0, 1.0),
      blue: (base.b * light).clamp(0.0, 1.0),
    );
    positions.addAll(pts);
    colors..add(shaded)..add(shaded)..add(shaded);
    if (wired) wire.addPolygon(pts, true);
  }
  if (positions.isEmpty) return;
  // BlendMode.dst: vertex colors only, the paint contributes nothing.
  canvas.drawVertices(
      Vertices(VertexMode.triangles, positions, colors: colors),
      BlendMode.dst,
      Paint());
  if (wireframeMask != 0) {
    canvas.drawPath(
        wire,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.6
          ..color = wireColor.withValues(alpha: 0.7));
  }
}
