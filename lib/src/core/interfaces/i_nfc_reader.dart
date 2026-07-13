import '../models/card_reader_state.dart';

/// Contract for the NFC hardware bridge.
///
/// Native code is a thin "bridge-only" layer:
///   - Start/stop the OS NFC session
///   - Relay raw APDU bytes to/from the card
///
/// All EMV logic (APDU command building, TLV parsing) lives in Dart.
abstract interface class INfcReader {
  /// Whether NFC hardware is present and enabled on this device.
  bool get isAvailable;

  /// Broadcast stream of state transitions.
  Stream<CardReaderState> get stateStream;

  /// Activate the NFC session and begin listening for ISO 7816 tags.
  Future<void> startScan();

  /// Stop the NFC session gracefully.
  Future<void> stopScan();

  /// Release all resources.
  Future<void> dispose();
}
