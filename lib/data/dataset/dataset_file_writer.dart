import 'dart:convert';
import 'dart:io';

import '../../core/utils/csv_exporter.dart';
import '../../domain/models/calibration_table.dart';
import '../../domain/models/dataset_row.dart';
import '../../domain/models/dataset_session.dart';
import '../../domain/models/telemetry_packet.dart';
import 'coverage_index.dart';

/// Writes the dataset files: one CSV per session (header per §5.2, appended
/// as rows arrive so a crash never loses a take) plus the sidecar JSON per
/// session (§5.3), finalized on close. Files land in the app-support
/// directory under `talkhimik_dataset/` (master §5.4).
class DatasetFileWriter {
  DatasetFileWriter(this._dirProvider);

  final Future<Directory> Function() _dirProvider;

  static String fileNameFor(GloveHand hand, String sessionId, int calId,
          {required bool sidecar}) =>
      'talkhimik_${hand == GloveHand.left ? 'L' : 'R'}'
      '_${sessionId}_cal$calId${sidecar ? '_sidecar.json' : '.csv'}';

  /// Creates the CSV and writes the header for [session]'s valid mask.
  Future<void> openSession(DatasetSession session) async {
    final dir = await _dirProvider();
    final file = File(
        '${dir.path}/${fileNameFor(session.hand, session.sessionId, session.calibrationId, sidecar: false)}');
    await file.writeAsString(CsvExporter.toCsv([_header(session)]));
  }

  /// Appends one row — written both to the in-memory buffer and the file.
  Future<void> appendRow(DatasetSession session, DatasetRow row) async {
    final dir = await _dirProvider();
    final file = File(
        '${dir.path}/${fileNameFor(session.hand, session.sessionId, session.calibrationId, sidecar: false)}');
    await file.writeAsString(
        CsvExporter.toCsv([_row(session, row)]),
        mode: FileMode.append);
  }

  /// Deletes every row of take [takeId] from [session]'s CSV (undo);
  /// returns how many rows were removed.
  Future<int> removeTake(DatasetSession session, int takeId) async {
    final dir = await _dirProvider();
    final file = File(
        '${dir.path}/${fileNameFor(session.hand, session.sessionId, session.calibrationId, sidecar: false)}');
    if (!await file.exists()) return 0;
    final lines = await file.readAsLines();
    if (lines.isEmpty) return 0;
    final takeCol = CoverageIndexStore.splitCsv(lines.first).indexOf('take_id');
    final kept = [
      lines.first,
      for (final line in lines.skip(1))
        if (line.isNotEmpty &&
            CoverageIndexStore.splitCsv(line)[takeCol] != '$takeId')
          line,
    ];
    final removed = lines.where((l) => l.isNotEmpty).length - kept.length;
    if (removed > 0) await file.writeAsString('${kept.join('\r\n')}\r\n');
    return removed;
  }

  /// Finalizes the sidecar JSON with the final counters.
  Future<void> closeSession(DatasetSession session) async {
    final dir = await _dirProvider();
    final file = File(
        '${dir.path}/${fileNameFor(session.hand, session.sessionId, session.calibrationId, sidecar: true)}');
    await file.writeAsString(jsonEncode(_sidecar(session)));
  }

  Future<void> deleteSession(DatasetSessionSummary summary) async {
    final dir = await _dirProvider();
    for (final name in [summary.csvName, summary.sidecarName]) {
      final file = File('${dir.path}/$name');
      if (await file.exists()) await file.delete();
    }
  }

  /// Deletes every dataset file (CSVs, sidecars, index.json) — the reset.
  Future<void> deleteAll() async {
    final dir = await _dirProvider();
    if (!await dir.exists()) return;
    await for (final entity in dir.list()) {
      if (entity is File) await entity.delete();
    }
  }

  /// Writes a sidecar for every CSV that lacks one (the app was killed
  /// before Stop), rebuilt from the CSV itself so it can be listed and
  /// shared. Only what the CSV proves is written: a finger is valid when
  /// its ang_ column exists; `recovered: true` marks the guesswork-free
  /// subset. Returns how many were recovered.
  Future<int> recoverSidecars() async {
    final dir = await _dirProvider();
    if (!await dir.exists()) return 0;
    var recovered = 0;
    await for (final entity in dir.list()) {
      if (entity is! File || !entity.path.endsWith('.csv')) continue;
      final base = entity.path.substring(0, entity.path.length - 4);
      final sidecar = File('${base}_sidecar.json');
      if (await sidecar.exists()) continue;
      try {
        final lines =
            (await entity.readAsLines()).where((l) => l.isNotEmpty).toList();
        if (lines.length < 2) continue; // header only: nothing to save
        final header = CoverageIndexStore.splitCsv(lines.first);
        final first = CoverageIndexStore.splitCsv(lines[1]);
        String col(String name) => first[header.indexOf(name)];
        await sidecar.writeAsString(jsonEncode({
          'session_id': col('session_id'),
          'signer_id': col('signer_id'),
          'hand': col('hand'),
          'calibration_id': int.parse(col('calibration_id')),
          'sample_rate_hz': 5,
          'rows': lines.length - 1,
          'dropped_frames': 0,
          'recovered': true,
          'fingers': {
            for (final f in fingerNames)
              f: {'valid': header.contains('ang_$f')},
          },
        }));
        recovered++;
      } catch (_) {
        // Malformed CSV: leave it alone rather than write a wrong sidecar.
      }
    }
    return recovered;
  }

