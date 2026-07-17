import 'dart:async';

import '../mock/mock_card_provider.dart';
import '../nfc/nfc_card_reader.dart';
import '../ocr/ocr_card_scanner.dart';
import 'interfaces/i_mock_provider.dart';
import 'interfaces/i_nfc_reader.dart';
import 'interfaces/i_ocr_scanner.dart';
import 'luhn.dart';
import 'models/card_data.dart';
import 'models/card_enums.dart';
import 'models/card_reader_exception.dart';
import 'models/card_reader_state.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Public Interface
// ─────────────────────────────────────────────────────────────────────────────

/// Central "motor" of the fintech_card_core package.
///
/// Integrates NFC, OCR, manual entry, and mock-testing into a single,
/// observable API. Consumers react to [stateStream] and never interact
/// with the individual sub-readers directly.
///
/// ```dart
/// final controller = CardReaderController();
///
/// controller.stateStream.listen((state) {
///   switch (state) {
///     case CardReaderSuccessState(:final data): print(data.maskedPan);
///     case CardReaderErrorState(:final exception): print(exception);
///     default: break;
///   }
/// });
///
/// await controller.startNfcScan();
/// ```
abstract interface class ICardReaderController {
  /// Unified broadcast stream — all sub-readers funnel their state here.
  Stream<CardReaderState> get stateStream;

  /// Synchronous snapshot of the last emitted state.
  CardReaderState get currentState;

  // ── NFC ──────────────────────────────────────────────────────────────────

  /// Start an NFC session. Emits [CardReaderScanningState] immediately, then
  /// [CardReaderSuccessState] or [CardReaderErrorState] when complete.
  Future<void> startNfcScan();

  /// Cancel the active NFC session. Emits [CardReaderIdleState].
  Future<void> stopNfcScan();

  // ── OCR ──────────────────────────────────────────────────────────────────

  /// Activate the camera for OCR card scanning.
  Future<void> startOcrScan();

  /// Stop the OCR scanner and release the camera.
  Future<void> stopOcrScan();

  // ── Manual Input ─────────────────────────────────────────────────────────

  /// Validate and wrap manually-entered card fields.
  /// Throws [CardReaderException] with [CardReaderErrorCode.manualInputInvalid]
  /// if the PAN fails the Luhn check or the expiry format is wrong.
  Future<CardData> submitManualInput({
    required String pan,
    required String expiryDate,
    String? cvv,
    String? cardholderName,
  });

  // ── Mock / Developer Mode ─────────────────────────────────────────────────

  /// Load a mock card for developer testing.
  ///
  /// [simulatedDelay] — artificial network latency.
  /// [simulateError]  — throw instead of returning data (tests error flows).
  Future<CardData> loadMockCard({
    MockCardPreset preset = MockCardPreset.visa,
    Duration? simulatedDelay,
    bool simulateError = false,
  });

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  /// Stop any active scan and reset to [CardReaderIdleState].
  Future<void> reset();

  /// Dispose all sub-readers and close the state stream.
  Future<void> dispose();
}

// ─────────────────────────────────────────────────────────────────────────────
// Concrete Implementation
// ─────────────────────────────────────────────────────────────────────────────

/// Default production implementation of [ICardReaderController].
///
/// Sub-readers are injected for testability; production callers use the
/// zero-argument constructor which wires up the real implementations.
class CardReaderController implements ICardReaderController {
  final INfcReader _nfcReader;
  final IOcrScanner _ocrScanner;
  final IMockProvider _mockProvider;

  final _stateController = StreamController<CardReaderState>.broadcast();
  StreamSubscription<CardReaderState>? _nfcSub;
  StreamSubscription<CardReaderState>? _ocrSub;

  CardReaderState _currentState = const CardReaderIdleState();

  CardReaderController({
    INfcReader? nfcReader,
    IOcrScanner? ocrScanner,
    IMockProvider? mockProvider,
  })  : _nfcReader = nfcReader ?? NfcCardReader(),
        _ocrScanner = ocrScanner ?? OcrCardScanner(),
        _mockProvider = mockProvider ?? MockCardProvider();

