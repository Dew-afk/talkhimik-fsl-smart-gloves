import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../core/strings/app_strings.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/motion.dart';
import '../../domain/models/telemetry_packet.dart';
import 'hand3d/hand_mesh.dart';
import 'hand3d/hand_orientation.dart';
import 'hand3d/hand_renderer.dart';
import 'header_band.dart';

/// Plain pose values for [HandPainter] — no business logic here (master §6.2).
class HandPose {
  const HandPose({
    required this.fingerDeg,
    this.rollDeg = 0,
    this.pitchDeg = 0,
    this.yawDeg = 0,
    required this.handedness,
    this.invalidMask = 0,
    this.weakMask = 0,
  });

  /// Pose from one telemetry frame (null → flat, level, nothing flagged).
  factory HandPose.fromTelemetry(TelemetryPacket? t, GloveHand hand,
          {int weakMask = 0}) =>
      HandPose(
        fingerDeg: [for (var i = 0; i < 5; i++) (t?.angles[i] ?? 0).toDouble()],
        rollDeg: t?.rollDeg ?? 0,
        pitchDeg: t?.pitchDeg ?? 0,
        yawDeg: t?.yawDeg ?? 0,
        handedness: hand,
        // The quality byte sets a bit per VALID finger; the view wants the
        // invalid ones.
        invalidMask: t == null ? 0 : ~t.validMask & 0x1F,
        weakMask: weakMask,
      );

  /// Flex 0–90° per finger, order thumb..pinky.
  final List<double> fingerDeg;

  /// IMU orientation in degrees (yaw is gyro-only / relative).
  final double rollDeg;
  final double pitchDeg;
  final double yawDeg;

  final GloveHand handedness;

  /// Bit0..4 = finger invalid (drawn wireframe + ✗).
  final int invalidMask;

  /// Bit0..4 = weak calibration span (CAL_INFO weak mask): amber ring + ⚠.
  final int weakMask;

  HandPose lerpTo(HandPose target, double t) => HandPose(
        fingerDeg: [
          for (var i = 0; i < fingerDeg.length; i++)
            fingerDeg[i] + (target.fingerDeg[i] - fingerDeg[i]) * t,
        ],
        // Roll and yaw wrap at ±180° (fw 1.3.0): take the short way round.
        rollDeg: wrap180(rollDeg + angleDelta(rollDeg, target.rollDeg) * t),
        pitchDeg: pitchDeg + (target.pitchDeg - pitchDeg) * t,
        yawDeg: wrap180(yawDeg + angleDelta(yawDeg, target.yawDeg) * t),
        handedness: handedness,
        invalidMask: target.invalidMask,
        weakMask: target.weakMask,
      );

  /// Same pose with finger [i] at [deg] (calibration target ghost).
  HandPose withFinger(int i, double deg) => HandPose(
        fingerDeg: [for (var k = 0; k < 5; k++) k == i ? deg : fingerDeg[k]],
        rollDeg: rollDeg,
        pitchDeg: pitchDeg,
        yawDeg: yawDeg,
        handedness: handedness,
        invalidMask: invalidMask,
        weakMask: weakMask,
      );

  Quat get orientation =>
      orientationFromImu(rollDeg: rollDeg, pitchDeg: pitchDeg, yawDeg: yawDeg);
}

/// Shortest signed angle from [from] to [to], in (−180, 180].
double angleDelta(double from, double to) => -wrap180(from - to);

/// Wraps degrees into (−180, 180].
double wrap180(double deg) {
  final d = deg % 360; // Dart % is non-negative for a positive divisor
  return d > 180 ? d - 360 : d;
}

/// One hand's panel: header band + calibration chip, then the live 3D hand
/// with per-finger badges. Drag to orbit the camera 360° around the hand
/// (it keeps tracking the glove); double-tap or "Reset view" to return.
class HandView extends StatefulWidget {
  const HandView({
    super.key,
    required this.target,
    this.title,
    this.chipLabel,
    this.uncalibrated = false,
    this.stale = false,
    this.compact = false,
    this.ghost,
    this.highlightFinger,
  });

  /// Latest pose from telemetry (the view animates toward it).
  final HandPose target;

  /// Header band title ("Left hand" / "Right hand"); no band when null.
  final String? title;

  /// Calibration chip text shown in the header band (cal_id · firmware).
  final String? chipLabel;

  /// Desaturates the hand and shows the "Uncalibrated" label.
  final bool uncalibrated;

