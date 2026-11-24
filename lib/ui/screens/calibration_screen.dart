import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/calibration_controller.dart';
import '../../application/providers.dart';
import '../../core/strings/app_strings.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/motion.dart';
import '../../data/glove/glove_connection.dart';
import '../../domain/models/calibration_table.dart';
import '../../domain/models/telemetry_packet.dart';
import '../widgets/anim.dart';
import '../widgets/hand_view.dart';
import '../widgets/header_band.dart';

/// Firmware-driven 10-step calibration wizard (master §4). The step shown
/// is always the glove's STATUS.calibrationStep — the app never advances
/// locally. The glove is the authority; the summary renders the mirrored
/// CAL_INFO table only.
class CalibrationScreen extends ConsumerWidget {
  const CalibrationScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(calibrationControllerProvider);
    return Scaffold(
      appBar: AppBar(title: const Text(AppStrings.calibrationTitle)),
      body: Column(
        children: [
          HeaderBand(
            title: AppStrings.calibrationTitle,
            chipLabel: state.step > 0 ? 'step ${state.step}/10' : null,
          ),
          Expanded(
            child: switch (state.phase) {
              CalibrationPhase.idle => _Idle(state: state),
              CalibrationPhase.running => _Running(state: state),
              CalibrationPhase.done => _Done(state: state),
            },
          ),
        ],
      ),
    );
  }
}

class _Idle extends ConsumerWidget {
  const _Idle({required this.state});

  final CalibrationState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final summary =
        state.calInfo == null ? null : CalibrationTable(state.calInfo!);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(AppStrings.calibrationPickHand,
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        for (final hand in const [GloveHand.left, GloveHand.right])
          Card(
            child: ListTile(
              leading: Icon(hand == GloveHand.left
                  ? Icons.back_hand_outlined
                  : Icons.back_hand),
              title: Text(hand == GloveHand.left
                  ? AppStrings.leftHandLabel
                  : AppStrings.rightHandLabel),
              subtitle: Text(
                  '${AppStrings.calibrationProfileSummary}: '
                  '${summary == null ? AppStrings.calibrationNoProfile : 'cal_id ${summary.calibrationId} · fw ${summary.firmwareVersion}'}'),
              onTap: () async {
                await ref
                    .read(calibrationControllerProvider.notifier)
                    .loadCached(hand);
                if (context.mounted) {
                  await ref
                      .read(calibrationControllerProvider.notifier)
                      .start(hand);
                }
              },
            ),
          ),
        if (summary != null) ...[
          const SizedBox(height: 12),
          _SummaryTable(table: summary),
        ] else
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Text(AppStrings.calibrationNoProfile,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
          ),
        const SizedBox(height: 24),
        Text(AppStrings.mountTitle,
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(AppStrings.mountIntro,
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: scheme.onSurfaceVariant)),
        const SizedBox(height: 4),
        Text(AppStrings.mountRestartNote,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant)),
        const SizedBox(height: 8),
        for (final hand in const [GloveHand.left, GloveHand.right])
          _MountCard(hand: hand),
      ],
    );
  }
}

/// fw 1.3.0 motion sensor (IMU mount) setup for one glove: gyro check,
/// Pose 1, Pose 2. Hidden behind a note on fw 1.2.0 gloves (no mount id).
class _MountCard extends ConsumerWidget {
  const _MountCard({required this.hand});

  final GloveHand hand;

