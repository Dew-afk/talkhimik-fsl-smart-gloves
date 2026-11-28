import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../../core/constants/gatt_ids.dart';
import '../../core/strings/app_strings.dart';
import '../../domain/models/cal_info_packet.dart';
import '../../domain/models/device_status.dart';
import '../../domain/models/gesture_result.dart';
import '../../domain/models/telemetry_packet.dart';
import '../codec/cal_info_codec.dart';
import '../codec/device_status_codec.dart';
import '../codec/telemetry_packet_codec.dart';
import 'ble_diagnostics.dart';
import 'ble_permissions.dart';
import 'glove_connection.dart';

/// Real BLE implementation over flutter_blue_plus, speaking the as-built
/// firmware GATT contract (Code Reference §5: TELEMETRY / STATUS / CAL_INFO /
/// COMMAND on service d84f9c2e-…, device name TALKHIMIK-L/R).
///
/// Connect sequence (fix B2, strictly sequential with awaits):
///   connect → clearGattCache if bonded (Android) → discover → validate the
///   4 characteristics → requestMtu(247) and REQUIRE ≥ 32 (29-byte frame +
///   ATT header; retry once, else error) → setNotifyValue on TELEMETRY,
///   STATUS, CAL_INFO (each awaited, retried once, failures surfaced) →
///   subscribe via onValueReceived → READ STATUS + CAL_INFO → balanced
///   priority → ready. Never calls createBond; system pairing is neither
///   required nor depended on.
///
/// Every step and every decode rejection is recorded in [diagnostics]
/// (fix B1) — frames are never dropped silently.
class FlutterBlueGloveConnection implements GloveConnection {
  FlutterBlueGloveConnection({
    this.hand = GloveHand.left,
    this.permissions = const PermissionHandlerBlePermissions(),
    this.scanTimeout = const Duration(seconds: 15),
    this.connectTimeout = const Duration(seconds: 15),
  });

  /// Which glove this connection binds to; the scan matches the full
  /// advertised name TALKHIMIK-L / TALKHIMIK-R (master §7.3).
  final GloveHand hand;

  final BlePermissions permissions;

  /// How long the scan hunts for the glove's advertisement.
  final Duration scanTimeout;

  /// How long one connect + service discovery attempt may take.
  final Duration connectTimeout;

  /// The advertised name this connection's scan looks for.
  static String advertisedNameFor(GloveHand hand) =>
      '${GattIds.deviceNamePrefix}-${hand == GloveHand.left ? 'L' : 'R'}';

  /// Live link diagnostics (fix B1) — the Developer panel renders this.
  @override
  final BleDiagnostics diagnostics = BleDiagnostics();

  // Label packets are a later firmware stage; the stream stays open so the
  // transcript pipeline is identical to the mock's.
  final _gestures = StreamController<GestureResultPacket>.broadcast();
  final _telemetry = StreamController<TelemetryPacket>.broadcast();
  final _status = StreamController<DeviceStatusPacket>.broadcast();
  final _calInfo = StreamController<CalInfoPacket>.broadcast();
  final _phases = StreamController<GloveConnectionPhase>.broadcast();

  final List<StreamSubscription<Object?>> _subs = [];
  BluetoothDevice? _device;
  BluetoothCharacteristic? _commandChar;
  BluetoothCharacteristic? _statusChar;
  bool _manualDisconnect = false;
  bool _disposed = false;

  @override
  Stream<GestureResultPacket> get gestureResults => _gestures.stream;

  @override
  Stream<TelemetryPacket> get telemetry => _telemetry.stream;

  @override
  Stream<DeviceStatusPacket> get deviceStatus => _status.stream;

  @override
  Stream<CalInfoPacket> get calInfo => _calInfo.stream;

  @override
  Stream<GloveConnectionPhase> get phaseChanges => _phases.stream;

  void _log(String step) {
    debugPrint('[ble:${advertisedNameFor(hand)}] $step '
        '@${DateTime.now().toIso8601String()}');
  }