  /// Freezes the hand at 40 % opacity (disconnected / no frames).
  final bool stale;

  /// COMPACT mode (Home preview card): no header band, smaller stage,
  /// no fingertip chips, no gestures.
  final bool compact;

  /// Translucent target pose drawn behind the live hand (calibration).
  final HandPose? ghost;

  /// Finger being calibrated: highlighted, and the [ghost] shows only it.
  final int? highlightFinger;

  @override
  State<HandView> createState() => _HandViewState();
}

class _HandViewState extends State<HandView>
    with SingleTickerProviderStateMixin {
  late Ticker _ticker;
  late HandPose _current;
  late Quat _orientation;
  late Quat _targetOrientation;
  late double _heldRoll;
  double _orbitYaw = 0;
  double _orbitTilt = 0;

  @override
  void initState() {
    super.initState();
    _current = widget.target;
    _heldRoll = widget.target.rollDeg;
    _retarget();
    _orientation = _targetOrientation;
    // Low-pass toward the target: v += (target − v) × 0.35 per tick
    // (master §6.2); orientation slerps by the same factor. The ticker
    // STOPS once the pose converges and restarts when a new target arrives
    // — no perpetual frames (tests can settle, battery friendly). "Reduce
    // motion" jumps straight to the target.
    _ticker = createTicker((_) {
      if (!mounted) return;
      final disableAnimations = MediaQuery.disableAnimationsOf(context);
      setState(() {
        _current = disableAnimations
            ? widget.target
            : _current.lerpTo(widget.target, 0.35);
        _orientation = disableAnimations
            ? _targetOrientation
            : _orientation.slerpTo(_targetOrientation, 0.35);
      });
      if (_converged) _ticker.stop();
    })..start();
  }

  /// Target orientation; roll is held near pitch ±90° where it is noise.
  void _retarget() {
    final t = widget.target;
    _heldRoll =
        stableRoll(previousRoll: _heldRoll, roll: t.rollDeg, pitch: t.pitchDeg);
    _targetOrientation = orientationFromImu(
        rollDeg: _heldRoll, pitchDeg: t.pitchDeg, yawDeg: t.yawDeg);
  }

  /// True when every finger and the orientation are within a hair of the
  /// target.
  bool get _converged {
    for (var i = 0; i < _current.fingerDeg.length; i++) {
      if ((_current.fingerDeg[i] - widget.target.fingerDeg[i]).abs() > 0.05) {
        return false;
      }
    }
    return _orientation.angleTo(_targetOrientation) < 1e-3;
  }

  @override
  void didUpdateWidget(HandView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _retarget();
    // A new telemetry target wakes the ticker if it had converged.
    if (!_converged && !_ticker.isActive) _ticker.start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _resetView() => setState(() {
        _orbitYaw = 0;
        _orbitTilt = 0;
      });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tokens = Theme.of(context).extension<TalkhimikTokens>() ??
        TalkhimikTokens.light;
    final side = widget.compact ? 100.0 : 220.0;
    Widget stage = AnimatedOpacity(
      opacity: widget.stale ? 0.4 : 1,
      duration: TalkhimikMotion.of(context)
          .resolve(context, TalkhimikMotion.values.quick),
      child: RepaintBoundary(
        child: CustomPaint(
          size: Size(side, side),
          painter: HandPainter(
            pose: _current,
            orientation: _orientation,
            orbitYawDeg: _orbitYaw,
            orbitTiltDeg: _orbitTilt,
            ghost: widget.ghost,
            highlightFinger: widget.highlightFinger,
            uncalibrated: widget.uncalibrated,
            tokens: tokens,
            compact: widget.compact,
            text: TalkhimikText.of(context),
            // Angle text under the badges must stay legible in both themes.
            mutedText: scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
    stage = Semantics(
      image: true,
      label: AppStrings.handPoseSemantics(
        left: widget.target.handedness == GloveHand.left,
        fingers: [for (final f in widget.target.fingerDeg) f.round()],
        roll: widget.target.rollDeg.round(),
        pitch: widget.target.pitchDeg.round(),
      ),
      child: stage,
    );
    if (!widget.compact) {
      final rotated = _orbitYaw != 0 || _orbitTilt != 0;
      stage = Stack(
        children: [
          // Claims only drags that START on the hand, so tab swipes and
          // list scrolling elsewhere keep working.
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanUpdate: (d) => setState(() {
              _orbitYaw = wrap180(_orbitYaw + d.delta.dx * 0.8);
              _orbitTilt = (_orbitTilt - d.delta.dy * 0.5)
                  .clamp(-maxOrbitTiltDeg, maxOrbitTiltDeg);
            }),
            onDoubleTap: _resetView,
            child: stage,
          ),
          if (rotated)
            Positioned(
              top: 0,
              right: 0,
              // Plain icon target (not IconButton): keeps the stage to one
              // CustomPaint, which hand_view_test relies on.
              child: Tooltip(
                message: AppStrings.handResetView,
                child: Semantics(
                  button: true,
                  label: AppStrings.handResetView,
                  child: GestureDetector(
                    key: const Key('hand-reset-view'),
                    behavior: HitTestBehavior.opaque,
                    onTap: _resetView,
                    child: SizedBox(
                      width: 48,
                      height: 48,
                      child: Icon(Icons.threesixty, color: scheme.primary),
                    ),
                  ),
                ),
              ),
            ),
        ],
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!widget.compact && widget.title != null)
          HeaderBand(title: widget.title!, chipLabel: widget.chipLabel),
        Container(
          margin: EdgeInsets.symmetric(horizontal: widget.compact ? 0 : 8),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [scheme.surface, scheme.surfaceContainerHighest],
            ),
            borderRadius: const BorderRadius.vertical(
              bottom: Radius.circular(16),
            ),
          ),
          child: stage,
        ),
      ],
    );
  }
}

