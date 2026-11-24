import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers.dart';
import '../../core/strings/app_strings.dart';
import '../../core/theme/app_theme.dart';
import '../../data/glove/glove_connection.dart';
import '../../domain/models/calibration_table.dart';
import '../../domain/models/hand_state.dart';
import '../../domain/models/telemetry_packet.dart';
import '../../domain/sensing/sensor_math.dart';
import '../widgets/connection_badges.dart';
import '../widgets/diagonal_slab.dart';
import '../widgets/finger_ticker_card.dart';
import '../widgets/hand_view.dart';
import '../widgets/imu_tiles.dart';
import '../widgets/recognition_debug_panel.dart';

/// Live per-hand telemetry view (master §6.1): animated hands, angle bars,
/// raw ADC + Ω details, IMU tiles, health badges, zero-yaw/vibrate, and the
/// calibration chip. Two hands side by side on wide screens, tabbed L/R on
/// phones.
class LiveScreen extends ConsumerStatefulWidget {
  const LiveScreen({super.key});

  @override
  ConsumerState<LiveScreen> createState() => _LiveScreenState();
}

class _LiveScreenState extends ConsumerState<LiveScreen>
    with SingleTickerProviderStateMixin {
  DateTime _now = DateTime.now();

  late final Ticker _clock = createTicker((_) {
    // Freshness/stale badges re-evaluate on a frame clock.
    if (mounted) setState(() => _now = DateTime.now());
  });

  @override
  void initState() {
    super.initState();
    _clock.start();
  }

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final live = ref.watch(liveControllerProvider);
    return Scaffold(
      appBar: AppBar(title: const Text(AppStrings.liveTitle)),
      body: Column(
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
          final wide = constraints.maxWidth >= 700;
          if (wide) {
            return Row(
              children: [
                Expanded(
                    child: _HandPanel(hand: live.left, now: _now)),
                const VerticalDivider(width: 1),
                Expanded(
                    child: _HandPanel(hand: live.right, now: _now)),
              ],
            );
          }
          return DefaultTabController(
            length: 2,
            child: Column(
              children: [
                const TabBar(tabs: [
                  Tab(text: AppStrings.leftHandLabel),
                  Tab(text: AppStrings.rightHandLabel),
                ]),
                Expanded(
                  child: TabBarView(
                    children: [
                      _HandPanel(hand: live.left, now: _now),
                      _HandPanel(hand: live.right, now: _now),
                    ],
                  ),
                ),
              ],
            ),
          );
              },
            ),
          ),
          if (kDebugMode)
            const Padding(
              padding: EdgeInsets.all(12),
              child: RecognitionDebugPanel(),
            ),
        ],
      ),
    );
  }
}

/// One hand's full column: hand view, bars, details, tiles, badges, actions.
class _HandPanel extends ConsumerWidget {
  const _HandPanel({required this.hand, required this.now});

