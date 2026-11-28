import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talkhimik_app/application/providers.dart';
import 'package:talkhimik_app/core/strings/app_strings.dart';
import 'package:talkhimik_app/ui/screens/collect_screen.dart';

import '../helpers/fake_glove_connection.dart';
import '../helpers/in_memory_calinfo_cache.dart';
import '../helpers/in_memory_settings_service.dart';

void main() {
  late Directory dir;
  late InMemorySettingsService settings;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('talkhimik_collect_test');
    settings = InMemorySettingsService();
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Widget wrap() => ProviderScope(
        overrides: [
          gloveConnectionProvider.overrideWithValue(FakeGloveConnection()),
          rightGloveConnectionProvider
              .overrideWithValue(FakeGloveConnection()),
          settingsServiceProvider.overrideWithValue(settings),
          calInfoCacheProvider.overrideWithValue(InMemoryCalInfoCache()),
          datasetDirectoryProvider.overrideWithValue(Future.value(dir)),
        ],
        child: const MaterialApp(home: CollectScreen()),
      );

  testWidgets('idle screen shows the label input, record button, and the '
      'sessions list header', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    // App bar + header band both show the title (design refresh).
    expect(find.text(AppStrings.recordModeTitle), findsNWidgets(2));
    expect(find.text(AppStrings.recordStart), findsOneWidget);
    // The coverage card sits above the sessions list now — scroll to it
    // (the outer ListView is the first Scrollable; TextFields own one too).
    await tester.scrollUntilVisible(
      find.text(AppStrings.datasetSessions),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text(AppStrings.datasetSessions), findsOneWidget);
  });

  testWidgets('the consent gate shows the NFR-8 message and stays idle',
      (tester) async {
    settings.participant = 'P-001';
    settings.consent = false;
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    await tester.tap(find.text(AppStrings.recordStart));
    await tester.pumpAndSettle();

    expect(find.text(AppStrings.recordNeedsConsent), findsOneWidget);
    expect(find.text(AppStrings.datasetRecording), findsNothing);
  });

  testWidgets('starting with consent records and shows the stop control',
      (tester) async {
    settings.participant = 'P-001';
    settings.consent = true;
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    await tester.tap(find.text(AppStrings.recordStart));
    await tester.pumpAndSettle();

    expect(find.text(AppStrings.recordAbort), findsOneWidget);
    expect(find.textContaining(AppStrings.datasetRecording), findsOneWidget);
  });

  /// The coverage card added a lot of vertical content — give these tests
  /// a tall viewport so the whole list is laid out at once.
  void useTallViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  testWidgets('the coverage card shows the letter grid, REST chip, summary '
      'and hint', (tester) async {
    useTallViewport(tester);
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    expect(find.text(AppStrings.coverageTitle), findsOneWidget);
    expect(find.text('A · 0'), findsOneWidget);
    expect(find.text('REST · 0'), findsOneWidget);
    // J and Z exist as chips (both count, motion-gated).
    expect(find.text('J · 0'), findsOneWidget);
    expect(find.text('Z · 0'), findsOneWidget);
    expect(find.text(AppStrings.coverageHint), findsOneWidget);
    expect(find.textContaining('of 29 letters ready'), findsOneWidget);
  });

  Finder selected(String label) => find.text(AppStrings.datasetSelected(label));

  Future<void> open(WidgetTester tester, String section) async {
    await tester.tap(find.text(section));
    await tester.pumpAndSettle();
  }

  testWidgets('tapping a bubble selects it for recording', (tester) async {
    useTallViewport(tester);
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();
    expect(find.text(AppStrings.datasetSelectedNone), findsOneWidget);

    await tester.tap(find.text('A · 0'));
    await tester.pumpAndSettle();
    expect(selected('A'), findsOneWidget);

    await tester.tap(find.text('REST · 0'));
    await tester.pumpAndSettle();
    expect(selected('REST'), findsOneWidget);
  });

  testWidgets('phrases start under movement, each with an error bubble',
      (tester) async {
    useTallViewport(tester);
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();
    expect(find.text('Salamat · 0'), findsNothing); // collapsed

    await open(tester, AppStrings.sectionMovement);
    expect(find.text('Kumusta · 0'), findsOneWidget);
    expect(find.text('Magkano? · 0'), findsOneWidget);
    await open(tester, AppStrings.sectionErrors);
    expect(find.text('Wrong Kumusta · 0'), findsOneWidget);
    expect(find.text('Random moves · 0'), findsOneWidget);

    await tester.tap(find.text('Wrong Salamat · 0'));
    await tester.pumpAndSettle();
    expect(selected('Wrong Salamat'), findsOneWidget);
  });

  testWidgets('holding a phrase moves it to still and drops its error bubble',
      (tester) async {
    useTallViewport(tester);
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();
    await open(tester, AppStrings.sectionMovement);
    await open(tester, AppStrings.sectionErrors);

    await tester.longPress(find.text('Oo · 0'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(AppStrings.moveWordStill));
    await tester.pumpAndSettle();

    expect(settings.still, {'Oo'});
    expect(find.text('Oo · 0'), findsNothing); // still section is collapsed
    expect(find.text('Wrong Oo · 0'), findsNothing);
    await open(tester, AppStrings.sectionStill);
    expect(find.text('Oo · 0'), findsOneWidget);
  });

  testWidgets('a word can be added to a section, then deleted',
      (tester) async {
    useTallViewport(tester);
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();
    await open(tester, AppStrings.sectionMovement);
    await open(tester, AppStrings.sectionErrors);

    await tester.tap(find.byKey(const Key('add-word-button')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('add-word-filipino')), 'Salamat');
    await tester.enterText(
        find.byKey(const Key('add-word-english')), 'Thanks');
    await tester.tap(find.byKey(const Key('add-word-confirm')));
    await tester.pumpAndSettle();
    expect(find.text(AppStrings.addWordExists), findsOneWidget);

    await tester.enterText(find.byKey(const Key('add-word-filipino')), 'Kain');
    await tester.tap(find.byKey(const Key('add-word-confirm')));
    await tester.pumpAndSettle();
    expect(selected('Kain'), findsOneWidget);
    expect(find.text('Kain · 0'), findsOneWidget);
    expect(find.text('Wrong Kain · 0'), findsOneWidget);

    await tester.longPress(find.text('Kain · 0'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(AppStrings.deleteWord));
    await tester.pumpAndSettle();
    expect(find.text('Kain · 0'), findsNothing);
    expect(find.text('Wrong Kain · 0'), findsNothing);
    expect(find.text(AppStrings.datasetSelectedNone), findsOneWidget);
  });

  testWidgets('a word added as still has no error bubble', (tester) async {
    useTallViewport(tester);
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();
    await open(tester, AppStrings.sectionErrors);
    await tester.tap(find.byKey(const Key('add-word-button')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('add-word-filipino')), 'Kain');
    await tester.enterText(find.byKey(const Key('add-word-english')), 'Eat');
    await tester.tap(find.text(AppStrings.moveWordStill));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('add-word-confirm')));
    await tester.pumpAndSettle();

    expect(settings.still, {'Kain'});
    expect(find.text('Wrong Kain · 0'), findsNothing);
    await open(tester, AppStrings.sectionStill);
    expect(find.text('Kain · 0'), findsOneWidget);
  });

  testWidgets('the label cannot change while a take is running',
      (tester) async {
    useTallViewport(tester);
    settings.participant = 'P-001';
    settings.consent = true;
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();
    await tester.tap(find.text('A · 0'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(AppStrings.recordStart));
    await tester.pumpAndSettle();

    await tester.tap(find.text('B · 0'));
    await tester.pumpAndSettle();
    expect(selected('A'), findsOneWidget);
  });

  testWidgets('share-all is disabled with a reason when there is no data',
      (tester) async {
    useTallViewport(tester);
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    final button = tester.widget<OutlinedButton>(
        find.byKey(const Key('share-all-button')));
    expect(button.onPressed, isNull);
    expect(find.text(AppStrings.shareAllNoData), findsOneWidget);
  });
}
