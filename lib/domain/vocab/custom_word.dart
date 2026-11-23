import 'dart:convert';

import 'package:meta/meta.dart';

import 'vocab_entry.dart';

/// A word added on the Record screen. Phone-only: the firmware does not know
/// these ids, so they start far above the shared table (1..28, 100+).
@immutable
class CustomWord {
  const CustomWord(this.entry, {this.deleted = false});

  static const int firstId = 1000;

  final VocabEntry entry;

  /// Hidden but kept: its id is never reused, so old transcripts and
  /// recordings still resolve, and adding the word again restores it.
  final bool deleted;

  Map<String, Object?> toJson() => {
        'word_id': entry.wordId,
        'label': entry.filipino,
        'english': entry.english,
        'deleted': deleted,
      };

  /// Null when [json] is not a stored custom word.
  static CustomWord? parse(String json) {
    try {
      final m = jsonDecode(json) as Map<String, Object?>;
      return CustomWord(
        VocabEntry(
          wordId: m['word_id'] as int,
          filipino: m['label'] as String,
          english: m['english'] as String,
          category: VocabCategory.phrase,
        ),
        deleted: m['deleted'] == true,
      );
    } catch (_) {
      return null;
    }
  }
}