  static Key buttonKey(GloveHand hand, AppCommand command) =>
      Key('mount-${hand.name}-${command.name}');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(
        liveControllerProvider.select((l) => l.forHand(hand).status));
    final mount = ref.watch(mountCalibrationControllerProvider);
    final mine = mount.hand == hand;
    final busy = mount.pending != null;
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    Widget step(AppCommand command, String label, String hint) => ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(hint, style: text.bodyMedium),
          trailing: FilledButton.tonal(
            key: buttonKey(hand, command),
            onPressed: busy
                ? null
                : () => ref
                    .read(mountCalibrationControllerProvider.notifier)
                    .run(hand, command),
            child: Text(mine && mount.pending == command
                ? AppStrings.mountWorking
                : label),
          ),
        );

    final List<Widget> body;
    if (status == null) {
      body = [Text(AppStrings.mountConnectFirst, style: text.bodyMedium)];
    } else if (status.mountCalibrationId == null) {
      body = [Text(AppStrings.mountNeedsNewFirmware, style: text.bodyMedium)];
    } else {
      body = [
        Text(
            status.mountUncalibrated
                ? AppStrings.mountStatusDefault
                : AppStrings.mountStatusDone,
            style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
        Center(
          child: _LiveGuideHand(
            hand: hand,
            compact: true,
            // Ghost of the next pose: Pose 2 once Pose 1 reported success
            // (the controller exposes that only through its message).
            ghost: (live) => HandPose(
              fingerDeg: const [0, 0, 0, 0, 0],
              pitchDeg: mine &&
                      mount.succeeded &&
                      mount.message == AppStrings.mountPose1Ok
                  ? 90
                  : 0,
              yawDeg: live.yawDeg,
              handedness: hand,
            ),
          ),
        ),
        step(AppCommand.calibrateGyro, AppStrings.mountGyroButton,
            AppStrings.mountGyroHint),
        step(AppCommand.captureMountPose1, AppStrings.mountPose1Button,
            AppStrings.mountPose1Hint),
        step(AppCommand.captureMountPose2, AppStrings.mountPose2Button,
            AppStrings.mountPose2Hint),
        if (mine && mount.message != null)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: mount.succeeded
                  ? scheme.secondaryContainer
                  : scheme.errorContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(mount.message!,
                style: text.bodyMedium?.copyWith(
                    color: mount.succeeded
                        ? scheme.onSecondaryContainer
                        : scheme.onErrorContainer)),
          ),
      ];
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(hand == GloveHand.left
                ? AppStrings.leftHandTitle
                : AppStrings.rightHandTitle,
                style: text.titleSmall),
            ...body,
          ],
        ),
      ),
    );
  }
}

class _Running extends ConsumerWidget {
  const _Running({required this.state});

