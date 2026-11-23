import '../../domain/models/gesture_result.dart';
import '../../domain/repositories/vocabulary_repository.dart';
import '../../domain/vocab/custom_word.dart';
import '../../domain/vocab/fsl_vocabulary.dart';
import '../../domain/vocab/vocab_entry.dart';

/// Vocabulary lookup over the const table in `fsl_vocabulary.dart` plus the
/// words added on the Record screen.
class DefaultVocabularyRepository implements VocabularyRepository {
  DefaultVocabularyRepository([this._custom = const []])
      : _byId = _index([
          ...fslVocabulary,
          for (final w in _custom) w.entry,
        ]);

  final List<CustomWord> _custom;
  final Map<int, VocabEntry> _byId;

  static Map<int, VocabEntry> _index(List<VocabEntry> table) => {
        for (final e in table) e.wordId: e,
      };

  @override
  VocabEntry? lookup(int wordId) => _byId[wordId];

  @override
  List<VocabEntry> get letters =>
      fslVocabulary.where((e) => e.category == VocabCategory.letter).toList();

  @override
  List<VocabEntry> get phrases => [
        ...fslVocabulary.where((e) => e.category == VocabCategory.phrase),
        for (final w in _custom)
          if (!w.deleted) w.entry,
      ];

  @override
  List<AlternativePrediction> fallbackAlternatives(int wordId) {
    final entry = _byId[wordId];
    if (entry == null) return const [];

    // Placeholder heuristic: nearest same-category ids by distance. The
    // firmware may later extend the result packet with real model top-3s
    // (packet.alternatives); this fallback keeps FR-5 usable until then.
    final siblings = entry.category == VocabCategory.letter
        ? letters
        : phrases;
    final candidates = siblings
        .map((e) => (e.wordId - wordId).abs().toDouble() + (e.wordId == wordId ? 1e9 : 0))
        .toList();
    final indices = List<int>.generate(candidates.length, (i) => i)
      ..sort((a, b) => candidates[a].compareTo(candidates[b]));

    return indices.take(3).map((i) {
      final e = siblings[i];
      // Plausible decaying confidences for the demo; real values come from
      // the glove once the packet carries them.
      final conf = i == 0 ? 68 : (i == 1 ? 55 : 45);
      return AlternativePrediction(wordId: e.wordId, confidence: conf);
    }).toList();
  }
}
