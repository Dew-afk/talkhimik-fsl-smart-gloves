import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talkhimik_app/application/custom_words_controller.dart';
import 'package:talkhimik_app/application/providers.dart';
import 'package:talkhimik_app/core/strings/app_strings.dart';

import '../helpers/in_memory_settings_service.dart';

void main() {
  late InMemorySettingsService settings;

  ProviderContainer open() {
    final c = ProviderContainer(
        overrides: [settingsServiceProvider.overrideWithValue(settings)]);
    addTearDown(c.dispose);
    return c;
  }

  setUp(() => settings = InMemorySettingsService());

  test('an added word gets an id from 1000 and survives a restart', () async {
    final c = open();
    final words = c.read(customWordsProvider.notifier);
    expect(await words.add(' Tulong po ', 'Please help'), 'Tulong po');
    await words.add('Kain', 'Eat');

    final again = open();
    again.read(customWordsProvider);
    await pumpEventQueue();
    final vocab = again.read(vocabularyRepositoryProvider);
    expect(vocab.lookup(1000)!.filipino, 'Tulong po');
    expect(vocab.lookup(1001)!.english, 'Eat');
    expect(vocab.phrases.last.filipino, 'Kain');
  });

  test('adding right after start keeps the words stored before', () async {
    await open().read(customWordsProvider.notifier).add('Kain', 'Eat');
    await open().read(customWordsProvider.notifier).add('Inom', 'Drink');
    expect(settings.words, hasLength(2));
  });

  test('a deleted word is hidden, keeps its id, and can come back', () async {
    final c = open();
    final words = c.read(customWordsProvider.notifier);
    await words.add('Kain', 'Eat');
    await words.remove(1000);
    final vocab = c.read(vocabularyRepositoryProvider);
    expect(vocab.phrases.any((e) => e.filipino == 'Kain'), isFalse);
    expect(vocab.lookup(1000)!.filipino, 'Kain'); // old transcripts

    await words.add('Inom', 'Drink');
    expect(c.read(vocabularyRepositoryProvider).lookup(1001)!.filipino, 'Inom');
    expect(await words.add('kain', 'To eat'), 'Kain');
    expect(c.read(vocabularyRepositoryProvider).lookup(1000)!.english, 'To eat');
  });

  test('names that clash or are reserved are refused', () async {
    final words = open().read(customWordsProvider.notifier);
    await words.add('Kain', 'Eat');
    expect(words.problemWith('Inom', 'Drink'), isNull);
    expect(words.problemWith(' ', 'x'), AppStrings.addWordBothTexts);
    expect(words.problemWith('x1', ' '), AppStrings.addWordBothTexts);
    expect(words.problemWith('_wrong_A', 'x'), AppStrings.addWordUnderscore);
    for (final name in ['salamat', 'a', 'Rest', 'KAIN ']) {
      expect(words.problemWith(name, 'x'), AppStrings.addWordExists);
    }
  });

  test('a broken stored word does not hide the others', () async {
    settings.words = ['{bad', '{"word_id":1003,"label":"Kain","english":"Eat"}'];
    final c = open();
    c.read(customWordsProvider);
    await pumpEventQueue();
    expect(c.read(customWordsProvider).single.entry.wordId, 1003);
  });

  test('the export lists words and still phrases for the trainer', () async {
    final dir = await Directory.systemTemp.createTemp('talkhimik_words');
    addTearDown(() => dir.delete(recursive: true));
    final words = open().read(customWordsProvider.notifier);
    await words.add('Kain', 'Eat');
    final file = await words.writeExport(dir, {'Oo'});
    expect(file.path, endsWith(CustomWordsController.exportFileName));
    expect(jsonDecode(await file.readAsString()), {
      'words': [
        {'word_id': 1000, 'label': 'Kain', 'english': 'Eat', 'deleted': false},
      ],
      'still': ['Oo'],
    });
  });
}
