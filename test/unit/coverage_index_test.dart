import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:talkhimik_app/data/dataset/coverage_index.dart';

/// Writes a session CSV with the standard §5.2 header shape (7 fixed
/// columns + one finger triple) so the store's parser runs against
/// realistic files.
Future<void> writeSessionCsv(
  Directory dir,
  String name,
  List<List<String>> rows, {
  List<String> extraHeader = const ['raw_thumb', 'ohm_thumb', 'ang_thumb'],
}) async {
  final header = [
    'timestamp_ms',
    'session_id',
    'signer_id',
    'hand',
    'calibration_id',
    'label',
    'take_id',
    ...extraHeader,
  ];
  final lines = [
    header.join(','),
    for (final r in rows) ...[
      // Row columns: ts, session, signer, hand, cal, label, take,
      // padding for the finger columns.
      [
        ...r,
        for (var i = 0; i < extraHeader.length; i++) '0',
      ].join(','),
    ],
  ];
  await File('${dir.path}/$name').writeAsString(lines.join('\r\n'));
}

void main() {
  late Directory dir;
  late CoverageIndexStore store;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('talkhimik_coverage_test');
    store = CoverageIndexStore(() => Future.value(dir));
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('rebuild aggregates takes, rows, hands, calibration ids, and '
      'signers per label from the CSVs', () async {
    await writeSessionCsv(dir, 'talkhimik_L_S-1_cal3.csv', [
      ['1000', 'S-1', 'P-001', 'L', '3', 'A', '1'],
      ['1200', 'S-1', 'P-001', 'L', '3', 'A', '1'],
      ['1400', 'S-1', 'P-001', 'L', '3', 'A', '2'],
      ['1600', 'S-1', 'P-001', 'L', '3', '_rest', '3'],
    ]);
    await writeSessionCsv(dir, 'talkhimik_R_S-2_cal7.csv', [
      ['1000', 'S-2', 'P-002', 'R', '7', 'A', '1'],
      ['1200', 'S-2', 'P-002', 'R', '7', 'B', '1'],
    ]);

    final index = await store.rebuild();

    final a = index.labels['A']!;
    expect(a.takes, 3); // (S-1,1), (S-1,2), (S-2,1)
    expect(a.rows, 4);
    expect(a.hands, {'L', 'R'});
    expect(a.calibrationIds, {3, 7});
    expect(a.signers, {'P-001', 'P-002'});
    expect(index.labels['B']!.takes, 1);
    expect(index.labels['_rest']!.takes, 1);
    expect(index.totalTakes, 5);
    expect(index.restTakes, 1);
  });

  test('labels containing commas parse through the RFC 4180 quoting',
      () async {
    final quoted = '"${'Salamat, po'}"';
    await writeSessionCsv(dir, 'talkhimik_L_S-1_cal3.csv', [
      ['1000', 'S-1', 'P-001', 'L', '3', quoted, '1'],
      ['1200', 'S-1', 'P-001', 'L', '3', quoted, '1'],
    ]);

    final index = await store.rebuild();
    expect(index.labels['Salamat, po']!.takes, 1);
    expect(index.labels['Salamat, po']!.rows, 2);
  });

  test('load() returns the stored index and rebuilds a missing or corrupt '
      'one', () async {
    // Empty dir → load builds a fresh empty index and writes it.
    final first = await store.load();
    expect(first.labels, isEmpty);
    expect(await File('${dir.path}/index.json').exists(), isTrue);

    // Corrupt index.json → load rebuilds from the CSVs instead.
    await File('${dir.path}/index.json').writeAsString('not json');
    await writeSessionCsv(dir, 'talkhimik_L_S-1_cal3.csv', [
      ['1000', 'S-1', 'P-001', 'L', '3', 'A', '1'],
    ]);
    final rebuilt = await store.load();
    expect(rebuilt.labels['A']!.takes, 1);
  });

  test('thresholds: <5 needs data, 5–9 ok, >=10 good', () {
    expect(coverageLevelFor('A', 4), CoverageLevel.needsData);
    expect(coverageLevelFor('A', 5), CoverageLevel.ok);
    expect(coverageLevelFor('A', 9), CoverageLevel.ok);
    expect(coverageLevelFor('A', 10), CoverageLevel.good);
    expect(coverageLevelFor('J', 10), CoverageLevel.good); // motion-gated
    expect(coverageLevelFor('Z', 0), CoverageLevel.needsData);
  });

  test('readyCount counts labels at ok takes or more', () {
    final index = CoverageIndex(
      labels: {
        'A': LabelCoverage(takes: 12, rows: 12, hands: {}, calibrationIds: {}, signers: {}),
        'B': LabelCoverage(takes: 5, rows: 5, hands: {}, calibrationIds: {}, signers: {}),
        'C': LabelCoverage(takes: 3, rows: 3, hands: {}, calibrationIds: {}, signers: {}),
        'J': LabelCoverage(takes: 100, rows: 100, hands: {}, calibrationIds: {}, signers: {}),
        '_rest': LabelCoverage(takes: 4, rows: 4, hands: {}, calibrationIds: {}, signers: {}),
      },
      updatedAt: DateTime.now(),
    );
    const targets = ['A', 'B', 'C', 'J', 'Z', '_rest'];
    // A (good) + B (ok) + J ready; C, Z (no takes), _rest not.
    expect(index.readyCount(targets), 3);
  });

  test('index.json round-trips through JSON', () {
    final index = CoverageIndex(
      labels: {
        'A': LabelCoverage(
          takes: 2,
          rows: 5,
          hands: {'L', 'R'},
          calibrationIds: {3, 7},
          signers: {'P-001'},
        ),
      },
      updatedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
    );
    final decoded =
        CoverageIndex.fromJson(jsonDecode(jsonEncode(index.toJson())));
    expect(decoded.labels['A']!.takes, 2);
    expect(decoded.labels['A']!.hands, {'L', 'R'});
    expect(decoded.labels['A']!.calibrationIds, {3, 7});
    expect(decoded.updatedAt.millisecondsSinceEpoch, 1700000000000);
  });
}