  /// Exposes the underlying OCR scanner so UI widgets (e.g. [CardScannerOverlay])
  /// can access [IOcrScanner.cameraController] without creating a second camera.
  IOcrScanner get ocrScanner => _ocrScanner;

  // ── ICardReaderController ─────────────────────────────────────────────────

  @override
  Stream<CardReaderState> get stateStream => _stateController.stream;

  @override
  CardReaderState get currentState => _currentState;

  // ── NFC ──────────────────────────────────────────────────────────────────

  @override
  Future<void> startNfcScan() async {
    await _cancelOcr();
    _nfcSub?.cancel();
    _nfcSub = _nfcReader.stateStream.listen(_emit);
    await _nfcReader.startScan();
  }

  @override
  Future<void> stopNfcScan() async {
    await _nfcReader.stopScan();
    _nfcSub?.cancel();
    _nfcSub = null;
  }

  // ── OCR ──────────────────────────────────────────────────────────────────

  @override
  Future<void> startOcrScan() async {
    await _cancelNfc();
    _ocrSub?.cancel();
    _ocrSub = _ocrScanner.stateStream.listen(_emit);
    await _ocrScanner.startScan();
  }

  @override
  Future<void> stopOcrScan() async {
    await _ocrScanner.stopScan();
    _ocrSub?.cancel();
    _ocrSub = null;
  }

  // ── Manual Input ─────────────────────────────────────────────────────────

  @override
  Future<CardData> submitManualInput({
    required String pan,
    required String expiryDate,
    String? cvv,
    String? cardholderName,
  }) async {
    final cleaned = pan.replaceAll(RegExp(r'[\s\-]'), '');

    if (!Luhn.validate(cleaned)) {
      throw const CardReaderException(
        code: CardReaderErrorCode.manualInputInvalid,
        message: 'Invalid card number — Luhn check failed.',
      );
    }

    if (!RegExp(r'^(0[1-9]|1[0-2])\/\d{2}$').hasMatch(expiryDate)) {
      throw const CardReaderException(
        code: CardReaderErrorCode.manualInputInvalid,
        message: 'Invalid expiry date — expected MM/YY format.',
      );
    }

    final data = CardData.fromManual(
      pan: cleaned,
      expiryDate: expiryDate,
      cvv: cvv,
      cardholderName: cardholderName,
    );

    _emit(CardReaderSuccessState(data));
    return data;
  }

  // ── Mock / Developer Mode ─────────────────────────────────────────────────

  @override
  Future<CardData> loadMockCard({
    MockCardPreset preset = MockCardPreset.visa,
    Duration? simulatedDelay,
    bool simulateError = false,
  }) async {
    _emit(const CardReaderScanningState(
      mode: CardReadMode.mock,
      message: 'Loading mock card…',
    ));

    if (simulatedDelay != null) {
      await Future<void>.delayed(simulatedDelay);
    }

    if (simulateError) {
      final ex = const CardReaderException(
        code: CardReaderErrorCode.mockProviderError,
        message: 'Simulated transaction declined.',
      );
      _emit(CardReaderErrorState(ex));
      throw ex;
    }

    final data = await _mockProvider.getCard(preset: preset);
    _emit(CardReaderSuccessState(data));
    return data;
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  Future<void> reset() async {
    await _cancelNfc();
    await _cancelOcr();
    _emit(const CardReaderIdleState());
  }

  @override
  Future<void> dispose() async {
    await _nfcReader.dispose();
    await _ocrScanner.dispose();
    _nfcSub?.cancel();
    _ocrSub?.cancel();
    if (!_stateController.isClosed) {
      await _stateController.close();
    }
  }

  // ── Internal helpers ──────────────────────────────────────────────────────

  void _emit(CardReaderState state) {
    _currentState = state;
    if (!_stateController.isClosed) _stateController.add(state);
  }

  Future<void> _cancelNfc() async {
    _nfcSub?.cancel();
    _nfcSub = null;
    await _nfcReader.stopScan();
  }

  Future<void> _cancelOcr() async {
    _ocrSub?.cancel();
    _ocrSub = null;
    await _ocrScanner.stopScan();
  }

}
