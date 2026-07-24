import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui' show Rect;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';

import '../core/interfaces/i_ocr_scanner.dart';
import '../core/luhn.dart';
import '../core/models/card_data.dart';
import '../core/models/card_enums.dart';
import '../core/models/card_reader_exception.dart';
import '../core/models/card_reader_state.dart';
import '../services/paddle_card_ocr_engine.dart';
import 'ocr_result_accumulator.dart';

/// Camera-based card scanner powered by on-device **PaddleOCR** (PP-OCRv2 lite).
///
/// ```
/// CameraImage
///   → JPEG encode (isolate)
///   → PaddleCardOcrEngine (Paddle Lite det+cls+rec)
///   → CardFieldExtractor (PAN / expiry / Luhn)
///   → OcrResultAccumulator (2 matching frames)
///   → CardReaderSuccessState
/// ```
class OcrCardScanner implements IOcrScanner {
  /// Paddle is heavier than TFLite strip OCR — ~2–3 fps.
  static const _throttleInterval = Duration(milliseconds: 400);

  final _stateCtrl = StreamController<CardReaderState>.broadcast();
  final PaddleCardOcrEngine _engine;
  final OcrResultAccumulator _accumulator;

  CameraController? _cameraCtrl;
  CameraDescription? _camera;

  bool _isScanning = false;
  bool _isProcessing = false;
  DateTime _lastOcrAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Full-card normalized ROI from the overlay (0–1).
  Rect? _scanRoi;

  /// Creates a scanner. Pass [engine] / [accumulator] only in tests.
  OcrCardScanner({
    PaddleCardOcrEngine? engine,
    OcrResultAccumulator? accumulator,
  })  : _engine = engine ?? PaddleCardOcrEngine(),
        _accumulator = accumulator ?? OcrResultAccumulator(minFrames: 2, windowSize: 4);

  /// Legacy debug hook — Paddle path does not emit a 320×48 preview.
  ValueListenable<Uint8List?> get debugPreviewBytes =>
      const _NullBytesListenable();

  // ── IOcrScanner ───────────────────────────────────────────────────────────

  @override
  Stream<CardReaderState> get stateStream => _stateCtrl.stream;

  @override
  CameraController? get cameraController => _cameraCtrl;

  @override
  void setScanRoi(Rect? normalizedRoi) {
    _scanRoi = normalizedRoi;
  }

  @override
  Future<void> startScan() async {
    if (_isScanning) return;

    _resetVotes();

    try {
      if (!_engine.isReady) {
        await _engine.load();
      }

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

      final format = Platform.isAndroid
          ? ImageFormatGroup.yuv420
          : ImageFormatGroup.bgra8888;

      _cameraCtrl = CameraController(
        _camera!,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: format,
      );

      await _cameraCtrl!.initialize();
      try {
        await _cameraCtrl!.setFocusMode(FocusMode.auto);
      } catch (_) {}
      try {
        await _cameraCtrl!.setExposureMode(ExposureMode.auto);
      } catch (_) {}

      _isScanning = true;

      _emit(const CardReaderScanningState(
        mode: CardReadMode.ocr,
        message: 'Point camera at the card',
      ));

      await _cameraCtrl!.startImageStream(_onCameraImage);
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
    _resetVotes();
    _scanRoi = null;

    final ctrl = _cameraCtrl;
    _cameraCtrl = null;

    if (ctrl != null) {
      try {
        if (ctrl.value.isStreamingImages) {
          await ctrl.stopImageStream();
        }
      } catch (_) {}
      await ctrl.dispose();
    }

    if (!_stateCtrl.isClosed) {
      _emit(const CardReaderIdleState());
    }
  }

  @override
  Future<void> dispose() async {
    await stopScan();
    await _engine.dispose();
    if (!_stateCtrl.isClosed) await _stateCtrl.close();
  }

  // ── Image stream ──────────────────────────────────────────────────────────

  void _onCameraImage(CameraImage image) {
    if (!_isScanning || _isProcessing || !_engine.isReady) return;

    final now = DateTime.now();
    if (now.difference(_lastOcrAt) < _throttleInterval) return;

    _isProcessing = true;
    _lastOcrAt = now;
    _processFrame(image).whenComplete(() => _isProcessing = false);
  }

  Future<void> _processFrame(CameraImage image) async {
    try {
      final rotation = _camera?.sensorOrientation ?? 0;
      if (PaddleCardOcrEngine.debugDiagnostics) {
        // ignore: avoid_print
        print(
          'OcrCardScanner(Paddle) frame: '
          '${image.width}x${image.height} '
          'sensorOrientation=$rotation° '
          'roi=$_scanRoi',
        );
      }

      final fields = await _engine.recognizeCameraImage(
        image,
        normalizedRoi: _scanRoi,
        rotationDegrees: rotation,
      );
      if (!_isScanning || fields == null || fields.pan == null) return;

      final pan = fields.pan!;
      _accumulator.add(pan);
      final consensus = _accumulator.accumulateVotes();

      if (PaddleCardOcrEngine.debugDiagnostics) {
        // ignore: avoid_print
        print(
          'OcrCardScanner(Paddle) pan="$pan" '
          'luhn=${fields.luhnPass} '
          'expiry=${fields.expiryDate} '
          'buffer=${_accumulator.length} '
          'consensus=${consensus ?? "(pending)"}',
        );
      }

      if (consensus == null) return;
      if (consensus.length != 16) return;
      if (!Luhn.validate(consensus)) return;

      _emitSuccess(
        CardData.fromOcr(
          pan: consensus,
          expiryDate: fields.expiryDate,
          cardholderName: fields.cardholderName,
        ),
      );
    } catch (e, st) {
      if (PaddleCardOcrEngine.debugDiagnostics) {
        // ignore: avoid_print
        print('OcrCardScanner(Paddle) frame error: $e\n$st');
      }
    }
  }

  void _emitSuccess(CardData data) {
    if (!_isScanning) return;
    _isScanning = false;
    _emit(CardReaderSuccessState(data));
    unawaited(_stopStreamOnly());
  }

  Future<void> _stopStreamOnly() async {
    final ctrl = _cameraCtrl;
    if (ctrl != null && ctrl.value.isStreamingImages) {
      try {
        await ctrl.stopImageStream();
      } catch (_) {}
    }
  }

  void _resetVotes() {
    _accumulator.clear();
    _lastOcrAt = DateTime.fromMillisecondsSinceEpoch(0);
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

class _NullBytesListenable extends ValueListenable<Uint8List?> {
  const _NullBytesListenable();

  @override
  Uint8List? get value => null;

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}