/// Pure 3D renderer for one hand: procedural mesh posed by the flex
/// angles, rotated by the IMU orientation, orbited by the user, then
/// flat-shaded. Fingers are tinted along the 4-stop angle gradient; badges
/// (initial + live angle) sit on the projected fingertips.
class HandPainter extends CustomPainter {
  HandPainter({
    required this.pose,
    this.orientation,
    this.orbitYawDeg = 0,
    this.orbitTiltDeg = 0,
    this.ghost,
    this.highlightFinger,
    this.uncalibrated = false,
    required this.tokens,
    required this.text,
    this.compact = false,
    this.mutedText = const Color(0xFF4A4944),
  });

  final HandPose pose;

  /// Smoothed orientation; null → derived from [pose]'s Euler angles.
  final Quat? orientation;

  /// User camera orbit (degrees) on top of the glove orientation.
  final double orbitYawDeg;
  final double orbitTiltDeg;

  /// Translucent target pose (see [HandView.ghost]).
  final HandPose? ghost;
  final int? highlightFinger;

  final bool uncalibrated;
  final TalkhimikTokens tokens;

  /// App typography styles for the badge text (never hard-coded sizes).
  final TalkhimikText text;

  /// Compact mode: lighter mesh, no fingertip badges.
  final bool compact;

  /// Angle-label color under the badges (theme-dependent for dark mode).
  final Color mutedText;

  static const _initials = ['T', 'P', 'M', 'R', 'P'];
  static const _skin = Color(0xFFE8C39E);
  static const _grey = Color(0xFF9E9E9E);

  /// Fingertip screen positions for [pose] (default camera, no orbit).
  static List<Offset> fingerTipOffsets(Size size, HandPose pose) {
    final mesh = HandMesh.build(pose.fingerDeg,
        left: pose.handedness == GloveHand.left);
    final p = HandProjector(size, pose.orientation);
    return [for (final t in mesh.tips) p.project(p.toView(t))];
  }