  /// Sessions on disk, newest first (master §5.4), rebuilt from sidecars.
  Future<List<DatasetSessionSummary>> listSessions() async {
    final dir = await _dirProvider();
    if (!await dir.exists()) return const [];
    final summaries = <DatasetSessionSummary>[];
    await for (final entity in dir.list()) {
      if (entity is! File || !entity.path.endsWith('_sidecar.json')) continue;
      try {
        final sidecar = jsonDecode(await entity.readAsString())
            as Map<String, Object?>;
        final sidecarName = entity.uri.pathSegments.last;
        final base = sidecarName.substring(
            0, sidecarName.length - '_sidecar.json'.length);
        final csvFile = File('${dir.path}/$base.csv');
        summaries.add(DatasetSessionSummary(
          sessionId: sidecar['session_id'] as String,
          signerId: sidecar['signer_id'] as String,
          hand: sidecar['hand'] == 'L' ? GloveHand.left : GloveHand.right,
          calibrationId: sidecar['calibration_id'] as int,
          rows: sidecar['rows'] as int,
          droppedFrames: sidecar['dropped_frames'] as int,
          sizeBytes: await csvFile.exists() ? await csvFile.length() : 0,
          csvName: '$base.csv',
          sidecarName: sidecarName,
        ));
      } catch (_) {
        // Corrupt sidecar — skip; the list must not take the screen down.
      }
    }
    // Newest first: session ids embed a millisecond timestamp.
    summaries.sort((a, b) => b.sessionId.compareTo(a.sessionId));
    return summaries;
  }

  /// Absolute paths of a session's two files (share targets).
  Future<List<String>> pathsFor(DatasetSessionSummary summary) async {
    final dir = await _dirProvider();
    return [
      '${dir.path}/${summary.csvName}',
      '${dir.path}/${summary.sidecarName}',
    ];
  }

  // -------------------------------------------------------------- internals

  /// Valid fingers in order, thumb first within each group (master §5.2).
  List<int> _validFingers(DatasetSession session) => [
        for (var i = 0; i < fingerNames.length; i++)
          if (session.validMask & (1 << i) != 0) i,
      ];

  List<String> _header(DatasetSession session) {
    final valid = _validFingers(session);
    return [
      'timestamp_ms',
      'session_id',
      'signer_id',
      'hand',
      'calibration_id',
      'label',
      'take_id',
      for (final i in valid) 'raw_${fingerNames[i]}',
      for (final i in valid) 'ohm_${fingerNames[i]}',
      for (final i in valid) 'ang_${fingerNames[i]}',
      'roll',
      'pitch',
      'yaw',
      'quality_flag',
    ];
  }

  List<String> _row(DatasetSession session, DatasetRow row) {
    final valid = _validFingers(session);
    return [
      '${row.timestampMs}',
      session.sessionId,
      session.signerId,
      session.handTag,
      '${session.calibrationId}',
      row.label,
      '${row.takeId}',
      for (final i in valid) '${row.rawAdc[i]}',
      for (final i in valid) row.ohms[i].toStringAsFixed(2),
      for (final i in valid) row.angles[i].toStringAsFixed(2),
      row.rollDeg.toStringAsFixed(1),
      row.pitchDeg.toStringAsFixed(1),
      row.yawDeg.toStringAsFixed(1),
      '${row.qualityFlag}',
    ];
  }

  Map<String, Object?> _sidecar(DatasetSession session) => {
        'session_id': session.sessionId,
        'signer_id': session.signerId,
        'hand': session.handTag,
        'calibration_id': session.calibrationId,
        'mount_calibration_id': session.mountCalibrationId,
        'two_hand': session.twoHand,
        // Same wording as the web dashboard's sidecar.
        'roll_note': 'roll wraps at +/-180; use sin/cos(roll) or the '
            'gravity vector as ML features',
        'sample_rate_hz': 5,
        'firmware_version': session.firmwareVersion,
        'recorded_at': session.startedAt.toIso8601String(),
        'rows': session.rows,
        'dropped_frames': session.droppedFrames,
        'dropped': {'adcRail': session.adcRail, 'seqGap': session.seqGapDrops},
        'r_div': session.rDiv,
        'fingers': {
          for (final f in session.fingers) f.name: f.toJson(),
        },
      };
}
