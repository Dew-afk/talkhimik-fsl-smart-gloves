import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers.dart';
import '../../core/strings/app_strings.dart';
import '../../core/theme/app_theme.dart';
import '../../data/glove/glove_connection.dart';
import '../../data/glove/glove_connection_factory.dart';
import '../../data/glove/mock_glove_connection.dart';
import '../../domain/models/telemetry_packet.dart';
import '../widgets/anim.dart';
import '../widgets/diagonal_slab.dart';
import '../widgets/device_status_bar.dart';
import '../widgets/hand_view.dart';
import '../widgets/reply_panel.dart';
import '../widgets/saved_phrases_panel.dart';
import '../widgets/transcript_view.dart';

/// Main screen (design refresh, step 4): one status pill, hero transcript,
/// a compact live-hand preview card, one dominant action, quick replies,
/// and the reply input. Demo controls moved to More → Developer.
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  @override
  void initState() {
    super.initState();
    // Demo convenience: on dev platforms the mock glove auto-connects so
    // the transcript is one tap away; a saved startup scenario then starts
    // running. NEVER on a phone: the mock must not start itself there even
    // when Force mock is on (bugfix) — there it connects explicitly.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (GloveConnectionFactory.isMobile ||
          !ref.read(gloveIsMockProvider)) {
        return;
      }
      final gloveController = ref.read(gloveControllerProvider.notifier);
      await gloveController.connect();
      await ref.read(rightGloveControllerProvider.notifier).connect();
      if (!mounted) return;
      final scenarioName =
          await ref.read(settingsServiceProvider).demoScenario();
      if (scenarioName == null || !mounted) return;
      final glove = ref.read(gloveConnectionProvider);
      if (glove is MockGloveConnection) {
        final scenario = MockScenario.values
            .where((s) => s.name == scenarioName)
            .firstOrNull;
        if (scenario != null) glove.startScenario(scenario);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final live = ref.watch(liveControllerProvider);
    final phase = ref.watch(gloveControllerProvider).phase;
    final isMock = ref.watch(gloveIsMockProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text(AppStrings.appTitle),
        // ≤ 2 actions: Live preview shortcut + Settings (step 4 nav).
        actions: [
          IconButton(
            tooltip: AppStrings.liveTitle,
            icon: const Icon(Icons.back_hand_outlined),
            onPressed: () => Navigator.of(context).pushNamed('/live'),
          ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).pushNamed('/settings'),
          ),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 840;
            final content = Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: DeviceStatusBar(),
                ),
                // Compact live-hand preview card: the signature feature on
                // the main screen (glass, tap → Live). Hidden on very
                // short viewports so the transcript/input never overflow.
                if (phase == GloveConnectionPhase.ready &&
                    constraints.maxHeight > 560)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: FadeIn(
                      child: InkWell(
                        borderRadius: BorderRadius.circular(16),
                        onTap: () =>
                            Navigator.of(context).pushNamed('/live'),
                        child: Container(
                          height: 110,
                          padding:
                              const EdgeInsets.symmetric(horizontal: 12),
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [
                                AppColors.tintSky,
                                Theme.of(context).colorScheme.surface,
                              ],
                            ),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                                color: Theme.of(context)
                                    .colorScheme
                                    .outlineVariant),
                          ),
                          child: Stack(
                            children: [
                              // Decorative slab behind the hand.
                              const Positioned.fill(
                                child: SlabBackdrop(variant: 2),
                              ),
                              Row(
                                children: [
                                  Expanded(
                                    child: HandView(
                                      compact: true,
                                      target: HandPose.fromTelemetry(
                                          live.left.telemetry, GloveHand.left,
                                          weakMask:
                                              live.left.calInfo?.weakMask ?? 0),
                                      stale:
                                          live.left.isStaleAt(DateTime.now()),
                                      uncalibrated: live.left.uncalibrated,
                                    ),
                                  ),
                                  Expanded(
                                    child: HandView(
                                      compact: true,
                                      target: HandPose.fromTelemetry(
                                          live.right.telemetry,
                                          GloveHand.right,
                                          weakMask:
                                              live.right.calInfo?.weakMask ??
                                                  0),
                                      stale: live.right
                                          .isStaleAt(DateTime.now()),
                                      uncalibrated:
                                          live.right.uncalibrated,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                Expanded(
                  child: Stack(
                    children: [
                      // Soft hero gradient + diagonal slabs behind the
                      // transcript header zone (decorative only).
                      const Positioned.fill(
                        child: IgnorePointer(child: SlabBackdrop()),
                      ),
                      Column(
                        children: [
                          // Slim transcript header: a label + the one
                          // existing action (Clear) — no full-width band.
                          Padding(
                            padding:
                                const EdgeInsets.fromLTRB(16, 4, 8, 0),
                            child: Row(
                              children: [
                                Text(
                                  AppStrings.transcriptHeader,
                                  style: Theme.of(context)
                                      .textTheme
                                      .labelMedium
                                      ?.copyWith(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onSurfaceVariant),
                                ),
                                const Spacer(),
                                IconButton(
                                  tooltip: AppStrings.clearTranscript,
                                  visualDensity:
                                      VisualDensity.compact,
                                  icon: const Icon(
                                      Icons.delete_sweep_outlined),
                                  onPressed: () => ref
                                      .read(
                                          transcriptControllerProvider
                                              .notifier)
                                      .clear(),
                                ),
                              ],
                            ),
                          ),
                          Expanded(child: TranscriptView()),
                        ],
                      ),
                    ],
                  ),
                ),
                if (isMock)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: SavedPhrasesPanel(),
                  ),
                // ONE dominant action, thumb zone: connect both gloves;
                // when connected it settles into a quiet "Listening" pill
                // (no new behavior — existing connect actions only).
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: phase == GloveConnectionPhase.ready
                      ? FilledButton.icon(
                          icon: const Icon(Icons.graphic_eq, size: 18),
                          label: const Text(AppStrings.listening),
                          onPressed: null,
                        )
                      : FilledButton.icon(
                          key: DeviceStatusBar.connectButtonKey,
                          icon: const Icon(Icons.bluetooth_searching),
                          label: const Text(AppStrings.connectGloves),
                          onPressed: () async {
                            await ref
                                .read(gloveControllerProvider.notifier)
                                .connect();
                            await ref
                                .read(
                                    rightGloveControllerProvider.notifier)
                                .connect();
                          },
                        ),
                ),
                const ReplyPanel(),
              ],
            );
            // Wide: cap content at ~720 dp, centered.
            if (!wide) return content;
            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: content,
              ),
            );
          },
        ),
      ),
    );
  }
}