  /// 4-stop finger gradient (0° → 90°): pale sky tint → sky → azure →
  /// navy, echoing the slab palette (step 5 re-skin).
  static Color fingerColorFor(double flex) {
    const stops = [
      AppColors.fingerLow,
      AppColors.sky,
      AppColors.azure,
      AppColors.navy,
    ];
    final t = (flex / 90).clamp(0.0, 1.0) * (stops.length - 1);
    final i = t.floor().clamp(0, stops.length - 2);
    return Color.lerp(stops[i], stops[i + 1], t - i)!;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final left = pose.handedness == GloveHand.left;
    final q = orientation ?? pose.orientation;
    HandProjector projector(Quat o) => HandProjector(size, o,
        orbitYawDeg: orbitYawDeg, orbitTiltDeg: orbitTiltDeg);
    final main = projector(q);

    // Ghost first so the live hand paints over it.
    final g = ghost;
    if (g != null) {
      final only = highlightFinger;
      paintHandMesh(
        canvas,
        HandMesh.build(g.fingerDeg, left: left, compact: compact),
        // A single-finger ghost rides on the live orientation.
        only != null ? main : projector(g.orientation),
        colorFor: (_) => tokens.header.withValues(alpha: 0.4),
        include: only == null ? null : (part) => part == only,
      );
    }

    final mesh = HandMesh.build(pose.fingerDeg, left: left, compact: compact);
    paintHandMesh(
      canvas,
      mesh,
      main,
      colorFor: (part) {
        if (uncalibrated) return _grey;
        if (part < 0) return _skin;
        if (part == highlightFinger) {
          return Color.lerp(_skin, tokens.headerDark, 0.6)!;
        }
        return Color.lerp(_skin, fingerColorFor(pose.fingerDeg[part]), 0.45)!;
      },
      wireframeMask: pose.invalidMask & 0x1F,
      wireColor: tokens.headerDark,
    );

    final tips = [for (final t in mesh.tips) main.project(main.toView(t))];

    // Soft sky glow on the most-flexed finger (state cue).
    var maxIndex = 0;
    for (var i = 1; i < 5; i++) {
      if (pose.fingerDeg[i] > pose.fingerDeg[maxIndex]) maxIndex = i;
    }
    final glowRadius = size.shortestSide * 0.17;
    if (pose.fingerDeg[maxIndex] > 60 && !uncalibrated) {
      canvas.drawCircle(
        tips[maxIndex],
        glowRadius,
        Paint()
          ..shader = RadialGradient(colors: [
            AppColors.sky.withValues(alpha: 0.45),
            AppColors.sky.withValues(alpha: 0),
          ]).createShader(
              Rect.fromCircle(center: tips[maxIndex], radius: glowRadius))
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
      );
    }

    // Weak span: amber ring at the finger base plus a ⚠ glyph, so the cue
    // never relies on color alone.
    for (var i = 0; i < 5; i++) {
      if (pose.weakMask & (1 << i) == 0) continue;
      final v = main.toView(mesh.bases[i]);
      final c = main.project(v);
      final r = main.pixels(0.14, v);
      canvas.drawCircle(
          c,
          r,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = AppColors.warning);
      _paintText(canvas, '⚠', c + Offset(r + 5, -r),
          text.caption!.copyWith(color: AppColors.warning));
    }

    if (!compact) {
      for (var i = 0; i < 5; i++) {
        _drawBadge(canvas, tips[i], _initials[i], pose.fingerDeg[i].round(),
            invalid: pose.invalidMask & (1 << i) != 0,
            weak: pose.weakMask & (1 << i) != 0,
            highlighted: i == highlightFinger);
      }
    }
  }

  void _drawBadge(Canvas canvas, Offset tip, String initial, int angle,
      {required bool invalid, required bool weak, required bool highlighted}) {
    final center = tip + const Offset(0, -12);
    final bg = Paint()
      ..color = invalid
          ? const Color(0xFFBFBDB6)
          : (uncalibrated ? _grey : tokens.header);
    final border = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = highlighted ? 3 : 1.5
      ..color = tokens.headerDark;
    canvas.drawCircle(center, 10, bg);
    canvas.drawCircle(center, 10, border);

    _paintText(
      canvas,
      invalid ? '✗' : initial,
      center,
      text.badge!.copyWith(
        color: invalid ? const Color(0xFF4A4944) : tokens.headerText,
      ),
    );
    _paintText(
      canvas,
      invalid ? '' : (weak ? '⚠ $angle°' : '$angle°'),
      center + const Offset(0, 22),
      text.caption!.copyWith(
        fontWeight: FontWeight.w600,
        color: weak ? AppColors.warning : mutedText,
      ),
    );
  }

  void _paintText(Canvas canvas, String text, Offset center, TextStyle style) {
    if (text.isEmpty) return;
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(
        canvas, center - Offset(painter.width / 2, painter.height / 2));
  }

  @override
  bool shouldRepaint(HandPainter oldDelegate) =>
      oldDelegate.pose != pose ||
      oldDelegate.orientation != orientation ||
      oldDelegate.orbitYawDeg != orbitYawDeg ||
      oldDelegate.orbitTiltDeg != orbitTiltDeg ||
      oldDelegate.ghost != ghost ||
      oldDelegate.highlightFinger != highlightFinger ||
      oldDelegate.uncalibrated != uncalibrated ||
      oldDelegate.tokens != tokens ||
      oldDelegate.compact != compact;
}
