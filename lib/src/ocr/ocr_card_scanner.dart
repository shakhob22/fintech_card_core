import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/services.dart';

import '../core/interfaces/i_ocr_scanner.dart';
import '../core/models/card_enums.dart';
import '../core/models/card_reader_exception.dart';
import '../core/models/card_reader_state.dart';
import 'ocr_parser.dart';

/// Camera-based OCR card scanner.
///
/// Uses the device rear camera to capture still frames, then delegates text
/// recognition to the native platform via [_ocrChannel]:
/// - iOS  → Vision.framework / VNRecognizeTextRequest (iOS 13+)
/// - Android → com.google.mlkit:text-recognition (native SDK, no Flutter wrapper)
///
/// ## Reliability strategy for shiny / embossed cards
///
/// A single camera frame can be partially obscured by specular glare, causing
/// the OCR to read a broken PAN that the regex cannot match. Two mechanisms
/// work together to handle this:
///
/// 1. **Native preprocessing** — the native side runs a grayscale → contrast
///    boost → unsharp-mask pipeline and crops to the card-frame ROI before
///    invoking the OCR engine (see the platform implementations).
///
/// 2. **Two-frame PAN voting** — once a PAN is found, the same PAN must appear
///    in the *next* captured frame before a [CardReaderSuccessState] is emitted.
///    A glare artifact that accidentally forms a 16-digit pattern is extremely
///    unlikely to repeat identically 400 ms later, so this eliminates virtually
///    all false positives while adding only one capture interval to accept time.
///
/// Once a valid card is detected, the state stream emits
/// [CardReaderSuccessState] and the camera is released automatically.
class OcrCardScanner implements IOcrScanner {
  // 400 ms gives ≈2.5 frames/s; with 2-frame voting the minimum acceptance
  // time is 800 ms — the same wall-clock total as the old single-frame 800 ms
  // approach, but far more reliable on reflective surfaces.
  static const _captureInterval = Duration(milliseconds: 400);
  static const _ocrChannel = MethodChannel('fintech_card_core/ocr');

  final _stateCtrl = StreamController<CardReaderState>.broadcast();

  CameraController? _cameraCtrl;
  CameraDescription? _camera;
  Timer? _captureTimer;

  bool _isScanning = false;
  bool _isProcessing = false;

  // ── Two-frame PAN voting ───────────────────────────────────────────────────
  String? _lastPan;
  int _panMatchCount = 0;

  // ── IOcrScanner ───────────────────────────────────────────────────────────

  @override
  Stream<CardReaderState> get stateStream => _stateCtrl.stream;

  @override
  CameraController? get cameraController => _cameraCtrl;

  @override
  Future<void> startScan() async {
    if (_isScanning) return;

    _resetVoting();

    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        _emitError(
          CardReaderErrorCode.ocrCameraPermissionDenied,
          'No cameras found on this device.',
        );
        return;
      }

      _camera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      _cameraCtrl = CameraController(
        _camera!,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );

      await _cameraCtrl!.initialize();
      _isScanning = true;

      _emit(const CardReaderScanningState(
        mode: CardReadMode.ocr,
        message: 'Point camera at the card',
      ));

      _captureTimer = Timer.periodic(_captureInterval, (_) => _captureAndOcr());
    } catch (e) {
      _emitError(
        CardReaderErrorCode.ocrCameraPermissionDenied,
        'Camera initialisation failed: $e',
        cause: e,
      );
    }
  }

  @override
  Future<void> stopScan() async {
    _isScanning = false;
    _resetVoting();
    _captureTimer?.cancel();
    _captureTimer = null;
    await _cameraCtrl?.dispose();
    _cameraCtrl = null;
    if (!_stateCtrl.isClosed) {
      _emit(const CardReaderIdleState());
    }
  }

  @override
  Future<void> dispose() async {
    await stopScan();
    if (!_stateCtrl.isClosed) await _stateCtrl.close();
  }

  // ── Capture loop ──────────────────────────────────────────────────────────

  Future<void> _captureAndOcr() async {
    if (!_isScanning || _isProcessing || _cameraCtrl == null) return;
    _isProcessing = true;

    try {
      final xFile = await _cameraCtrl!.takePicture();

      final text = await _ocrChannel.invokeMethod<String>(
        'ocr/recognizeText',
        {'imagePath': xFile.path},
      );

      if (!_isScanning) return;

      final cardData = OcrParser.parse(text ?? '');
      if (cardData != null) {
        // Two-frame voting: require the same PAN on two consecutive frames
        // before accepting. Resets when a different PAN is seen.
        if (cardData.pan == _lastPan) {
          _panMatchCount++;
        } else {
          _lastPan = cardData.pan;
          _panMatchCount = 1;
        }

        if (_panMatchCount >= 2) {
          _isScanning = false;
          _captureTimer?.cancel();
          _captureTimer = null;
          _emit(CardReaderSuccessState(cardData));
        }
      }
    } catch (_) {
      // Ignore individual frame errors — keep scanning
    } finally {
      _isProcessing = false;
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  void _resetVoting() {
    _lastPan = null;
    _panMatchCount = 0;
  }

  void _emit(CardReaderState state) {
    if (!_stateCtrl.isClosed) _stateCtrl.add(state);
  }

  void _emitError(
    CardReaderErrorCode code,
    String message, {
    Object? cause,
  }) {
    _emit(CardReaderErrorState(
      CardReaderException(code: code, message: message, cause: cause),
    ));
  }
}
