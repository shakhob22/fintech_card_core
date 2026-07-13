import 'dart:async';

import 'package:camera/camera.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import '../core/interfaces/i_ocr_scanner.dart';
import '../core/models/card_enums.dart';
import '../core/models/card_reader_exception.dart';
import '../core/models/card_reader_state.dart';
import 'ocr_parser.dart';

/// Camera-based OCR card scanner.
///
/// Uses the device rear camera + ML Kit text recognition to detect a payment
/// card and extract the PAN and expiry date.
///
/// The scanner captures a still image every [_captureInterval] and runs it
/// through [TextRecognizer]. Once a valid card is detected, the state stream
/// emits [CardReaderSuccessState] and the camera is released automatically.
class OcrCardScanner implements IOcrScanner {
  static const _captureInterval = Duration(milliseconds: 800);

  final _stateCtrl = StreamController<CardReaderState>.broadcast();
  final _textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);

  CameraController? _cameraCtrl;
  CameraDescription? _camera;
  Timer? _captureTimer;

  bool _isScanning = false;
  bool _isProcessing = false;

  // ── IOcrScanner ───────────────────────────────────────────────────────────

  @override
  Stream<CardReaderState> get stateStream => _stateCtrl.stream;

  @override
  CameraController? get cameraController => _cameraCtrl;

  @override
  Future<void> startScan() async {
    if (_isScanning) return;

    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        _emitError(
          CardReaderErrorCode.ocrCameraPermissionDenied,
          'No cameras found on this device.',
        );
        return;
      }

      // Prefer rear-facing camera
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
    await _textRecognizer.close();
    if (!_stateCtrl.isClosed) await _stateCtrl.close();
  }

  // ── Capture loop ──────────────────────────────────────────────────────────

  Future<void> _captureAndOcr() async {
    if (!_isScanning || _isProcessing || _cameraCtrl == null) return;
    _isProcessing = true;

    try {
      final xFile = await _cameraCtrl!.takePicture();
      final inputImage = InputImage.fromFilePath(xFile.path);
      final recognised = await _textRecognizer.processImage(inputImage);

      if (!_isScanning) return; // stopped while processing

      final cardData = OcrParser.parse(recognised.text);
      if (cardData != null) {
        _isScanning = false;
        _captureTimer?.cancel();
        _captureTimer = null;
        _emit(CardReaderSuccessState(cardData));
      }
    } catch (_) {
      // Ignore individual frame errors — keep scanning
    } finally {
      _isProcessing = false;
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

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