  @override
  Future<void> connect() async {
    _assertNotDisposed();
    final device = _device;
    if (device != null && device.isConnected) {
      _addPhase(GloveConnectionPhase.ready);
      return;
    }

    _teardownSubs();
    _manualDisconnect = false;
    try {
      // 1. Permissions first (C-S1): scanning fails cryptically without
      //    them, the classic first-demo failure point.
      _log('permissions');
      await permissions.ensureGranted();

      // 2. Adapter on? (Android only; turnOn throws off-Android.)
      _log('adapter');
      if (FlutterBluePlus.adapterStateNow == BluetoothAdapterState.off) {
        await FlutterBluePlus.turnOn();
      }

      // 3. Scan for this connection's glove by its full advertised name
      //    (C-F4, master §7.3: the L/R suffix decides the hand).
      //    Deliberately UNFILTERED: ColorOS and other OEM stacks
      //    throttle/drop service-UUID-filtered LE scans into zero results,
      //    and a name match in Dart is reliable everywhere. Step 5's GATT
      //    discovery still validates the service contract.
      _addPhase(GloveConnectionPhase.scanning);
      final advertisedName = advertisedNameFor(hand);
      _log('scan for $advertisedName');
      await FlutterBluePlus.startScan(timeout: scanTimeout);
      final ScanResult result;
      try {
        result = await FlutterBluePlus.onScanResults
            .expand((results) => results)
            .firstWhere((r) => r.advertisementData.advName == advertisedName)
            .timeout(scanTimeout);
      } on TimeoutException {
        throw StateError(
            'Glove "$advertisedName" not found within '
            '${scanTimeout.inSeconds} s');
      }
      if (FlutterBluePlus.isScanningNow) {
        await FlutterBluePlus.stopScan();
      }
      final target = result.device;

      // 4. Connect (C-S1). License.nonprofit: the thesis is educational
      //    use under the FlutterBluePlus License.
      _addPhase(GloveConnectionPhase.connecting);
      _log('gatt connect');
      await target.connect(license: License.nonprofit, timeout: connectTimeout);

      // 4b. Bond hygiene (fix B2/H3): a bond cached from Android Settings
      //     can serve a stale GATT table. Never create the bond ourselves —
      //     pairing is not required — but clear the stale cache when one
      //     exists, BEFORE discovery.
      var bonded = false;
      if (!kIsWeb && Platform.isAndroid) {
        try {
          final bond = await target.bondState.first
              .timeout(const Duration(seconds: 3));
          diagnostics.bondState = bond.name;
          bonded = bond == BluetoothBondState.bonded;
        } catch (e) {
          _log('bond read failed: $e');
        }
      }
      diagnostics.touch();
      _log('bond state ${diagnostics.bondState}');
      if (bonded) {
        _log('clearGattCache (bonded)');
        try {
          await target.clearGattCache();
        } catch (e) {
          _log('clearGattCache failed: $e');
        }
      }

      // 5. Discover + validate the four characteristics (Code Reference
      //    §5.1); a missing one means the profile does not match.
      _addPhase(GloveConnectionPhase.discoveringServices);
      _log('discoverServices');
      final services = await target.discoverServices();
      final telemetryChar = _findCharacteristic(services, GattIds.telemetry);
      final statusChar = _findCharacteristic(services, GattIds.deviceStatus);
      final commandChar = _findCharacteristic(services, GattIds.command);
      final calInfoChar = _findCharacteristic(services, GattIds.calInfo);
      diagnostics.characteristicsFound
        ..[GattIds.telemetry] = telemetryChar != null
        ..[GattIds.command] = commandChar != null
        ..[GattIds.deviceStatus] = statusChar != null
        ..[GattIds.calInfo] = calInfoChar != null;
      if (telemetryChar == null ||
          statusChar == null ||
          commandChar == null ||
          calInfoChar == null) {
        final missing = [
          if (telemetryChar == null) 'TELEMETRY',
          if (statusChar == null) 'STATUS',
          if (commandChar == null) 'COMMAND',
          if (calInfoChar == null) 'CAL_INFO',
        ].join(', ');
        diagnostics.lastError = 'Missing characteristics: $missing';
        diagnostics.touch();
        throw StateError(
            'Glove GATT profile does not match the firmware contract '
            '(missing: $missing)');
      }

      // 5b. MTU (fix B2/H1): the 29-byte TELEMETRY frame needs
      //     MTU ≥ 32 (ATT payload = MTU − 3). Request 247, require the
      //     result, retry once, else surface an error instead of silently
      //     receiving truncated frames.
      if (!kIsWeb && Platform.isAndroid) {
        _log('requestMtu 247');
        var mtu = await target.requestMtu(247);
        diagnostics.mtu = mtu;
        diagnostics.mtuAttempts++;
        if (mtu < 32) {
          _log('MTU $mtu too small — retry');
          mtu = await target.requestMtu(247);
          diagnostics.mtu = mtu;
          diagnostics.mtuAttempts++;
        }
        diagnostics.touch();
        if (mtu < 32) {
          diagnostics.lastError = AppStrings.mtuTooSmall;
          diagnostics.touch();
          throw StateError('${AppStrings.mtuTooSmall} (MTU $mtu)');
        }
        _log('MTU $mtu');
      }

      // 6. Link-loss detection feeds the auto-reconnect state machine
      //    (C-S5, NFR-9: the banner must appear within 3 s).
      _track(target.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected &&
            !_manualDisconnect) {
          _addPhase(GloveConnectionPhase.disconnected);
        }
      }));

      // 7. Notify enables (fix B2/H2): TELEMETRY, then STATUS, then
      //    CAL_INFO — each strictly awaited, retried once, failures
      //    surfaced (never swallowed).
      final enabledTelemetry =
          await _enableNotify(telemetryChar, GattIds.telemetry);
      final enabledStatus = await _enableNotify(statusChar, GattIds.deviceStatus);
      final enabledCalInfo = await _enableNotify(calInfoChar, GattIds.calInfo);
      if (!enabledTelemetry) {
        diagnostics.lastError = AppStrings.notifyTelemetryFailed;
        diagnostics.touch();
        throw StateError(AppStrings.notifyTelemetryFailed);
      }

      // 8. Subscribe via the notification stream for all three.
      final telemetrySub = telemetryChar.onValueReceived.listen((bytes) {
        _onNotify(GattIds.telemetry, bytes);
      });
      _track(telemetrySub);
      target.cancelWhenDisconnected(telemetrySub);

      final statusSub = statusChar.onValueReceived.listen((bytes) {
        _onNotify(GattIds.deviceStatus, bytes);
        try {
          _status.add(DeviceStatusCodec.decode(Uint8List.fromList(bytes)));
        } on FormatException {
          _countReject(reason: 'exception', char: 'STATUS');
        }
      });
      _track(statusSub);
      target.cancelWhenDisconnected(statusSub);

      final calInfoSub = calInfoChar.onValueReceived.listen((bytes) {
        _onNotify(GattIds.calInfo, bytes);
        try {
          _calInfo.add(CalInfoCodec.decode(Uint8List.fromList(bytes)));
        } on FormatException {
          _countReject(reason: 'exception', char: 'CAL_INFO');
        }
      });
      _track(calInfoSub);
      target.cancelWhenDisconnected(calInfoSub);

      // 9. READ STATUS + CAL_INFO once (notify may lag a beat).
      try {
        final initial = Uint8List.fromList(await statusChar.read());
        _status.add(DeviceStatusCodec.decode(initial));
      } on FormatException {
        // Firmware contract mismatch; the NOTIFY path still works.
      }
      try {
        final initial = Uint8List.fromList(await calInfoChar.read());
        _calInfo.add(CalInfoCodec.decode(initial));
      } on FormatException {
        // Firmware contract mismatch; the NOTIFY path still works.
      }

      // 10. Short connection interval for snappy telemetry.
      try {
        await target.requestConnectionPriority(
            connectionPriorityRequest: ConnectionPriority.high);
      } catch (_) {
        // Optional optimization — never fatal.
      }

      _device = target;
      _commandChar = commandChar;
      _statusChar = statusChar;
      _log('ready (mtu ${diagnostics.mtu}, notify T:$enabledTelemetry '
          'S:$enabledStatus C:$enabledCalInfo)');
      _addPhase(GloveConnectionPhase.ready);
    } catch (e) {
      diagnostics.lastError ??= e.toString();
      diagnostics.touch();
      _log('connect failed: $e');
      // Best-effort cleanup; the controller resets the phase on failure.
      await _teardownDevice();
      rethrow;
    }
  }

  /// One notify enable with a single retry; the result is recorded and
  /// returned (fix B2/H2 — errors are surfaced, never swallowed).
  Future<bool> _enableNotify(
      BluetoothCharacteristic char, String uuid) async {
    for (var attempt = 1; attempt <= 2; attempt++) {
      try {
        final ok = await char.setNotifyValue(true);
        diagnostics.notifyResults[uuid] = ok ? 'ok' : 'false';
        diagnostics.touch();
        if (ok) return true;
        _log('notify $uuid returned false (attempt $attempt)');
      } catch (e) {
        diagnostics.notifyResults[uuid] = '$e';
        diagnostics.touch();
        _log('notify $uuid failed (attempt $attempt): $e');
      }
    }
    return false;
  }

  void _onNotify(String uuid, List<int> bytes) {
    diagnostics.notifyCounts[uuid] = (diagnostics.notifyCounts[uuid] ?? 0) + 1;
    diagnostics.lastPayloadLength = bytes.length;
    diagnostics.touch();
    if (uuid == GattIds.telemetry) {
      if (bytes.length != GattIds.telemetryPacketLength) {
        // Wrong length — the classic truncated-frame signature (H1).
        _countReject(reason: 'length', char: 'TELEMETRY');
        return;
      }
      try {
        final frame =
            TelemetryPacketCodec.decode(Uint8List.fromList(bytes));
        if (frame.hand != hand) {
          _countReject(reason: 'hand', char: 'TELEMETRY');
          return;
        }
        diagnostics.lastTelemetryAt = DateTime.now();
        diagnostics.touch();
        _telemetry.add(frame);
      } catch (e) {
        _countReject(reason: 'exception', char: 'TELEMETRY');
        _log('telemetry decode exception: $e');
      }
    }
  }

  void _countReject({required String reason, required String char}) {
    switch (reason) {
      case 'length':
        diagnostics.rejectsLength++;
      case 'exception':
        diagnostics.rejectsException++;
      case 'hand':
        diagnostics.rejectsHandMismatch++;
    }
    _log('decode reject [$char] reason=$reason');
    diagnostics.touch();
  }

  /// Stateless glove (C-F7): the exact same path as [connect].
  @override
  Future<void> reconnect() => connect();

  /// WRITE one command (opcode + optional payload) to the Command
  /// characteristic (C-F5).
  @override
  Future<void> sendCommand(AppCommand command, {int value = 0}) async {
    _assertNotDisposed();
    final device = _device;
    final commandChar = _commandChar;
    if (device == null || !device.isConnected || commandChar == null) {
      throw StateError('Glove is not connected');
    }
    await commandChar.write(command.encode(value: value));
  }

  @override
  Future<void> refreshStatus() async {
    _assertNotDisposed();
    final statusChar = _statusChar;
    if (statusChar == null || !(_device?.isConnected ?? false)) return;
    try {
      _status.add(DeviceStatusCodec.decode(
          Uint8List.fromList(await statusChar.read())));
    } on FormatException {
      _countReject(reason: 'exception', char: 'STATUS');
    }
  }

  /// Deliberate teardown — must NOT trigger auto-reconnect.
  @override
  Future<void> disconnect() async {
    _manualDisconnect = true;
    await _teardownDevice();
    _addPhase(GloveConnectionPhase.disconnected);
  }

  @override
  void dispose() {
    _disposed = true;
    _teardownSubs();
    _gestures.close();
    _telemetry.close();
    _status.close();
    _calInfo.close();
    _phases.close();
  }

  // ---------------------------------------------------------------- internals

  BluetoothCharacteristic? _findCharacteristic(
      List<BluetoothService> services, String uuid) {
    for (final service in services) {
      for (final characteristic in service.characteristics) {
        if (characteristic.uuid.str128 == uuid) return characteristic;
      }
    }
    return null;
  }

  Future<void> _teardownDevice() async {
    final device = _device;
    _device = null;
    _commandChar = null;
    _statusChar = null;
    _teardownSubs();
    if (device == null) return;
    try {
      await device.disconnect();
    } catch (_) {
      // Already gone — nothing to clean up.
    }
  }

  void _teardownSubs() {
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    _subs.clear();
  }

  void _track(StreamSubscription<Object?> sub) => _subs.add(sub);

  void _addPhase(GloveConnectionPhase phase) {
    diagnostics.phase = phase;
    diagnostics.touch();
    if (_disposed) return;
    _phases.add(phase);
  }

  void _assertNotDisposed() {
    if (_disposed) throw StateError('Connection disposed');
  }
}