  final CalibrationState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(calibrationControllerProvider.notifier);
    final finger = fingerNames[state.fingerIndex];
    final prompt = state.isFlatStep
        ? AppStrings.calibrationFlatPrompt(finger)
        : AppStrings.calibrationBendPrompt(finger);
    final scheme = Theme.of(context).colorScheme;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Progress ring (n of 10) in the brand gradient — driven only by
        // STATUS.step, easing toward each new value.
        Center(
          child: TweenAnimationBuilder<double>(
            tween:
                Tween(begin: 0, end: state.step == 0 ? 0 : state.step / 10),
            duration: TalkhimikMotion.of(context).resolve(
                context, TalkhimikMotion.values.quick),
            curve: Curves.easeOutCubic,
            builder: (context, value, _) => SizedBox(
              width: 72,
              height: 72,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  CustomPaint(
                    size: const Size(72, 72),
                    painter: _ProgressRingPainter(
                      fraction: value,
                      gradient: AppColors.deepGradient,
                      trackColor: scheme.surfaceContainerHighest,
                    ),
                  ),
                  Text('${state.step}/10',
                      style: Theme.of(context).textTheme.titleSmall),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          state.step == 0
              ? AppStrings.calibrationStart
              : '${AppStrings.calibrationProfileSummary}: '
                  'step ${state.step}/10',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 24),
        AnimatedSwitcher(
          duration: TalkhimikMotion.of(context).resolve(
              context, TalkhimikMotion.values.quick),
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: Tween(
                begin: const Offset(0.15, 0),
                end: Offset.zero,
              ).animate(animation),
              child: child,
            ),
          ),
          child: Column(
            key: ValueKey(state.step),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  // Flat ↔ 90° instruction: a hand-line icon rotating with
                  // the step phase.
                  AnimatedRotation(
                    turns: state.isFlatStep ? 0 : 0.25,
                    duration: TalkhimikMotion.of(context).resolve(
                        context, TalkhimikMotion.values.standard),
                    child: Icon(
                      Icons.back_hand_outlined,
                      size: 28,
                      color: scheme.primary,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      state.step == 0
                          ? AppStrings.calibrationStart
                          : prompt,
                      // Display prompt: one instruction per screen.
                      style: TalkhimikText.of(context)
                          .display
                          ?.copyWith(color: scheme.onSurface),
                    ),
                  ),
                ],
              ),
              if (state.step == 0)
                Padding(
                  padding: const EdgeInsets.only(top: 8, left: 40),
                  child: Text(
                    AppStrings.calibrationFlatPrompt(fingerNames[0]),
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
            ],
          ),
        ),
        // Error 3: one quick horizontal shake per rejection (zeroed under
        // reduce-motion via the motion tokens).
        if (state.error == AppStrings.calibrationSpanReject) ...[
          const SizedBox(height: 16),
          KeyedOneShot(
            trigger: '${state.step}-${state.error}',
            builder: (t, context) => Transform.translate(
              offset: Offset(
                  math.sin(t.value * math.pi * 4) * 6 * (1 - t.value), 0),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: scheme.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(state.error!,
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(color: scheme.onErrorContainer)),
              ),
            ),
          ),
        ] else if (state.error != null) ...[
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: scheme.errorContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(state.error!,
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: scheme.onErrorContainer)),
          ),
        ],
        const SizedBox(height: 24),
        PressScale(
          onTap: (state.step == 0 || state.capturePending)
              ? null
              : () async {
                  await ref
                      .read(calibrationControllerProvider.notifier)
                      .capture();
                  // Accepted captures get a light haptic tick; a
                  // rejection (error 3) stays quiet.
                  final current =
                      ref.read(calibrationControllerProvider);
                  if (current.error != AppStrings.calibrationSpanReject) {
                    HapticFeedback.selectionClick();
                  }
                },
          child: FilledButton.icon(
            icon: const Icon(Icons.check_circle_outline),
            label: AnimatedSwitcher(
              duration: TalkhimikMotion.of(context).resolve(
                  context, TalkhimikMotion.values.instant),
              child: Text(
                state.capturePending
                    ? AppStrings.calibrationCapturing
                    : AppStrings.calibrationCapture,
                key: ValueKey(state.capturePending),
              ),
            ),
            onPressed: null,
          ),
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: controller.cancel,
          child: const Text(AppStrings.calibrationAbort),
        ),
        const SizedBox(height: 16),
        // Live hand for the glove being calibrated: the current finger is
        // highlighted and its target (flat / 90°) shows as a ghost. Below
        // the actions so Capture/Cancel keep their place.
        _LiveGuideHand(
          hand: state.hand,
          highlightFinger: state.step == 0 ? null : state.fingerIndex,
          ghost: state.step == 0
              ? null
              : (live) => live.withFinger(
                  state.fingerIndex, state.isFlatStep ? 0 : 90),
        ),
      ],
    );
  }
}

/// Read-only 3D hand following one glove's live telemetry, with an
/// optional target ghost built from the live pose.
class _LiveGuideHand extends ConsumerWidget {
  const _LiveGuideHand({
    required this.hand,
    this.ghost,
    this.highlightFinger,
    this.compact = false,
  });

  final GloveHand hand;
  final HandPose Function(HandPose live)? ghost;
  final int? highlightFinger;
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final live =
        ref.watch(liveControllerProvider.select((l) => l.forHand(hand)));
    final pose = HandPose.fromTelemetry(live.telemetry, hand,
        weakMask: live.calInfo?.weakMask ?? 0);
    return HandView(
      key: Key('guide-hand-${hand.name}'),
      target: pose,
      ghost: ghost?.call(pose),
      highlightFinger: highlightFinger,
      compact: compact,
      stale: live.isStaleAt(DateTime.now()),
      uncalibrated: live.uncalibrated,
    );
  }
}

class _Done extends ConsumerWidget {
  const _Done({required this.state});

