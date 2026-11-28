import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/glove/glove_connection.dart';
import '../domain/classifier/classifier_factory.dart';
import '../domain/classifier/gesture_classifier.dart';
import '../domain/classifier/hand_frame.dart';
import '../domain/classifier/mlp_classifier.dart';
import '../domain/classifier/model_bundle.dart';
import '../domain/classifier/motion_gate.dart';
import '../domain/classifier/prediction.dart';
import '../domain/classifier/recognition_constants.dart';
import '../domain/classifier/refuse_gate.dart';
import '../domain/classifier/stabilizer.dart';
import '../domain/classifier/threshold_classifier.dart';
import '../domain/models/gesture_result.dart';
import '../domain/models/telemetry_packet.dart';
import 'live_controller.dart';
import 'providers.dart';

/// Phone-side recognition events — the SAME stream shape the glove's
/// label packets use, consumed by the SAME transcript path.
class RecognitionEventBus {
  final StreamController<GestureResultPacket> _events =
      StreamController<GestureResultPacket>.broadcast();

  Stream<GestureResultPacket> get stream => _events.stream;

  void add(GestureResultPacket packet) => _events.add(packet);
}

/// Everything the recognition debug panel shows (C1.5).
class RecognitionState {
  const RecognitionState({
    this.enabled = false,
    this.pausedForLabelPackets = false,
    this.signingHandPref = 'auto',
    this.activeHand,
    this.classifier = '',
    this.modelVersion = '',
    this.modelTrainedOn,
    this.rawClass,
    this.rawLabel,
    this.rawConfidence,
    this.top3 = const [],
    this.voteCount = 0,
    this.blockedReason,
    this.lastEmittedLabel,
  });

  /// True while the recognizer is processing real-glove frames (user
  /// toggle on, not mock). False otherwise.
  final bool enabled;

  /// A real glove label packet arrived — the phone recognizer stands down
  /// (glove takes precedence). Cleared on disconnect.
  final bool pausedForLabelPackets;

  /// Persisted preference: 'auto' | 'left' | 'right'.
  final String signingHandPref;

  /// Hand currently being classified, or null when none is connected.
  final GloveHand? activeHand;

  /// Active classifier name ('phone-threshold' until C4).
  final String classifier;

  final String modelVersion;

  /// One-line trained-on summary from labels.json (C4); null for the
  /// stand-in or when no model shipped.
  final String? modelTrainedOn;

  /// Last raw class/letter/confidence BEFORE stabilization.
  final String? rawClass;
  final String? rawLabel;
  final double? rawConfidence;

  /// Top-3 alternatives when the classifier provides them (empty for the
  /// stand-in; the C4 model fills this).
  final List<String> top3;

  /// Stabilizer majority votes for the latest frame.
  final int voteCount;

  /// Why nothing can be emitted right now:
  /// 'uncalibrated' | 'stale' | 'invalid finger' | 'released' | null.
  final String? blockedReason;

  /// Last letter the recognizer emitted to the transcript.
  final String? lastEmittedLabel;

  RecognitionState copyWith({
    bool? enabled,
    bool? pausedForLabelPackets,
    String? signingHandPref,
    GloveHand? activeHand,
    String? classifier,
    String? modelVersion,
    String? modelTrainedOn,
    String? rawClass,
    String? rawLabel,
    double? rawConfidence,
    List<String>? top3,
    int? voteCount,
    String? blockedReason,
    String? lastEmittedLabel,
  }) =>
      RecognitionState(
        enabled: enabled ?? this.enabled,
        pausedForLabelPackets:
            pausedForLabelPackets ?? this.pausedForLabelPackets,
        signingHandPref: signingHandPref ?? this.signingHandPref,
        activeHand: activeHand ?? this.activeHand,
        classifier: classifier ?? this.classifier,
        modelVersion: modelVersion ?? this.modelVersion,
        modelTrainedOn: modelTrainedOn ?? this.modelTrainedOn,
        rawClass: rawClass ?? this.rawClass,
        rawLabel: rawLabel ?? this.rawLabel,
        rawConfidence: rawConfidence ?? this.rawConfidence,
        top3: top3 ?? this.top3,
        voteCount: voteCount ?? this.voteCount,
        blockedReason: blockedReason ?? this.blockedReason,
        lastEmittedLabel: lastEmittedLabel ?? this.lastEmittedLabel,
      );
}

