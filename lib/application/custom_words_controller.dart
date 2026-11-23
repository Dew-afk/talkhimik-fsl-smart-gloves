import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/strings/app_strings.dart';
import '../domain/vocab/custom_word.dart';
import '../domain/vocab/fsl_vocabulary.dart';
import '../domain/vocab/vocab_entry.dart';
import 'providers.dart';

/// Words the user added on the Record screen, kept in the settings so
/// deleting all recordings does not delete them.
class CustomWordsController extends Notifier<List<CustomWord>> {
  /// Travels with "Share all": word ids and sections for the trainer.
  static const String exportFileName = 'words.json';

  late Future<void> _loaded;

  @override
  List<CustomWord> build() {
    _loaded = _load()..ignore(); // a failed load surfaces in add/remove
    return const [];
  }

  Future<void> _load() async {
    final stored = await ref.read(settingsServiceProvider).customWords();
    if (!ref.mounted) return;
    state = stored.map(CustomWord.parse).whereType<CustomWord>().toList();
  }

  /// Why this word cannot be added, or null when it can.
  String? problemWith(String filipino, String english) {
    final name = filipino.trim();
    if (name.isEmpty || english.trim().isEmpty) {
      return AppStrings.addWordBothTexts;
    }
    if (name.startsWith('_')) return AppStrings.addWordUnderscore;
    final taken = [
      'REST',
      for (final e in fslVocabulary) e.filipino,
      for (final w in state)
        if (!w.deleted) w.entry.filipino,
    ];
    return taken.any((t) => t.toLowerCase() == name.toLowerCase())
        ? AppStrings.addWordExists
        : null;
  }

  /// Adds the word (or restores a deleted one under its old id) and returns
  /// the label to record. Call [problemWith] first.
  Future<String> add(String filipino, String english) async {
    await _loaded; // never overwrite stored words that are not loaded yet
    final name = filipino.trim();
    final old = state
        .where((w) => w.entry.filipino.toLowerCase() == name.toLowerCase())
        .firstOrNull;
    final nextId = state.fold(CustomWord.firstId,
        (id, w) => w.entry.wordId >= id ? w.entry.wordId + 1 : id);
    final word = CustomWord(VocabEntry(
      wordId: old?.entry.wordId ?? nextId,
      filipino: old?.entry.filipino ?? name, // its recordings' label
      english: english.trim(),
      category: VocabCategory.phrase,
    ));
    await _save([...state.where((w) => w != old), word]);
    return word.entry.filipino;
  }

  /// Hides the word; its recordings stay.
  Future<void> remove(int wordId) async {
    await _loaded;
    await _save([
      for (final w in state)
        w.entry.wordId == wordId ? CustomWord(w.entry, deleted: true) : w,
    ]);
  }

  Future<void> _save(List<CustomWord> words) async {
    await ref.read(settingsServiceProvider).setCustomWords([
      for (final w in words) jsonEncode(w.toJson()),
    ]);
    state = words;
  }

  /// Writes [exportFileName] into [dir].
  Future<File> writeExport(Directory dir, Set<String> stillPhrases) async {
    await _loaded;
    final file = File('${dir.path}/$exportFileName');
    await file.writeAsString(jsonEncode({
      'words': [for (final w in state) w.toJson()],
      'still': stillPhrases.toList()..sort(),
    }));
    return file;
  }
}
