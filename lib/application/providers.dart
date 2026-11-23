import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import '../core/constants/app_version.dart';
import '../data/dataset/coverage_index.dart';
import '../data/dataset/dataset_file_writer.dart';
import '../data/glove/ble_diagnostics.dart';
import '../data/glove/glove_connection.dart';
import '../data/glove/glove_connection_factory.dart';
import '../data/glove/mock_glove_connection.dart';
import '../data/model/model_asset_loader.dart';
import '../data/storage/calinfo_cache.dart';
import '../data/storage/settings_service.dart';
import '../data/tts/flutter_tts_service.dart';
import '../data/tts/tts_service.dart';
import '../data/vocab/default_vocabulary_repository.dart';
import '../domain/classifier/model_bundle.dart';
import '../domain/models/telemetry_packet.dart';
import '../domain/repositories/log_store.dart';
import '../domain/repositories/vocabulary_repository.dart';
import '../domain/vocab/custom_word.dart';
import 'calibration_controller.dart';
import 'coverage_controller.dart';
import 'custom_words_controller.dart';
import 'dataset_recorder_controller.dart';
import 'export_controller.dart';
import 'glove_controller.dart';
import 'live_controller.dart';
import 'mount_calibration_controller.dart';
import 'recognition_controller.dart';
import 'settings_controller.dart';
import 'transcript_controller.dart';
import 'tts_controller.dart';

/// Composition root — every provider in one panel-readable file.
/// Layer rule: ui → application → domain ← data.

final vocabularyRepositoryProvider = Provider<VocabularyRepository>(
  (ref) => DefaultVocabularyRepository(ref.watch(customWordsProvider)),
);

final customWordsProvider =
    NotifierProvider<CustomWordsController, List<CustomWord>>(
        CustomWordsController.new);

final settingsServiceProvider = Provider<SettingsService>(
  (ref) => SharedPrefsSettingsService(),
);

/// Real [LogStore] is created by the app bootstrap (main.dart) after Hive
/// init; tests and widget pumps override this with an in-memory store.
final logStoreProvider = Provider<LogStore>(
  (ref) => throw UnimplementedError('logStoreProvider is overridden at '
      'startup (see main.dart) or in tests'),
);

/// The live Force-mock flag; toggling it swaps each glove's connection
/// class without a restart (bugfix: the toggle used to need one).
final forceMockProvider =
    NotifierProvider<ForceMockController, bool>(ForceMockController.new);

/// One connection per glove. The Force-mock flag selects the class; a
/// toggle rebuilds these providers and disposes the previous connection
/// (streams, timers, reconnect loops) before creating the new one. This is
/// the LEFT glove (keep area: the transcript/demo path is bound to it).
final gloveConnectionProvider = Provider<GloveConnection>((ref) {
  final forceMock = ref.watch(forceMockProvider);
  final connection = GloveConnectionFactory.create(forceMock: forceMock);
  ref.onDispose(connection.dispose);
  return connection;
});

/// The right glove's connection — same Force-mock-driven swap as the left.
final rightGloveConnectionProvider = Provider<GloveConnection>((ref) {
  final forceMock = ref.watch(forceMockProvider);
  final connection = GloveConnectionFactory.createForHand(GloveHand.right,
      forceMock: forceMock);
  ref.onDispose(connection.dispose);
  return connection;
});

/// Right glove's lifecycle controller: same phase/reconnect state machine
/// as [gloveControllerProvider], bound to [rightGloveConnectionProvider].
final rightGloveControllerProvider =
    NotifierProvider<GloveController, GloveState>(
        () => GloveController(Future<void>.delayed, rightGloveConnectionProvider));

/// True when the active connection is the simulated glove — gates the
/// dev-only demo controls. Watches the provider so a live swap re-gates.
final gloveIsMockProvider = Provider<bool>(
  (ref) => ref.watch(gloveConnectionProvider) is MockGloveConnection,
);

final gloveControllerProvider =
    NotifierProvider<GloveController, GloveState>(GloveController.new);