/// The C1 recognizer: signing-hand frames → gate → classifier → stabilizer
/// → [RecognitionEventBus] → the existing transcript path.
///
/// OFF entirely when the mock glove is active (the mock drives its own
/// transcript) and when the Developer toggle is off. Label packets from
/// either glove pause it: the glove takes precedence.
class RecognitionController extends Notifier<RecognitionState> {
  final List<StreamSubscription<Object?>> _subs = [];
  final Stabilizer _stabilizer = Stabilizer();
  final MotionGate _motion = MotionGate();
  final ClassifierFactory _factory = const ClassifierFactory();
  final Map<GloveHand, (ModelBundle?, GestureClassifier)> _classifiers = {};
  DartMlpClassifier? _twoHand;
  bool _userEnabled = true; // Developer toggle, default ON

  @override
  RecognitionState build() {
    final mock = ref.watch(gloveIsMockProvider);
    _bind(ref.watch(gloveConnectionProvider));
    _bind(ref.watch(rightGloveConnectionProvider));
    ref.listen(liveControllerProvider, (prev, next) => _onLive(next));
    // The settings controller owns these prefs; watch them so a change on
    // the Settings screen reaches the recognizer immediately.
    ref.listen(settingsControllerProvider.select((s) => s.signingHand),
        (prev, next) => state = state.copyWith(signingHandPref: next));
    ref.listen(
        settingsControllerProvider.select((s) => s.phoneRecognitionEnabled),
        (prev, next) => _userEnabled = next);
    ref.onDispose(() {
      for (final s in _subs) {
        unawaited(s.cancel());
      }
    });
    if (mock) _stabilizer.reset();
    return RecognitionState(
      classifier: RecognitionConstants.thresholdSource,
      modelVersion: RecognitionConstants.thresholdModelVersion,
    );
  }

  void _bind(GloveConnection connection) {
    _subs.add(connection.gestureResults.listen((_) => _onLabelPacket()));
    _subs.add(connection.phaseChanges.listen((phase) {
      if (phase != GloveConnectionPhase.ready) _onDisconnect();
    }));
  }

  /// Glove label packets take precedence: pause phone recognition until
  /// the next disconnect (glove packets keep flowing through the normal
  /// transcript path untouched).
  void _onLabelPacket() {
    _stabilizer.reset();
    state = state.copyWith(pausedForLabelPackets: true);
  }

  void _onDisconnect() {
    _stabilizer.reset();
    _motion.reset();
    state = state.copyWith(
      pausedForLabelPackets: false,
      activeHand: null,
      blockedReason: null,
      rawClass: null,
      rawLabel: null,
      rawConfidence: null,
      voteCount: 0,
    );
  }