  final CalibrationState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summary =
        state.calInfo == null ? null : CalibrationTable(state.calInfo!);
    return HapticOnce(
      child: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Success moment: checkmark draws in once with a springy pop
        // (zeroed under reduce-motion), and the calibration id counts up.
        KeyedOneShot(
          trigger: summary?.calibrationId,
          builder: (t, context) => Transform.scale(
            scale: Curves.elasticOut.transform(t.value).clamp(0.0, 1.0),
            child: Icon(Icons.check_circle,
                size: 48, color: Theme.of(context).colorScheme.primary),
          ),
        ),
        const SizedBox(height: 8),
        Text(AppStrings.calibrationSavedTitle,
            style: Theme.of(context).textTheme.titleLarge),
        if (summary != null) ...[
          const SizedBox(height: 12),
          TweenAnimationBuilder<int>(
            tween: IntTween(begin: 0, end: summary.calibrationId),
            duration: TalkhimikMotion.of(context).resolve(
                context, TalkhimikMotion.values.standard),
            builder: (context, value, _) => Text(
              'cal_id $value'
              ' · fw ${summary.firmwareVersion}'
              ' · R_DIV ${summary.packet.rDiv.map((v) => v.toStringAsFixed(0)).join(', ')}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          const SizedBox(height: 12),
          _SummaryTable(table: summary),
        ],
        const SizedBox(height: 16),
        FilledButton(
          onPressed: () =>
              ref.read(calibrationControllerProvider.notifier).resetToIdle(),
          child: const Text(AppStrings.calibrationDone),
        ),
      ],
      ),
    );
  }
}

/// Per-finger summary: valid ✓/✗, weak ⚠, flat Ω, 90° Ω, span counts
/// (master §4.4). Source: the mirrored CAL_INFO — nothing else.
class _ProgressRingPainter extends CustomPainter {
  const _ProgressRingPainter({
    required this.fraction,
    required this.gradient,
    required this.trackColor,
  });

  final double fraction;
  final Gradient gradient;
  final Color trackColor;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = 8.0;
    final rect = Offset.zero & size;
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = trackColor;
    canvas.drawArc(rect.deflate(stroke / 2), 0, 2 * math.pi, false, track);

    final progress = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..shader = gradient
          .createShader(rect.deflate(stroke / 2))
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect.deflate(stroke / 2), -math.pi / 2,
        2 * math.pi * fraction, false, progress);
  }

  @override
  bool shouldRepaint(_ProgressRingPainter oldDelegate) =>
      oldDelegate.fraction != fraction ||
      oldDelegate.gradient != gradient ||
      oldDelegate.trackColor != trackColor;
}

class _SummaryTable extends StatelessWidget {
  const _SummaryTable({required this.table});

  final CalibrationTable table;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Table(
      columnWidths: const {
        0: FlexColumnWidth(1.4),
        1: FlexColumnWidth(1),
        2: FlexColumnWidth(1.2),
        3: FlexColumnWidth(1.2),
        4: FlexColumnWidth(1),
      },
      children: [
        TableRow(children: [
          for (final h in ['Finger', 'Valid', 'Flat Ω', '90° Ω', 'Span'])
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(h, style: Theme.of(context).textTheme.labelMedium),
            ),
        ]),
        for (final f in table.fingers)
          TableRow(children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(f.name),
            ),
            Text(f.valid ? '✓' : '✗',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: f.valid ? AppColors.success : scheme.error)),
            Text(f.flatOhm.toStringAsFixed(0),
                style: TalkhimikText.of(context).metric),
            Text(f.bent90Ohm.toStringAsFixed(0),
                style: TalkhimikText.of(context).metric),
            Text(f.weak ? '⚠ ${f.spanCounts}' : '${f.spanCounts}',
                style: f.weak
                    ? TalkhimikText.of(context)
                        .metric
                        ?.copyWith(color: AppColors.warning)
                    : TalkhimikText.of(context).metric),
          ]),
      ],
    );
  }
}
