import 'telemetry_packet.dart';

/// One calibration-aware recording session per (hand, calibration_id,
/// mount_calibration_id) (master §5.1) — files never mix calibrations.
class DatasetSession {
  DatasetSession({
    required this.sessionId,
    required this.signerId,
    required this.hand,
    required this.calibrationId,
    required this.firmwareVersion,
    required this.validMask,
    required this.rDiv,
    required this.fingers,
    required this.startedAt,
    this.mountCalibrationId,
    this.twoHand = false,
  });

  final String sessionId;

  /// Anonymized signer id (participantId or anon-XXXX) — never a name.
  final String signerId;

  final GloveHand hand;
  final int calibrationId;
  final String firmwareVersion;

  /// CAL_INFO valid mask at open; decides which columns exist.
  final int validMask;

  /// R_DIV values the profile was captured with (sidecar).
  final List<double> rDiv;

  /// Per-finger CAL_INFO blocks for the sidecar.
  final List<FingerInfo> fingers;

  final DateTime startedAt;

  /// STATUS mount_calibration_id at open (fw 1.3.0+); null for fw 1.2.0
  /// gloves or before the first STATUS arrived.
  final int? mountCalibrationId;

  /// Recorded in Both mode: this hand's half of a two-handed sign (the
  /// other glove's session shares label and take_id). Not trained yet.
  final bool twoHand;

  int rows = 0;
  int droppedFrames = 0;
  int adcRail = 0;
  int seqGapDrops = 0;
  int takeId = 0;
  String label = '';

  String get handTag => hand == GloveHand.left ? 'L' : 'R';
}

/// One finger's sidecar block (master §5.3) — includes invalid fingers so
/// the sidecar documents why columns are missing.
class FingerInfo {
  const FingerInfo({
    required this.name,
    required this.valid,
    required this.weak,
    required this.flatOhm,
    required this.bent90Ohm,
    required this.flatAdc,
    required this.bent90Adc,
    required this.spanCounts,
  });

  final String name;
  final bool valid;
  final bool weak;
  final double flatOhm;
  final double bent90Ohm;
  final int flatAdc;
  final int bent90Adc;
  final int spanCounts;

  Map<String, Object?> toJson() => {
        'valid': valid,
        'weak': weak,
        'flat_ohm': flatOhm,
        'bent90_ohm': bent90Ohm,
        'flat_adc': flatAdc,
        'bent90_adc': bent90Adc,
        'span_counts': spanCounts,
      };
}

/// One finished session as shown in the sessions list (newest first):
/// hand, signer, calibration_id, rows, dropped, size, [Share] [Delete].
class DatasetSessionSummary {
  const DatasetSessionSummary({
    required this.sessionId,
    required this.signerId,
    required this.hand,
    required this.calibrationId,
    required this.rows,
    required this.droppedFrames,
    required this.sizeBytes,
    required this.csvName,
    required this.sidecarName,
  });

  final String sessionId;
  final String signerId;
  final GloveHand hand;
  final int calibrationId;
  final int rows;
  final int droppedFrames;
  final int sizeBytes;

  /// File names inside the dataset directory (share/delete targets).
  final String csvName;
  final String sidecarName;

  String get handTag => hand == GloveHand.left ? 'L' : 'R';
}
