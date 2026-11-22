import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../application/coverage_controller.dart';
import '../../application/dataset_recorder_controller.dart';
import '../../application/providers.dart';
import '../../core/strings/app_strings.dart';
import '../../core/theme/app_theme.dart';
import '../../data/dataset/coverage_index.dart';
import '../../domain/vocab/vocab_entry.dart';
import '../widgets/anim.dart';
import '../widgets/header_band.dart';

/// Dataset recorder screen (master §5): labeled takes at 5 Hz per glove,
/// calibration-aware sessions, and the finished-sessions list with
/// share / delete actions.
class CollectScreen extends ConsumerStatefulWidget {
  const CollectScreen({super.key});

  @override
  ConsumerState<CollectScreen> createState() => _CollectScreenState();
}

class _CollectScreenState extends ConsumerState<CollectScreen> {
  final ScrollController _scroll = ScrollController();

  /// The tapped bubble: what [DatasetRecorderController.startTake] records.
  String? _selectedLabel;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Back to the record button: the bubbles are a long scroll below it.
  void _selectLabel(String stored) {
    setState(() => _selectedLabel = stored);
    _scroll.animateTo(0,
        duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
  }

  Future<void> _moveWord(VocabEntry e) async {
    final still = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(AppStrings.moveWordTitle(e.filipino, e.english)),
        content: const Text(AppStrings.moveWordBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text(AppStrings.moveWordStill),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text(AppStrings.moveWordMovement),
          ),
        ],
      ),
    );
    if (still == null) return;
    await ref
        .read(coverageControllerProvider.notifier)
        .setStill(e.filipino, still);
  }

  /// One collapsible group of bubbles.
  Widget _section(String title,
          {required List<Widget> chips,
          String? hint,
          bool initiallyExpanded = false}) =>
      ExpansionTile(
        key: PageStorageKey(title),
        title: Text(title),
        initiallyExpanded: initiallyExpanded,
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 8),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (hint != null) ...[
            Text(hint, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
          ],
          Wrap(spacing: 8, runSpacing: 8, children: chips),
        ],
      );

  Future<void> _shareAll() async {
    final recorder = ref.read(datasetRecorderControllerProvider.notifier);
    // Finalize a running recording so its sidecars exist and are shared.
    if (ref.read(datasetRecorderControllerProvider).phase ==
        RecordingPhase.recording) {
      await recorder.stop();
    }
    final files = <XFile>[];
    for (final s in ref.read(datasetRecorderControllerProvider).sessions) {
      for (final p in await recorder.pathsFor(s)) {
        files.add(XFile(p));
      }
    }
    // The coverage index travels with the data so training can rebuild it.
    final dir = await ref.read(datasetDirectoryProvider);
    files.add(XFile('${dir.path}/${CoverageIndexStore.fileName}'));
    if (!mounted) return;
    await SharePlus.instance.share(ShareParams(files: files));
  }

  static String _display(String label) {
    if (label == restLabel) return 'REST';
    if (label == randomMovesLabel) return AppStrings.randomMoves;
    final wrong = wrongLabelFor('');
    return label.startsWith(wrong)
        ? AppStrings.wrongMove(label.substring(wrong.length))
        : label;
  }

  Future<void> _confirmReset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text(AppStrings.datasetResetTitle),
        content: const Text(AppStrings.datasetResetBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text(AppStrings.datasetUndoKeep),
          ),
          FilledButton(
            key: const Key('reset-all-confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text(AppStrings.datasetResetConfirm),
          ),
        ],
      ),
    );
    if (ok ?? false) {
      await ref.read(datasetRecorderControllerProvider.notifier).resetAll();
    }
  }

  Future<void> _confirmUndo(String label) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text(AppStrings.datasetUndoTitle),
        content: Text(AppStrings.datasetUndoBody(_display(label))),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text(AppStrings.datasetUndoKeep),
          ),
          FilledButton(
            key: const Key('undo-take-confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text(AppStrings.datasetUndoConfirm),
          ),
        ],
      ),
    );
    if (ok ?? false) {
      await ref.read(datasetRecorderControllerProvider.notifier).undoLastTake();
    }
  }

  /// One coverage chip: label + take count + state icon. State is shown
  /// with an icon AND a number, never color alone (design system rule);
  /// the icon's meaning is in the Tooltip. Tapping selects the label, unless
  /// a take is running ([locked]): that take keeps its label. Holding a
  /// [phrase] moves it to another section.
  Widget _coverageChip(
      BuildContext context, CoverageState coverage, String label,
      {VocabEntry? phrase, required bool locked}) {
    final takes = coverage.index?.labels[label]?.takes ?? 0;
    final cState = coverageLevelFor(label, takes);
    final (icon, stateName) = switch (cState) {
      CoverageLevel.later =>
        (Icons.schedule, AppStrings.coverageLater),
      CoverageLevel.needsData =>
        (Icons.hourglass_empty, AppStrings.coverageNeedsData),
      CoverageLevel.ok =>
        (Icons.check_circle_outline, AppStrings.coverageOk),
      CoverageLevel.good => (Icons.verified, AppStrings.coverageGood),
    };
    final display = _display(label);
    final chip = Tooltip(
      message: stateName,
      triggerMode: phrase == null ? null : TooltipTriggerMode.manual,
      child: ActionChip(
        avatar: Icon(icon, size: 18),
        label: Text('$display · $takes'),
        onPressed: locked ? null : () => _selectLabel(label),
      ),
    );
    return phrase == null
        ? chip
        : GestureDetector(onLongPress: () => _moveWord(phrase), child: chip);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(datasetRecorderControllerProvider);
    final recorder = ref.read(datasetRecorderControllerProvider.notifier);
    final coverage = ref.watch(coverageControllerProvider);
    final letters = ref.read(vocabularyRepositoryProvider).letters;
    final recording = state.phase == RecordingPhase.recording;
    final phrases = ref.read(vocabularyRepositoryProvider).phrases;
    final still = [
      for (final e in phrases)
        if (coverage.stillPhrases.contains(e.filipino)) e,
    ];
    final moving = [
      for (final e in phrases)
        if (!coverage.stillPhrases.contains(e.filipino)) e,
    ];
    final selected = _selectedLabel ?? state.label;
    final locked = state.takeActive;

    return Scaffold(
      appBar: AppBar(title: const Text(AppStrings.recordModeTitle)),
      body: Column(
        children: [
          HeaderBand(
            title: AppStrings.recordModeTitle,
            chipLabel: recording && state.active.isNotEmpty
                ? '${state.active.length} glove(s)'
                : null,
          ),
          Expanded(
            child: ListView(
              controller: _scroll,
              padding: const EdgeInsets.all(16),
              children: [
          if (state.error != null) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(state.error!),
            ),
            const SizedBox(height: 12),
          ],
          Semantics(
            liveRegion: true,
            child: Text(
              selected.isEmpty
                  ? AppStrings.datasetSelectedNone
                  : AppStrings.datasetSelected(_display(selected)),
              key: const Key('selected-label'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (!recording)
                // Large record pill (step 4b).
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 32, vertical: 16),
                    textStyle: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                  icon: const Icon(Icons.fiber_manual_record),
                  label: const Text(AppStrings.recordStart),
                  onPressed: () async {
                    await recorder.start();
                    if (!mounted) return;
                    if (ref.read(datasetRecorderControllerProvider).phase ==
                        RecordingPhase.recording) {
                      await recorder
                          .startTake(selected);
                      // Light haptic on recording start (motion pass).
                      HapticFeedback.selectionClick();
                    }
                  },
                )
              else
                OutlinedButton.icon(
                  icon: const Icon(Icons.stop),
                  label: const Text(AppStrings.recordAbort),
                  onPressed: () async {
                    HapticFeedback.selectionClick();
                    await recorder.stopTake();
                    await recorder.stop();
                  },
                ),
              if (recording && state.takeActive)
                OutlinedButton.icon(
                  icon: const Icon(Icons.pause_circle_outline),
                  label: const Text(AppStrings.datasetStopTake),
                  onPressed: recorder.stopTake,
                )
              else if (recording)
                OutlinedButton.icon(
                  icon: const Icon(Icons.play_circle_outline),
                  label: const Text(AppStrings.datasetStartTake),
                  onPressed: () => recorder.startTake(selected),
                ),
              if (!state.takeActive && state.undoLabel.isNotEmpty)
                TextButton.icon(
                  key: const Key('undo-take-button'),
                  icon: const Icon(Icons.undo),
                  label: Text(
                      AppStrings.datasetUndoTake(_display(state.undoLabel))),
                  onPressed: () => _confirmUndo(state.undoLabel),
                ),
            ],
          ),
          if (recording) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                // Pulsing recording dot (static under reduce-motion/tests).
                LoopPulse(
                  scale: 1.4,
                  child: Container(
                    width: 10,
                    height: 10,
                    decoration: const BoxDecoration(
                      color: AppColors.danger,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${AppStrings.datasetRecording}: '
                    '${state.active.values.map((s) => '${s.handTag} ${s.rows} '
                            '${AppStrings.datasetRows}').join(' · ')}',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 24),
          // ---- Dataset coverage card (C2) ----
          Text(AppStrings.coverageTitle,
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            AppStrings.coverageSummary(
              coverage.readyCount(letters),
              letters.length - CoverageThresholds.laterLabels.length + 1,
              coverage.index?.totalTakes ?? 0,
              coverage.index?.restTakes ?? 0,
            ),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          _section(AppStrings.sectionLetters, initiallyExpanded: true, chips: [
            for (final label in coverage.targetLabels(letters))
              _coverageChip(context, coverage, label, locked: locked),
          ]),
          _section(
            AppStrings.sectionStill,
            hint: still.isEmpty ? AppStrings.sectionStillEmpty : null,
            chips: [
              for (final e in still)
                _coverageChip(context, coverage, e.filipino,
                    phrase: e, locked: locked),
            ],
          ),
          _section(
            AppStrings.sectionMovement,
            hint: AppStrings.sectionMovementHint,
            chips: [
              for (final e in moving)
                _coverageChip(context, coverage, e.filipino,
                    phrase: e, locked: locked),
            ],
          ),
          _section(
            AppStrings.sectionErrors,
            hint: AppStrings.sectionErrorsHint,
            chips: [
              for (final label in coverage.errorLabels(phrases))
                _coverageChip(context, coverage, label, locked: locked),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            AppStrings.coverageHint,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            key: const Key('share-all-button'),
            icon: const Icon(Icons.ios_share),
            label: const Text(AppStrings.shareAll),
            onPressed: state.sessions.isEmpty && state.active.isEmpty
                ? null
                : _shareAll,
          ),
          if (state.sessions.isEmpty && state.active.isEmpty) ...[
            const SizedBox(height: 4),
            Text(
              AppStrings.shareAllNoData,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          TextButton.icon(
            key: const Key('reset-all-button'),
            icon: const Icon(Icons.delete_forever_outlined),
            label: const Text(AppStrings.datasetResetAll),
            onPressed: state.phase == RecordingPhase.recording ||
                    state.sessions.isEmpty
                ? null
                : _confirmReset,
          ),
          const SizedBox(height: 24),
          Text(AppStrings.datasetSessions,
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          for (final s in state.sessions)
            FadeIn(
              key: ValueKey('session-${s.sessionId}'),
              child: Card(
              child: ListTile(
                title: Text(
                    '${s.handTag} · ${s.signerId} · cal_id ${s.calibrationId}'),
                subtitle: Text(
                    '${s.rows} ${AppStrings.datasetRows} · '
                    '${s.droppedFrames} ${AppStrings.datasetDropped} · '
                    '${(s.sizeBytes / 1024).toStringAsFixed(1)} kB'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: AppStrings.datasetShare,
                      icon: const Icon(Icons.share_outlined),
                      onPressed: () async {
                        final paths = await recorder.pathsFor(s);
                        if (!mounted) return;
                        await SharePlus.instance.share(ShareParams(
                          files: [for (final p in paths) XFile(p)],
                        ));
                      },
                    ),
                    IconButton(
                      tooltip: AppStrings.datasetDelete,
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => recorder.deleteSession(s),
                    ),
                  ],
                ),
              ),
              ),
            ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