/// Per-hand BLE link diagnostics (fix B1): rendered by the Settings →
/// Developer panel. Watches the connections so a Force-mock swap rebinds.
final bleDiagnosticsProvider =
    Provider<Map<GloveHand, BleDiagnostics>>((ref) {
  final left = ref.watch(gloveConnectionProvider);
  final right = ref.watch(rightGloveConnectionProvider);
  return {
    GloveHand.left: left.diagnostics,
    GloveHand.right: right.diagnostics,
  };
});

/// Both gloves' live snapshots for the /live screen (master §6.1).
final liveControllerProvider =
    NotifierProvider<LiveController, LiveState>(LiveController.new);

/// Phone-side recognizer (C1): gate → classifier → stabilizer → events.
final recognitionControllerProvider =
    NotifierProvider<RecognitionController, RecognitionState>(
        RecognitionController.new);

/// The recognizer's event bus — the transcript consumes this alongside the
/// glove connection's own [GloveConnection.gestureResults] stream.
final recognitionEventBusProvider =
    Provider<RecognitionEventBus>((ref) => RecognitionEventBus());

/// Shipped model bundle (C4): labels.json + weights.json from assets.
/// Null = no usable model — the recognizer falls back to the C1
/// threshold rules, and the app works with no model present.
final modelBundleProvider = FutureProvider<ModelBundle?>(
    (ref) => ModelAssetLoader().load());

final appVersionProvider = Provider<String>((ref) => kAppVersion);

final ttsServiceProvider = Provider<TtsService>((ref) => FlutterTtsService());

final ttsControllerProvider =
    NotifierProvider<TtsController, TtsState>(TtsController.new);

final transcriptControllerProvider =
    NotifierProvider<TranscriptController, TranscriptState>(
        TranscriptController.new);

final settingsControllerProvider =
    NotifierProvider<SettingsController, SettingsState>(SettingsController.new);

/// Where FR-16 CSVs are written; overridden with a temp dir in tests.
/// Desktop/Android only — path_provider and dart:io have no web
/// implementation, so export fails fast there instead of throwing
/// MissingPluginException.
final exportDirectoryProvider = Provider<Future<Directory>>((ref) async {
  if (kIsWeb) {
    throw UnsupportedError('CSV export is desktop/Android only');
  }
  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory('${docs.path}/talkhimik_exports');
  await dir.create(recursive: true);
  return dir;
});

/// Dataset files (master §5.4): app-support dir, `talkhimik_dataset/`.
final datasetDirectoryProvider = Provider<Future<Directory>>((ref) async {
  if (kIsWeb) {
    throw UnsupportedError('Dataset recording is desktop/Android only');
  }
  final base = await getApplicationSupportDirectory();
  final dir = Directory('${base.path}/talkhimik_dataset');
  await dir.create(recursive: true);
  return dir;
});

/// The dataset CSV/sidecar writer; overridden with a temp dir in tests.
final datasetWriterProvider = Provider<DatasetFileWriter>(
  (ref) => DatasetFileWriter(() => ref.read(datasetDirectoryProvider)),
);

/// Dataset coverage index (C2) — derived cache over the session CSVs.
final coverageIndexStoreProvider = Provider<CoverageIndexStore>(
  (ref) => CoverageIndexStore(() => ref.read(datasetDirectoryProvider)),
);

final coverageControllerProvider =
    NotifierProvider<CoverageController, CoverageState>(
        CoverageController.new);

final datasetRecorderControllerProvider =
    NotifierProvider<DatasetRecorderController, RecorderState>(
        DatasetRecorderController.new);

final mountCalibrationControllerProvider =
    NotifierProvider<MountCalibrationController, MountCalibrationState>(
        MountCalibrationController.new);

final exportControllerProvider =
    NotifierProvider<ExportController, ExportState>(ExportController.new);

/// FR-8 (master §4.5): last-known CAL_INFO mirror per hand — the glove's
/// NVS stays the calibration authority; this cache only displays and feeds
/// sidecars. Overridden with an in-memory store in tests.
final calInfoCacheProvider = Provider<CalInfoCache>(
  (ref) => SharedPrefsCalInfoCache(),
);

final calibrationControllerProvider =
    NotifierProvider<CalibrationController, CalibrationState>(
        CalibrationController.new);
