import 'dart:async';

import 'package:fintech_card_core/src/nfc/nfc_bridge.dart';
import 'package:fintech_card_core/src/nfc/nfc_card_reader.dart';
import 'package:fintech_card_core/src/core/models/card_reader_exception.dart';
import 'package:fintech_card_core/src/core/models/card_reader_state.dart';
import 'package:flutter_test/flutter_test.dart';

/// In-memory bridge for unit tests (no MethodChannel).
class _FakeBridge extends NfcBridge {
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  int stopSessionCalls = 0;

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<void> startSession({String? alertMessage}) async {}

  @override
  Future<void> stopSession({String? errorMessage}) async {
    stopSessionCalls++;
  }

  @override
  Future<List<int>> transceive(List<int> command) async => [0x6A, 0x82];

  void emit(Map<String, dynamic> event) => _events.add(event);

  Future<void> dispose() => _events.close();
}

void main() {
  test('late sessionEnded does not overwrite terminal Error with Idle', () async {
    final bridge = _FakeBridge();
    final reader = NfcCardReader(bridge: bridge);
    final states = <CardReaderState>[];
    final sub = reader.stateStream.listen(states.add);

    await reader.startScan();
    expect(states.last, isA<CardReaderScanningState>());

    bridge.emit({
      'type': 'error',
      'message': 'Missing required entitlement',
    });
    await Future<void>.delayed(Duration.zero);

    expect(states.last, isA<CardReaderErrorState>());
    final err = states.last as CardReaderErrorState;
    expect(err.exception.code, CardReaderErrorCode.nfcNotAvailable);
    expect(err.exception.message, contains('CoreNFC'));

    final before = states.length;
    bridge.emit({'type': 'sessionEnded'});
    await Future<void>.delayed(Duration.zero);

    expect(states.length, before);
    expect(states.last, isA<CardReaderErrorState>());

    await sub.cancel();
    await reader.dispose();
    await bridge.dispose();
  });

  test('user cancel while scanning emits Idle', () async {
    final bridge = _FakeBridge();
    final reader = NfcCardReader(bridge: bridge);
    final states = <CardReaderState>[];
    final sub = reader.stateStream.listen(states.add);

    await reader.startScan();
    bridge.emit({'type': 'sessionEnded'});
    await Future<void>.delayed(Duration.zero);

    expect(states.last, isA<CardReaderIdleState>());

    await sub.cancel();
    await reader.dispose();
    await bridge.dispose();
  });
}
