import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers.dart';

/// FR-6: frequently used sentences pinned for one-tap playback without
/// signing. Tapping speaks the phrase and echoes it into the transcript.
class SavedPhrasesPanel extends ConsumerWidget {
  const SavedPhrasesPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vocab = ref.watch(vocabularyRepositoryProvider);
    final phrases = vocab.phrases;
    if (phrases.isEmpty) return const SizedBox.shrink();

    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: phrases.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final phrase = phrases[index];
          return ActionChip(
            label: Text(phrase.filipino),
            onPressed: () => ref
                .read(transcriptControllerProvider.notifier)
                .playSavedPhrase(phrase),
          );
        },
      ),
    );
  }
}
