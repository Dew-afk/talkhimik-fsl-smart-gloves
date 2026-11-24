import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talkhimik_app/application/providers.dart';
import 'package:talkhimik_app/core/strings/app_strings.dart';
import 'package:talkhimik_app/core/theme/app_theme.dart';
import 'package:talkhimik_app/domain/models/device_status.dart';
import 'package:talkhimik_app/domain/models/telemetry_packet.dart';
import 'package:talkhimik_app/ui/screens/calibration_screen.dart';
import 'package:talkhimik_app/ui/widgets/hand_view.dart';

import '../helpers/fake_glove_connection.dart';
import '../helpers/in_memory_calinfo_cache.dart';

HandPose flat({double pointer = 0}) => HandPose(
    fingerDeg: [0, pointer, 0, 0, 0], handedness: GloveHand.right);

HandPainter painterOf(WidgetTester tester, [Finder? within]) {
  final custom = tester.widget<CustomPaint>(find.descendant(
      of: within ?? find.byType(RepaintBoundary),
      matching: find.byType(CustomPaint)));
  return custom.painter! as HandPainter;
}

TelemetryPacket frame({int quality = 0x1F}) => TelemetryPacket(
      hand: GloveHand.left,
      seq: 1,
      angles: const [10, 20, 30, 40, 50],
      rollDeg: 0,
      pitchDeg: 0,
      yawDeg: 0,
      rawAdc: const [0, 0, 0, 0, 0],
      calibrationId: 1,
      quality: quality,
      receivedAt: DateTime(2026),
    );

void main() {
  Widget wrap(Widget child, {bool reduceMotion = false}) => MaterialApp(
        theme: buildLightTheme(),
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(disableAnimations: reduceMotion),
            child: Scaffold(body: Center(child: child)),
          ),
        ),
      );
  final handPaint = find.descendant(
      of: find.byType(HandView), matching: find.byType(CustomPaint));

  test('fromTelemetry flags INVALID fingers (quality bits are valid ones)',
      () {
    expect(HandPose.fromTelemetry(frame(), GloveHand.left).invalidMask, 0);
    expect(
        HandPose.fromTelemetry(frame(quality: 0x1D), GloveHand.left)
            .invalidMask,
        0x02);
    expect(HandPose.fromTelemetry(null, GloveHand.left).invalidMask, 0);
  });

  testWidgets('drag orbits the camera; Reset and double-tap return it',
      (tester) async {
    await tester.pumpWidget(wrap(HandView(target: flat(), title: 'Right')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('hand-reset-view')), findsNothing);

    await tester.drag(handPaint, const Offset(120, -40));
    await tester.pumpAndSettle();
    expect(painterOf(tester).orbitYawDeg, isNot(0));
    expect(painterOf(tester).orbitTiltDeg, isNot(0));

    await tester.tap(find.byKey(const Key('hand-reset-view')));
    await tester.pumpAndSettle();
    expect(painterOf(tester).orbitYawDeg, 0);
    expect(painterOf(tester).orbitTiltDeg, 0);

    await tester.drag(handPaint, const Offset(80, 0));
    await tester.pumpAndSettle();
    final paint = handPaint;
    await tester.tap(paint);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(paint);
    await tester.pumpAndSettle();
    expect(painterOf(tester).orbitYawDeg, 0);
  });

  testWidgets('a new target eases in, then the ticker settles',
      (tester) async {
    await tester.pumpWidget(wrap(HandView(target: flat(), title: 'Right')));
    await tester.pumpWidget(
        wrap(HandView(target: flat(pointer: 80), title: 'Right')));
    await tester.pump(const Duration(milliseconds: 16));
    final mid = painterOf(tester).pose.fingerDeg[1];
    expect(mid, inExclusiveRange(0, 80));
    await tester.pumpAndSettle(); // would time out on a perpetual ticker
    expect(painterOf(tester).pose.fingerDeg[1], closeTo(80, 0.1));
  });

  testWidgets('reduce motion snaps straight to the target', (tester) async {
    await tester.pumpWidget(
        wrap(HandView(target: flat(), title: 'Right'), reduceMotion: true));
    await tester.pumpWidget(wrap(
        HandView(target: flat(pointer: 80), title: 'Right'),
        reduceMotion: true));
    await tester.pump(const Duration(milliseconds: 16));
    expect(painterOf(tester).pose.fingerDeg[1], 80);
  });

  testWidgets('compact hands take no gestures', (tester) async {
    await tester.pumpWidget(wrap(HandView(target: flat(), compact: true)));
    expect(
        find.descendant(
            of: find.byType(HandView), matching: find.byType(GestureDetector)),
        findsNothing);
  });

  group('calibration screen', () {
    late FakeGloveConnection glove;
    Widget screen() => ProviderScope(
          overrides: [
            gloveConnectionProvider.overrideWithValue(glove),
            calInfoCacheProvider.overrideWithValue(InMemoryCalInfoCache()),
          ],
          child: MaterialApp(
              theme: buildLightTheme(), home: const CalibrationScreen()),
        );
    setUp(() => glove = FakeGloveConnection());

    testWidgets('wizard ghost follows the step: flat on odd, 90° on even',
        (tester) async {
      await tester.pumpWidget(screen());
      await tester.tap(find.text(AppStrings.leftHandLabel));
      await tester.pumpAndSettle();

      final guide = find.byKey(const Key('guide-hand-left'));
      for (final (step, finger, deg) in [(3, 1, 0.0), (4, 1, 90.0)]) {
        glove.emitStatus(DeviceStatusPacket(
            mode: GloveMode.calibrating, calibrationStep: step));
        await tester.pumpAndSettle();
        final p = painterOf(tester, guide);
        expect(p.highlightFinger, finger);
        expect(p.ghost!.fingerDeg[finger], deg);
      }
    });

    testWidgets('mount card shows a live hand with the Pose 1 ghost',
        (tester) async {
      await tester.pumpWidget(screen());
      glove.emitStatus(const DeviceStatusPacket(
          mode: GloveMode.streaming,
          lastErrorCode: 0,
          mountUncalibrated: true,
          mountCalibrationId: 0));
      await tester.pumpAndSettle();
      final guide = find.byKey(const Key('guide-hand-left'));
      await tester.scrollUntilVisible(guide, 200);
      await tester.pumpAndSettle();
      final p = painterOf(tester, guide);
      expect(p.compact, isTrue);
      expect(p.ghost!.pitchDeg, 0); // Pose 1: palm down, level
    });
  });
}
