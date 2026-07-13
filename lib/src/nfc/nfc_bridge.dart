import 'dart:async';
import 'package:flutter/services.dart';

/// Low-level Dart ↔ Native bridge for NFC operations.
///
/// Channel contracts:
///
///   **MethodChannel** `fintech_card_core/nfc`
///   | Method              | Args                     | Returns        |
///   |---------------------|--------------------------|----------------|
///   | `nfc/isAvailable`   | —                        | `bool`         |
///   | `nfc/startSession`  | `{alertMessage?: String}`| `null`         |
///   | `nfc/stopSession`   | `{errorMessage?: String}`| `null`         |
///   | `nfc/transceive`    | `{apdu: List<int>}`      | `List<int>`    |
///
///   **EventChannel** `fintech_card_core/nfc/events`
///   Events are `Map<String,dynamic>` with key `type`:
///   - `'tagDetected'`  — an ISO 7816 tag has been connected
///   - `'sessionEnded'` — the NFC session was invalidated (user cancelled)
///   - `'error'`        — native error; `message` key carries the description
///
/// The native side is intentionally kept as a **thin bridge** — it only
/// activates the OS NFC reader and relays raw bytes. All command logic
/// (APDU building, TLV parsing, EMV sequencing) is performed in Dart.
class NfcBridge {
  static const _method = MethodChannel('fintech_card_core/nfc');
  static const _event = EventChannel('fintech_card_core/nfc/events');

  Stream<Map<String, dynamic>>? _events;

  /// Broadcast stream of native NFC events.
  Stream<Map<String, dynamic>> get events {
    _events ??= _event
        .receiveBroadcastStream()
        .map((raw) => Map<String, dynamic>.from(raw as Map));
    return _events!;
  }

  // ── Control ───────────────────────────────────────────────────────────────

  /// Returns `true` when NFC hardware is present and enabled.
  Future<bool> isAvailable() async {
    final result = await _method.invokeMethod<bool>('nfc/isAvailable');
    return result ?? false;
  }

  /// Request the OS to begin an NFC reader session.
  Future<void> startSession({String? alertMessage}) {
    return _method.invokeMethod<void>('nfc/startSession', {
      'alertMessage': alertMessage,
    });
  }

  /// Invalidate the active NFC session.
  /// Pass [errorMessage] to show the system error banner (iOS only).
  Future<void> stopSession({String? errorMessage}) {
    return _method.invokeMethod<void>('nfc/stopSession', {
      'errorMessage': errorMessage,
    });
  }

  // ── APDU transceive ───────────────────────────────────────────────────────

  /// Send an APDU [command] to the connected tag and return the raw response.
  ///
  /// This is the single "wire" between Dart and hardware — analogous to how a
  /// microcontroller pushes bytes over SPI and waits for the peripheral's reply.
  /// The native code does no interpretation: it forwards bytes verbatim.
  Future<List<int>> transceive(List<int> command) async {
    final result = await _method.invokeMethod<List<dynamic>>(
      'nfc/transceive',
      {'apdu': command},
    );
    if (result == null) {
      throw PlatformException(
        code: 'NULL_RESPONSE',
        message: 'Native transceive returned null',
      );
    }
    return result.cast<int>();
  }
}
