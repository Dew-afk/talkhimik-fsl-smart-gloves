import 'dart:convert';
import 'dart:io';

/// Coverage targets and thresholds — THE constants for the dataset
/// coverage card (C2). "X of Y letters ready" counts labels at
/// [okAtOrAbove] takes or more. J and Z train like any letter (motion-gated
/// in the app), so they count.
class CoverageThresholds {
  CoverageThresholds._();

  /// Below this a label "needs data".
  static const int okAtOrAbove = 5;

  /// At or above this a label is "good".
  static const int goodAtOrAbove = 10;
}

/// The special REST label as stored in CSV files.
const String restLabel = '_rest';

/// Wrong moves are recorded to TEST the model, never to train it (ml/ skips
/// them). One per moving word, plus everyday moves shared by every word.
const String randomMovesLabel = '_random';

String wrongLabelFor(String word) => '_wrong_$word';

/// Chip state for one label on the coverage card (icon + number, never
/// color alone).
enum CoverageLevel { needsData, ok, good }

CoverageLevel coverageLevelFor(String label, int takes) =>
    takes >= CoverageThresholds.goodAtOrAbove
            ? CoverageLevel.good
            : takes >= CoverageThresholds.okAtOrAbove
                ? CoverageLevel.ok
                : CoverageLevel.needsData;

/// Aggregated stats for one label across every session CSV.
class LabelCoverage {
  LabelCoverage({
    required this.takes,
    required this.rows,
    required this.hands,
    required this.calibrationIds,
    required this.signers,
  });

  factory LabelCoverage.fromJson(Map<String, Object?> json) => LabelCoverage(
        takes: json['takes'] as int? ?? 0,
        rows: json['rows'] as int? ?? 0,
        hands: (json['hands'] as List? ?? const []).cast<String>().toSet(),
        calibrationIds:
            (json['calibration_ids'] as List? ?? const []).cast<int>().toSet(),
        signers: (json['signers'] as List? ?? const []).cast<String>().toSet(),
      );

  /// Distinct takes: one (session, take_id) pair per recorded take.
  int takes;

  int rows;
  final Set<String> hands;
  final Set<int> calibrationIds;
  final Set<String> signers;

  Map<String, Object?> toJson() => {
        'takes': takes,
        'rows': rows,
        'hands': hands.toList()..sort(),
        'calibration_ids': calibrationIds.toList()..sort(),
        'signers': signers.toList()..sort(),
      };
}

/// The coverage index: per-label stats plus when it was built.
class CoverageIndex {
  CoverageIndex({required this.labels, required this.updatedAt});

  factory CoverageIndex.fromJson(Map<String, Object?> json) => CoverageIndex(
        labels: {
          for (final e in (json['labels'] as Map<String, Object?>? ?? {}).entries)
            e.key: LabelCoverage.fromJson(e.value as Map<String, Object?>),
        },
        updatedAt: DateTime.fromMillisecondsSinceEpoch(
            json['updated_at'] as int? ?? 0),
      );

  final Map<String, LabelCoverage> labels;
  final DateTime updatedAt;

  int get totalTakes =>
      labels.values.fold(0, (sum, c) => sum + c.takes);

  int get restTakes => labels[restLabel]?.takes ?? 0;

  /// Labels with ≥ [CoverageThresholds.okAtOrAbove] takes — the "X of Y
  /// letters ready" numerator.
  int readyCount(List<String> targets) => targets
      .where((l) => (labels[l]?.takes ?? 0) >= CoverageThresholds.okAtOrAbove)
      .length;

  Map<String, Object?> toJson() => {
        'updated_at': updatedAt.millisecondsSinceEpoch,
        'labels': {
          for (final e in labels.entries.toList()
            ..sort((a, b) => a.key.compareTo(b.key)))
            e.key: e.value.toJson(),
        },
      };
}

/// Reads/writes `index.json` in the dataset directory and rebuilds it from
/// the session CSVs. The CSV/sidecar formats are untouched — the index is
/// a derived cache only.
class CoverageIndexStore {
  CoverageIndexStore(this._dirProvider);

  final Future<Directory> Function() _dirProvider;

  static const String fileName = 'index.json';

  /// Loads the index; a missing or corrupt file triggers a rebuild so the
  /// UI always has something truthful to show.
  Future<CoverageIndex> load() async {
    try {
      final dir = await _dirProvider();
      final file = File('${dir.path}/$fileName');
      if (await file.exists()) {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map<String, Object?>) {
          return CoverageIndex.fromJson(decoded);
        }
      }
    } catch (_) {
      // Missing/corrupt → fall through to a fresh rebuild.
    }
    return rebuild();
  }

  /// Scans every session CSV and rewrites index.json. Runs at take stop —
  /// rows are appended as recorded, so the CSV is always current.
  Future<CoverageIndex> rebuild() async {
    final dir = await _dirProvider();
    final labels = <String, LabelCoverage>{};

    void bump(String label, void Function(LabelCoverage c) apply) {
      final c = labels.putIfAbsent(label, () => LabelCoverage(
            takes: 0,
            rows: 0,
            hands: <String>{},
            calibrationIds: <int>{},
            signers: <String>{},
          ));
      apply(c);
    }

    if (await dir.exists()) {
      await for (final entity in dir.list()) {
        if (entity is! File || !entity.path.endsWith('.csv')) continue;
        try {
          final lines = await entity.readAsLines();
          if (lines.isEmpty) continue;
          final header = splitCsv(lines.first);
          final sessionCol = header.indexOf('session_id');
          final signerCol = header.indexOf('signer_id');
          final handCol = header.indexOf('hand');
          final calCol = header.indexOf('calibration_id');
          final labelCol = header.indexOf('label');
          final takeCol = header.indexOf('take_id');
          if (sessionCol < 0 || labelCol < 0 || takeCol < 0) continue;

          final takesSeen = <String>{};
          for (final line in lines.skip(1)) {
            final fields = splitCsv(line);
            final label = fields[labelCol];
            final takeKey = '${fields[sessionCol]}|${fields[takeCol]}';
            final isNewTake = takesSeen.add('$label|$takeKey');
            bump(label, (c) {
              if (isNewTake) c.takes++;
              c.rows++;
              if (handCol >= 0) c.hands.add(fields[handCol]);
              if (calCol >= 0) {
                c.calibrationIds.add(int.tryParse(fields[calCol]) ?? 0);
              }
              if (signerCol >= 0) c.signers.add(fields[signerCol]);
            });
          }
        } catch (_) {
          // A corrupt CSV is skipped — the index must not take the screen
          // down; the session list reports it separately.
        }
      }
    }

    final index = CoverageIndex(labels: labels, updatedAt: DateTime.now());
    final file = File('${dir.path}/$fileName');
    await file.writeAsString(jsonEncode(index.toJson()));
    return index;
  }

  /// Minimal RFC 4180 splitter mirroring [CsvExporter]'s quoting (quoted
  /// fields may contain commas; embedded quotes are doubled).
  static List<String> splitCsv(String line) {
    final fields = <String>[];
    final buf = StringBuffer();
    var inQuotes = false;
    for (var i = 0; i < line.length; i++) {
      final c = line[i];
      if (inQuotes) {
        if (c == '"') {
          if (i + 1 < line.length && line[i + 1] == '"') {
            buf.write('"');
            i++;
          } else {
            inQuotes = false;
          }
        } else {
          buf.write(c);
        }
      } else if (c == '"') {
        inQuotes = true;
      } else if (c == ',') {
        fields.add(buf.toString());
        buf.clear();
      } else {
        buf.write(c);
      }
    }
    fields.add(buf.toString());
    return fields;
  }
}