  void _onLive(LiveState live) {
    if (state.pausedForLabelPackets) return;
    if (ref.read(gloveIsMockProvider)) return; // mock drives its transcript
    if (!_userEnabled) {
      _stabilizer.reset();
      state = state.copyWith(enabled: false);
      return;
    }

    final now = DateTime.now();
    final hand = _resolveHand(live);
    final handState = hand == null ? null : live.forHand(hand);
    final telemetry = handState?.telemetry;
    final bundle = ref.read(modelBundleProvider).value;
    final classifier = _classifierFor(hand, bundle);

    state = state.copyWith(
      enabled: true,
      activeHand: hand,
      classifier: classifier.source,
      modelVersion: classifier.modelVersion,
      modelTrainedOn: bundle?.labels.trainedOnSummary,
    );
    if (telemetry == null) {
      if (hand == null) _stabilizer.reset();
      return;
    }

    final frame = HandFrame.fromTelemetry(
      telemetry,
      uncalibrated: handState!.uncalibrated,
    );
    final gate = RefuseGate.evaluate(frame, now: now);
    if (gate == GateReason.stale) {
      _stabilizer.reset();
      state = state.copyWith(
        blockedReason: 'stale',
        rawClass: null,
        rawLabel: null,
        rawConfidence: null,
        voteCount: 0,
      );
      return;
    }
    if (gate != GateReason.none) {
      // Refuse, never guess: the frame is dropped entirely.
      state = state.copyWith(
        blockedReason: switch (gate) {
          GateReason.uncalibrated => 'uncalibrated',
          GateReason.invalidFinger => 'invalid finger',
          _ => null,
        },
      );
      return;
    }

    _motion.add(now, frame.pitchDeg, rollDeg: frame.rollDeg);
    var prediction = classifier.classifyFrame(frame);
    var floor = classifier.confidenceFloor;
    var rest = classifier.restLabel;
    var labels = bundle?.labels;
    // Both gloves on: a confident two-hand word always beats the one-hand
    // guess — it saw the left hand too (e.g. Maraming Salamat's right hand
    // alone looks like Salamat).
    final two = _twoHandPrediction(live, now);
    if (two != null) {
      final (p, spec) = two;
      if (p.label != spec.restClass && p.confidence >= spec.confidenceFloor) {
        prediction = p;
        floor = spec.confidenceFloor;
        rest = spec.restClass;
        labels = spec;
      }
    }
    // Trained-model semantics: below the confidence floor or the REST
    // class counts as neutral (a release), never an emission (concept
    // C5). The stand-in has no floor/REST and never reaches here with a
    // null prediction anyway.
    String? stabilizerLabel;
    if (prediction != null) {
      final belowFloor = floor != null && prediction.confidence < floor;
      final isRest = rest != null && prediction.label == rest;
      // A moving sign without its movement is not that sign: neutral.
      // shortcut: the movement check follows the signing hand's frames,
      // which matches two-hand paths only when that is the right glove.
      final still = !_motion.allows(
          prediction.label,
          labels?.motionPitchSpan ?? const {},
          labels?.motionPaths ?? const {});
      stabilizerLabel =
          (belowFloor || isRest || still) ? null : prediction.label;
    }
    final result = _stabilizer.addFrame(stabilizerLabel, now);
    state = state.copyWith(
      rawClass: prediction?.className,
      rawLabel: prediction?.label,
      rawConfidence: prediction?.confidence,
      top3: prediction?.top3 ?? const [],
      voteCount: result.voteCount,
      blockedReason: result.neutralReleased && result.majorityLabel == null
          ? 'released'
          : null,
    );

    final emitLabel = result.emitLabel;
    if (emitLabel == null) return;
    // One movement, one emission: repeating the sign needs a new movement.
    if (labels?.motionPaths.containsKey(emitLabel) ?? false) {
      _motion.reset();
    }
    // Read now, not at build: words can be added while the app runs.
    final vocab = ref.read(vocabularyRepositoryProvider);
    final wordId = [...vocab.letters, ...vocab.phrases]
        .where((e) => e.filipino == emitLabel)
        .firstOrNull
        ?.wordId;
    if (wordId == null) return;
    final confidence = (result.voteShare * (prediction?.confidence ?? 0) * 100)
        .round()
        .clamp(0, 100);
    ref.read(recognitionEventBusProvider).add(GestureResultPacket(
          wordId: wordId,
          confidence: confidence,
          gloveTimestampMs: now.millisecondsSinceEpoch,
          receivedAt: now,
          source: classifier.source,
          modelVersion: classifier.modelVersion,
        ));
    state = state.copyWith(lastEmittedLabel: emitLabel);
  }

  /// The classifier for the signing hand, cached until the model bundle
  /// or the hand changes. A bundle for the wrong hand falls back to the
  /// threshold rules (ClassifierFactory).
  GestureClassifier _classifierFor(GloveHand? hand, ModelBundle? bundle) {
    if (hand == null) return const ThresholdClassifier();
    final cached = _classifiers[hand];
    if (cached != null && identical(cached.$1, bundle)) return cached.$2;
    final classifier = _factory.create(bundle, hand);
    _classifiers[hand] = (bundle, classifier);
    return classifier;
  }

  /// The two-hand model's guess when it shipped and both gloves send
  /// gate-clean frames; null otherwise.
  (Prediction, LabelsSpec)? _twoHandPrediction(LiveState live, DateTime now) {
    final bundle = ref.read(twoHandModelBundleProvider).value;
    final l = live.left.telemetry;
    final r = live.right.telemetry;
    if (bundle == null || l == null || r == null) return null;
    final lf = HandFrame.fromTelemetry(l, uncalibrated: live.left.uncalibrated);
    final rf =
        HandFrame.fromTelemetry(r, uncalibrated: live.right.uncalibrated);
    if (RefuseGate.evaluate(lf, now: now) != GateReason.none ||
        RefuseGate.evaluate(rf, now: now) != GateReason.none) {
      return null;
    }
    if (_twoHand?.bundle != bundle) _twoHand = DartMlpClassifier(bundle);
    final p = _twoHand!.classifyPair(lf, rf);
    return p == null ? null : (p, bundle.labels);
  }

  /// Signing hand per the preference: manual hands are used as chosen;
  /// Auto = the only connected glove (one that has received telemetry),
  /// else Right when both have. Freshness is deliberately NOT part of
  /// this rule — a connected-but-stale glove still resolves here so the
  /// gate can report 'stale' instead of the panel showing "no hand".
  GloveHand? _resolveHand(LiveState live) {
    switch (state.signingHandPref) {
      case 'left':
        return GloveHand.left;
      case 'right':
        return GloveHand.right;
      default:
        final leftLive = live.left.telemetry != null;
        final rightLive = live.right.telemetry != null;
        if (leftLive && rightLive) return GloveHand.right;
        if (leftLive) return GloveHand.left;
        if (rightLive) return GloveHand.right;
        return null;
    }
  }
}
