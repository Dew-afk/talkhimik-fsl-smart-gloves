import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talkhimik_app/application/dataset_recorder_controller.dart';
import 'package:talkhimik_app/application/providers.dart';
import 'package:talkhimik_app/core/strings/app_strings.dart';
import 'package:talkhimik_app/domain/models/cal_info_packet.dart';
import 'package:talkhimik_app/domain/models/device_status.dart';
import 'package:talkhimik_app/domain/models/telemetry_packet.dart';

import '../helpers/fake_glove_connection.dart';
import '../helpers/in_memory_calinfo_cache.dart';
import '../helpers/in_memory_settings_service.dart';

CalInfoPacket calInfo(int id, {int validMask = 0x1F}) => CalInfoPacket(
      validMask: validMask,
      weakMask: 0,
      calibrationId: id,
      flatOhm: const [10000, 10000, 10000, 10000, 10000],
      bent90Ohm: const [30000, 30000, 30000, 30000, 30000],
      flatAdc: const [500, 500, 500, 500, 500],
      bent90Adc: const [1500, 1500, 1500, 1500, 1500],
      rDiv: const [10000, 10000, 10000, 10000, 10000],
      spanCounts: const [1000, 1000, 1000, 1000, 1000],
      firmwareVersion: '1.2.0',
    );

TelemetryPacket frame(int seq, int calId,
        {List<int>? raw, DateTime? at}) =>
    TelemetryPacket(
      hand: GloveHand.left,
      seq: seq,
      angles: const [10, 20, 30, 40, 50],
      rollDeg: 0,
      pitchDeg: 0,
      yawDeg: 0,
      rawAdc: raw ?? const [100, 200, 300, 400, 500],
      calibrationId: calId,
      quality: 0x1F,
      receivedAt: at ?? DateTime.now(),
    );

