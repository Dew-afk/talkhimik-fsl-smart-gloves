/// GATT contract constants shared between the glove firmware (ESP32-S3,
/// NimBLE) and this app.
///
/// Live contract: the as-built firmware — `docs/TALKHIMIK.md` §1
/// (`firmware/glove-left/config.h`, same in glove-right), mirrored by the web
/// dashboard. The app consumes TELEMETRY / STATUS / CAL_INFO and writes
/// COMMAND opcodes.
library;

class GattIds {
  GattIds._();

  /// Advertised device name prefix: `TALKHIMIK-L` / `TALKHIMIK-R` (the hand
  /// suffix comes from the build-time HAND constant / NVS).
  static const String deviceNamePrefix = 'TALKHIMIK';

  /// Talkhimik Glove Service — container for the four characteristics.
  static const String gloveService = 'd84f9c2e-6b1a-4e57-9f3d-2a8c7e5b1f04';

  /// Telemetry: READ + NOTIFY — 29-byte little-endian sensor frame every
  /// 50 ms (configurable via SET_RATE).
  static const String telemetry = '7a3e1b9c-2d4f-48a6-b7e2-5c9d0f8a3b61';

  /// Command: WRITE + WRITE-NO-RESPONSE — u8 opcode + optional payload.
  static const String command = '3f8d2a6b-9c4e-4d7f-a1e3-6b5c8d0e2f49';

  /// Device Status: READ + NOTIFY — 5 bytes (fw 1.2.0) or 9 bytes
  /// (fw 1.3.0+) every 250 ms.
  static const String deviceStatus = 'c2b6e8d4-1a7f-4c3e-9d5b-0f2a6e8c4d73';

  /// Calibration Info: READ + NOTIFY — 104-byte profile table, pushed after
  /// every calibration save.
  static const String calInfo = 'a1f2c3d4-5e6f-4a7b-8c9d-0e1f2a3b4c5d';

  /// TELEMETRY frame length in bytes (Code Reference §5.2).
  static const int telemetryPacketLength = 29;

  /// STATUS frame length in bytes (Code Reference §5.3): fw 1.2.0 sends
  /// the 5-byte base; fw 1.3.0 appends mount_calibration_id (u32 LE) for 9.
  static const int statusPacketLength = 5;
  static const int statusPacketLengthWithMount = 9;

  /// CAL_INFO table length in bytes (Code Reference §5.5).
  static const int calInfoPacketLength = 104;
}

/// Reconnection policy for the stateless glove (SRS C-F7, C-S5, NFR-9).
class ReconnectPolicy {
  ReconnectPolicy._();

  /// Backoff steps in seconds: 1, 2, 4, 8, then cap at 30 s.
  static const List<int> backoffSeconds = [1, 2, 4, 8, 30];

  /// The app must surface a visible "connection lost" state within this
  /// bound (SRS C-S5: 3 s).
  static const Duration lostNoticeBound = Duration(seconds: 3);
}