  final HandState hand;
  final DateTime now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = hand.telemetry;
    final calId = t?.calibrationId ?? hand.calInfo?.calibrationId;
    final table = hand.calInfo == null ? null : CalibrationTable(hand.calInfo!);
    // Per-finger weak spans come from the CAL_INFO weak mask (§4.3).
    final weakMask = table?.packet.weakMask ?? 0;
    final scheme = Theme.of(context).colorScheme;

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        // Glass stage with the diagonal slab backdrop behind the hand.
        Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [AppColors.tintSky, scheme.surface],
            ),
            borderRadius: BorderRadius.circular(20),
            border:
                Border.all(color: scheme.outlineVariant),
          ),
          child: Stack(
            children: [
              const Positioned.fill(
                child: IgnorePointer(child: SlabBackdrop(variant: 1)),
              ),
              HandView(
                target:
                    HandPose.fromTelemetry(t, hand.hand, weakMask: weakMask),
                title: hand.hand == GloveHand.left
                    ? AppStrings.leftHandTitle
                    : AppStrings.rightHandTitle,
                chipLabel: calId == null
                    ? null
                    : 'cal_id $calId'
                        '${table != null ? ' · fw ${table.firmwareVersion}' : ''}',
                uncalibrated: hand.uncalibrated,
                stale: hand.isStaleAt(now),
              ),
            ],
          ),
        ),
        ConnectionBadges(hand: hand, now: now),
        const SizedBox(height: 8),
        if (hand.uncalibrated)
          Chip(
            label: const Text(AppStrings.uncalibrated),
            backgroundColor: scheme.errorContainer,
          ),
        const SizedBox(height: 8),
        // Finger ticker cards: horizontal scroll, focused card scales.
        _FingerTicker(
          angles: [for (var i = 0; i < 5; i++) (t?.angles[i] ?? 0).toDouble()],
          validMask: t?.validMask ?? 0,
          weakMask: weakMask,
        ),
        const SizedBox(height: 8),
        if (t != null) ...[
          ImuTiles(
            rollDeg: t.rollDeg,
            pitchDeg: t.pitchDeg,
            yawDeg: t.yawDeg,
          ),
          const SizedBox(height: 8),
          _Details(t: t, table: table),
        ] else
          Text(AppStrings.noFramesYet,
              style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              icon: const Icon(Icons.explore_off, size: 16),
              label: const Text(AppStrings.zeroYaw),
              onPressed: () => _connectionFor(ref).sendCommand(
                  AppCommand.zeroYaw),
            ),
            // Vibrate (0x08) stays reachable through the dev demo controls;
            // it is a hardware test aid, not a product feature.
            FilledButton.tonalIcon(
              icon: const Icon(Icons.fiber_manual_record_outlined, size: 16),
              label: const Text(AppStrings.recordModeTitle),
              onPressed: () =>
                  Navigator.of(context).pushNamed('/collect'),
            ),
          ],
        ),
      ],
    );
  }

  /// The connection that owns this panel's glove.
  GloveConnection _connectionFor(WidgetRef ref) =>
      ref.read(hand.hand == GloveHand.left
          ? gloveConnectionProvider
          : rightGloveConnectionProvider);
}

/// Horizontal finger-card ticker (step 4b): thumb → pinky, focused card
/// scales to 1.06, sparklines buffer their own history.
class _FingerTicker extends StatefulWidget {
  const _FingerTicker({
    required this.angles,
    required this.validMask,
    required this.weakMask,
  });

  final List<double> angles;
  final int validMask;
  final int weakMask;

  @override
  State<_FingerTicker> createState() => _FingerTickerState();
}

class _FingerTickerState extends State<_FingerTicker> {
  int? _focused;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 88,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: fingerNames.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) => FingerTickerCard(
          name: fingerNames[i],
          angleDeg: widget.angles[i],
          invalid: widget.validMask & (1 << i) == 0,
          weak: widget.weakMask & (1 << i) != 0,
          focused: _focused == i,
          onTap: () => setState(() => _focused = _focused == i ? null : i),
        ),
      ),
    );
  }
}

/// Collapsible raw ADC + recomputed Ω per finger (master §6.1).
class _Details extends StatelessWidget {
  const _Details({required this.t, required this.table});

  final TelemetryPacket t;
  final CalibrationTable? table;

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      title: Text(AppStrings.details,
          style: Theme.of(context).textTheme.titleSmall),
      children: [
        for (var i = 0; i < fingerNames.length; i++)
          ListTile(
            dense: true,
            title: Text(fingerNames[i]),
            subtitle: Text(
              '${AppStrings.rawAdc}: ${t.rawAdc[i]}'
              ' · ${AppStrings.resistanceOhm}: '
              '${_ohms(i).toStringAsFixed(0)}',
            ),
          ),
      ],
    );
  }

  double _ohms(int i) {
    final finger = table?.finger(i);
    final rDiv = finger?.rDiv ?? 10000;
    return adcToOhms(rDiv, t.rawAdc[i]);
  }
}