void main() {
  late FakeGloveConnection left;
  late FakeGloveConnection right;
  late InMemorySettingsService settings;
  late Directory dir;

  ProviderContainer makeContainer() {
    left = FakeGloveConnection();
    right = FakeGloveConnection();
    settings = InMemorySettingsService()
      ..participant = 'P-001'
      ..consent = true;
    final container = ProviderContainer(
      overrides: [
        gloveConnectionProvider.overrideWithValue(left),
        rightGloveConnectionProvider.overrideWithValue(right),
        settingsServiceProvider.overrideWithValue(settings),
        calInfoCacheProvider.overrideWithValue(InMemoryCalInfoCache()),
        datasetDirectoryProvider.overrideWithValue(Future.value(dir)),
        // Long sampler interval: tests drive sampleNow() directly.
        datasetRecorderControllerProvider.overrideWith(
            () => DatasetRecorderController(const Duration(hours: 1))),
      ],
    );
    addTearDown(container.dispose);
    container.read(datasetRecorderControllerProvider);
    container.read(liveControllerProvider);
    return container;
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('talkhimik_rec_test');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Future<void> emit(TelemetryPacket packet) async {
    left.emitTelemetry(packet);
    await pumpEventQueue();
  }

  Future<void> emitCalInfo(CalInfoPacket packet) async {
    left.emitCalInfo(packet);
    await pumpEventQueue();
  }

  Future<void> startRecording(ProviderContainer c) async {
    await c.read(datasetRecorderControllerProvider.notifier).start();
  }

  test('consent gate blocks recording (NFR-8, master §5.1)', () async {
    final c = makeContainer();
    settings.consent = false;
    await startRecording(c);
    expect(c.read(datasetRecorderControllerProvider).error,
        AppStrings.recordNeedsConsent);
    expect(c.read(datasetRecorderControllerProvider).phase,
        RecordingPhase.idle);
  });

  test('a connected uncalibrated glove (cal_id 0) blocks recording',
      () async {
    final c = makeContainer();
    await emitCalInfo(calInfo(0));
    await emit(frame(1, 0));
    await startRecording(c);
    expect(c.read(datasetRecorderControllerProvider).error,
        AppStrings.recordNeedsCalibration);
  });

  test('link loss > 3 frames is counted but the fresh frame kept; take_id '
      'increments per start press (master §5.1)', () async {
    final c = makeContainer();
    await emitCalInfo(calInfo(3));
    await startRecording(c);
    await c
        .read(datasetRecorderControllerProvider.notifier)
        .startTake('A');
    final recorder = c.read(datasetRecorderControllerProvider.notifier);

    await emit(frame(10, 3));
    await recorder.sampleNow();
    // Timer ran late: 5 frames since the last sample, none lost → kept.
    for (var q = 11; q <= 15; q++) {
      await emit(frame(q, 3));
    }
    await recorder.sampleNow();
    await emit(frame(20, 3)); // 4 frames lost on the link → counted, kept
    await recorder.sampleNow();
    expect(c.read(datasetRecorderControllerProvider).error, isNull);

    var s = c.read(datasetRecorderControllerProvider);
    expect(s.active[GloveHand.left]!.rows, 3);
    expect(s.active[GloveHand.left]!.seqGapDrops, 1);
    expect(s.active[GloveHand.left]!.droppedFrames, 0);
    expect(s.active[GloveHand.left]!.takeId, 1);

    // Second take: take_id increments within the session.
    await c
        .read(datasetRecorderControllerProvider.notifier)
        .startTake('B');
    await emit(frame(21, 3));
    await recorder.sampleNow();
    s = c.read(datasetRecorderControllerProvider);
    expect(s.error, isNull); // a written row clears the skip message
    expect(s.active[GloveHand.left]!.takeId, 2);
    expect(s.active[GloveHand.left]!.rows, 4);
  });

  test('ADC rail (raw 0 or 4095) drops only on VALID fingers', () async {
    final c = makeContainer();
    await emitCalInfo(calInfo(3, validMask: 0x1E)); // thumb invalid
    await startRecording(c);
    await c
        .read(datasetRecorderControllerProvider.notifier)
        .startTake('A');
    final recorder = c.read(datasetRecorderControllerProvider.notifier);

    // Thumb (invalid) railed — not a drop; pointer (valid) railed — drop.
    await emit(frame(10, 3, raw: [0, 200, 300, 400, 500]));
    await recorder.sampleNow();
    await emit(frame(11, 3, raw: [0, 4095, 300, 400, 500]));
    await recorder.sampleNow();

    final s = c.read(datasetRecorderControllerProvider);
    expect(s.active[GloveHand.left]!.rows, 1);
    expect(s.active[GloveHand.left]!.adcRail, 1);
    expect(s.error, AppStrings.recordSensorAtLimit('pointer'));
  });

  test('a stalled glove (same frame again) writes no duplicate row',
      () async {
    final c = makeContainer();
    await emitCalInfo(calInfo(3));
    await startRecording(c);
    final recorder = c.read(datasetRecorderControllerProvider.notifier);
    await recorder.startTake('A');
    await emit(frame(10, 3));
    await recorder.sampleNow();
    await recorder.sampleNow(); // no new frame arrived
    final s = c.read(datasetRecorderControllerProvider);
    expect(s.active[GloveHand.left]!.rows, 1);
    expect(s.error, AppStrings.recordNoNewData);
  });

  test('a calibration change closes the session and opens a new file '
      '(master §5.1)', () async {
    final c = makeContainer();
    await emitCalInfo(calInfo(3));
    await startRecording(c);
    final recorder = c.read(datasetRecorderControllerProvider.notifier);
    await recorder.startTake('A');

    await emit(frame(10, 3));
    await recorder.sampleNow();
    await emitCalInfo(calInfo(4));
    await emit(frame(11, 4)); // new calibration on the wire
    await recorder.sampleNow();
    await recorder.stop();

    final sessions = c.read(datasetRecorderControllerProvider).sessions;
    // Both finalized files exist: the closed cal-3 session and the cal-4
    // session closed by stop(). Newest first.
    expect(sessions, hasLength(2));
    expect(sessions.first.calibrationId, 4);
    expect(sessions.last.calibrationId, 3);
    expect(sessions.last.rows, 1);
  });

  test('a mount calibration change also opens a new file (fw 1.3.0)',
      () async {
    final c = makeContainer();
    await emitCalInfo(calInfo(3));
    left.emitStatus(const DeviceStatusPacket(mountCalibrationId: 0));
    await startRecording(c);
    final recorder = c.read(datasetRecorderControllerProvider.notifier);
    await recorder.startTake('A');

    await emit(frame(10, 3));
    await recorder.sampleNow();
    // Distinct S-<ms> session ids (same cal id → same name pattern).
    await Future<void>.delayed(const Duration(milliseconds: 5));
    left.emitStatus(const DeviceStatusPacket(mountCalibrationId: 77));
    await emit(frame(11, 3));
    await recorder.sampleNow();
    await recorder.stop();

    final sessions = c.read(datasetRecorderControllerProvider).sessions;
    expect(sessions, hasLength(2));
    final sidecars = [
      for (final f in dir.listSync().whereType<File>())
        if (f.path.endsWith('_sidecar.json')) f.readAsStringSync(),
    ];
    expect(sidecars.where((s) => s.contains('"mount_calibration_id":77')),
        hasLength(1));
    expect(sidecars.where((s) => s.contains('"mount_calibration_id":0')),
        hasLength(1));
  });

  test('ending a take lists the session without Stop (share-all works)',
      () async {
    final c = makeContainer();
    await emitCalInfo(calInfo(3));
    await startRecording(c);
    final recorder = c.read(datasetRecorderControllerProvider.notifier);
    await recorder.startTake('B');
    await emit(frame(10, 3));
    await recorder.sampleNow();
    expect(c.read(datasetRecorderControllerProvider).sessions, isEmpty);

    await recorder.stopTake(); // still recording — no stop()
    final sessions = c.read(datasetRecorderControllerProvider).sessions;
    expect(sessions, hasLength(1));
    expect(sessions.single.rows, 1);
  });

  test('undo removes only the last take, from the CSV and the counts',
      () async {
    final c = makeContainer();
    await emitCalInfo(calInfo(3));
    await startRecording(c);
    final recorder = c.read(datasetRecorderControllerProvider.notifier);

    await recorder.startTake('A');
    await emit(frame(10, 3));
    await recorder.sampleNow();
    await emit(frame(11, 3));
    await recorder.sampleNow();
    await recorder.stopTake();
    expect(c.read(datasetRecorderControllerProvider).undoLabel, 'A');

    await recorder.startTake('B'); // the misinput
    await emit(frame(12, 3));
    await recorder.sampleNow();
    await recorder.stopTake();
    expect(c.read(datasetRecorderControllerProvider).undoLabel, 'B');
    expect(c.read(datasetRecorderControllerProvider).undoMore, 1);

    await recorder.undoLastTake();
    final s = c.read(datasetRecorderControllerProvider);
    expect(s.undoLabel, 'A'); // the take before it is next
    expect(s.undoMore, 0);
    expect(s.active[GloveHand.left]!.rows, 2);
    expect(s.sessions.single.rows, 2);
    final csv = dir
        .listSync()
        .whereType<File>()
        .singleWhere((f) => f.path.endsWith('.csv'))
        .readAsLinesSync();
    expect(csv, hasLength(3)); // header + the two A rows
    expect(csv.skip(1).every((l) => l.contains(',A,')), isTrue);

    // Coverage rebuilt from disk: B is gone, A keeps its take.
    final index = await c.read(coverageIndexStoreProvider).rebuild();
    expect(index.labels.containsKey('B'), isFalse);
    expect(index.labels['A']!.takes, 1);
  });

  test('undo steps back through several takes, newest first', () async {
    final c = makeContainer();
    await emitCalInfo(calInfo(3));
    await startRecording(c);
    final recorder = c.read(datasetRecorderControllerProvider.notifier);
    var seq = 10;
    for (final label in ['A', 'B', 'C']) {
      await recorder.startTake(label);
      await emit(frame(seq++, 3));
      await recorder.sampleNow();
      await recorder.stopTake();
    }
    expect(c.read(datasetRecorderControllerProvider).undoMore, 2);

    final undone = <String>[];
    while (c.read(datasetRecorderControllerProvider).undoLabel.isNotEmpty) {
      undone.add(c.read(datasetRecorderControllerProvider).undoLabel);
      await recorder.undoLastTake();
    }
    expect(undone, ['C', 'B', 'A']);
    expect(c.read(datasetRecorderControllerProvider).sessions.single.rows, 0);
  });

  test('deleting a session drops its takes from undo', () async {
    final c = makeContainer();
    await emitCalInfo(calInfo(3));
    await startRecording(c);
    final recorder = c.read(datasetRecorderControllerProvider.notifier);
    await recorder.startTake('A');
    await emit(frame(10, 3));
    await recorder.sampleNow();
    await recorder.stopTake();
    await recorder.stop();

    await recorder.deleteSession(
        c.read(datasetRecorderControllerProvider).sessions.single);
    expect(c.read(datasetRecorderControllerProvider).undoLabel, '');
  });

  Future<void> bothGlovesOn() async {
    await emitCalInfo(calInfo(3));
    right.emitCalInfo(calInfo(4));
    await emit(frame(10, 3));
    right.emitTelemetry(frame(10, 4));
    await pumpEventQueue();
  }

  test('both gloves on: recording waits for a hand choice, then saves only '
      'that glove', () async {
    final c = makeContainer();
    await bothGlovesOn();
    final recorder = c.read(datasetRecorderControllerProvider.notifier);
    await startRecording(c);
    expect(c.read(datasetRecorderControllerProvider).error,
        AppStrings.recordPickHands);
    expect(c.read(datasetRecorderControllerProvider).phase,
        RecordingPhase.idle);

    recorder.setRecordHands('right');
    await startRecording(c);
    await recorder.startTake('A');
    await emit(frame(11, 3));
    right.emitTelemetry(frame(11, 4));
    await pumpEventQueue();
    await recorder.sampleNow();
    final s = c.read(datasetRecorderControllerProvider);
    expect(s.active.keys, [GloveHand.right]);
    expect(s.active[GloveHand.right]!.twoHand, isFalse);

    recorder.setRecordHands('left'); // locked while recording
    expect(c.read(datasetRecorderControllerProvider).recordHands, 'right');
  });

  test('a chosen glove that is not connected blocks recording', () async {
    final c = makeContainer();
    await emitCalInfo(calInfo(3));
    await emit(frame(10, 3)); // only the left glove is on
    c.read(datasetRecorderControllerProvider.notifier).setRecordHands('right');
    await startRecording(c);
    expect(c.read(datasetRecorderControllerProvider).error,
        AppStrings.recordHandNotConnected);
  });

  test('Both mode saves each glove with the same take, marked two-handed',
      () async {
    final c = makeContainer();
    await bothGlovesOn();
    final recorder = c.read(datasetRecorderControllerProvider.notifier);
    recorder.setRecordHands('both');
    await startRecording(c);
    await recorder.startTake('Kain');
    await emit(frame(11, 3));
    right.emitTelemetry(frame(11, 4));
    await pumpEventQueue();
    await recorder.sampleNow();
    await recorder.stopTake();
    await recorder.stop();

    final sidecars = [
      for (final f in dir.listSync().whereType<File>())
        if (f.path.endsWith('_sidecar.json')) f.readAsStringSync(),
    ];
    expect(sidecars, hasLength(2));
    expect(sidecars.every((s) => s.contains('"two_hand":true')), isTrue);
    final csvs = [
      for (final f in dir.listSync().whereType<File>())
        if (f.path.endsWith('.csv')) f.readAsLinesSync()[1],
    ];
    expect(csvs.every((l) => l.contains(',Kain,1,')), isTrue);
  });

  test('reset deletes everything, but never while recording', () async {
    final c = makeContainer();
    await emitCalInfo(calInfo(3));
    await startRecording(c);
    final recorder = c.read(datasetRecorderControllerProvider.notifier);
    await recorder.startTake('A');
    await emit(frame(10, 3));
    await recorder.sampleNow();
    await recorder.stopTake();

    await recorder.resetAll(); // refused: still recording
    expect(dir.listSync(), isNotEmpty);

    await recorder.stop();
    await recorder.resetAll();
    final s = c.read(datasetRecorderControllerProvider);
    expect(s.sessions, isEmpty);
    expect(s.undoLabel, '');
    final index = await c.read(coverageIndexStoreProvider).rebuild();
    expect(index.labels, isEmpty);
  });

  test('undo still works after Stop recording', () async {
    final c = makeContainer();
    await emitCalInfo(calInfo(3));
    await startRecording(c);
    final recorder = c.read(datasetRecorderControllerProvider.notifier);
    await recorder.startTake('C');
    await emit(frame(10, 3));
    await recorder.sampleNow();
    await recorder.stopTake();
    await recorder.stop();

    await recorder.undoLastTake();
    expect(c.read(datasetRecorderControllerProvider).sessions.single.rows, 0);
  });

  test('rows are only written while a take is active', () async {
    final c = makeContainer();
    await emitCalInfo(calInfo(3));
    await startRecording(c);
    final recorder = c.read(datasetRecorderControllerProvider.notifier);

    await emit(frame(10, 3));
    await recorder.sampleNow(); // no take yet → session opens, no row
    final opened = c.read(datasetRecorderControllerProvider).active;
    expect(opened[GloveHand.left]!.rows, 0);

    await recorder.startTake('A');
    await emit(frame(11, 3));
    await recorder.sampleNow();
    expect(
        c.read(datasetRecorderControllerProvider).active[GloveHand.left]!.rows,
        1);

    await recorder.stopTake();
    await emit(frame(12, 3));
    await recorder.sampleNow();
    expect(
        c.read(datasetRecorderControllerProvider).active[GloveHand.left]!.rows,
        1);
  });

  test('an empty take label is blocked', () async {
    final c = makeContainer();
    await c
        .read(datasetRecorderControllerProvider.notifier)
        .startTake('   ');
    expect(c.read(datasetRecorderControllerProvider).error,
        AppStrings.recordNeedsLabel);
  });
}
