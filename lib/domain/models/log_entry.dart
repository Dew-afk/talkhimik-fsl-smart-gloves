import 'package:meta/meta.dart';

/// One logged recognition event (SRS FR-10). The CSV export columns mirror
/// this class 1:1, so field order here is the export contract.
@immutable
class GestureLogEntry {
  const GestureLogEntry({
    this.id,
    required this.participantId,
    required this.sessionId,
    required this.wordId,
    required this.filipinoText,
    required this.englishText,
    required this.confidence,
    required this.confidenceLevel,
    required this.latencyMs,
    required this.gloveTimestampMs,
    required this.receivedAt,
    this.corrected = false,
    this.originalWordId,
    required this.source,
    required this.appVersion,
    this.modelVersion = 'n/a',
  });

  /// Hive auto-increment key; null until the store assigns one.
  final int? id;

  /// Anonymized participant id (FR-13, DR-4) — never a name.
  final String participantId;

  /// Session key, e.g. "S-20260909-143000" (created at session start).
  final String sessionId;

  final int wordId;
  final String filipinoText;
  final String englishText;

  /// Glove confidence 0–100.
  final int confidence;

  /// green | amber | red — precomputed so exports never re-derive rules.
  final String confidenceLevel;

  /// End-to-end latency estimate (NFR-1); see GestureResultPacket.latencyMs
  /// for the clock-skew caveat.
  final int latencyMs;

  final int gloveTimestampMs;
  final DateTime receivedAt;

  /// True when a FR-5 correction produced this row.
  final bool corrected;

  /// Glove word id before the correction; null when not corrected.
  final int? originalWordId;

  /// glove | mock | correction
  final String source;

  final String appVersion;

  /// Model version from the FR-14 registry; "n/a" until Firebase exists.
  final String modelVersion;

  /// Copy with the Hive key attached after insertion.
  GestureLogEntry withId(int newId) => GestureLogEntry(
        id: newId,
        participantId: participantId,
        sessionId: sessionId,
        wordId: wordId,
        filipinoText: filipinoText,
        englishText: englishText,
        confidence: confidence,
        confidenceLevel: confidenceLevel,
        latencyMs: latencyMs,
        gloveTimestampMs: gloveTimestampMs,
        receivedAt: receivedAt,
        corrected: corrected,
        originalWordId: originalWordId,
        source: source,
        appVersion: appVersion,
        modelVersion: modelVersion,
      );
}

/// One entry of the offline sync queue (SRS FR-10, C-S4).
///
/// Log rows are queued here for a future cloud upload (not built).
@immutable
class SyncQueueEntry {
  const SyncQueueEntry({
    this.id,
    required this.logEntryId,
    required this.createdAt,
  });

  final int? id;
  final int logEntryId;
  final DateTime createdAt;
}

/// Header row for a logging session (SRS FR-10; drives the FR-16 export
/// listing).
@immutable
class SessionMeta {
  const SessionMeta({
    required this.sessionId,
    required this.participantId,
    required this.startedAt,
  });

  final String sessionId;
  final String participantId;
  final DateTime startedAt;
}

/// Session id helper: "S-yyyyMMdd-HHmmss" (SRS FR-10 session field).
String newSessionId([DateTime? now]) {
  final t = now ?? DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  return 'S-${t.year}${two(t.month)}${two(t.day)}'
      '-${two(t.hour)}${two(t.minute)}${two(t.second)}';
}
