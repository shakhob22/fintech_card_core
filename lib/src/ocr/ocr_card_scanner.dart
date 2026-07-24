import 'dart:async';
import 'dart:io' show Platform;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'dart:ui' show Rect;

import '../core/interfaces/i_ocr_scanner.dart';
import '../core/luhn.dart';
import '../core/models/card_data.dart';
import '../core/models/card_enums.dart';
import '../core/models/card_reader_exception.dart';
import '../core/models/card_reader_state.dart';
import '../services/card_ocr_engine.dart';
import 'ocr_result_accumulator.dart';

/// Camera-based card scanner powered by the on-device TFLite CRNN model.
///
/// ```
/// CameraImage
///   → CardOcrEngine (isolate preprocess + IsolateInterpreter)
///   → Greedy CTC (raw digits)
///   → OcrResultAccumulator (per-digit majority over 3–5 frames)
///   → Luhn + length 16 → CardReaderSuccessState
/// ```
class OcrCardScanner implements IOcrScanner {
  /// Minimum gap between inference attempts (~10 fps).
  static const _throttleInterval = Duration(milliseconds: 100);

  final _stateCtrl = StreamController<CardReaderState>.broadcast();
  final CardOcrEngine _engine;
  final OcrResultAccumulator _accumulator;

  CameraController? _cameraCtrl;
  CameraDescription? _camera;

  bool _isScanning = false;
  bool _isProcessing = false;
  DateTime _lastOcrAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Digits-strip normalized ROI from the overlay (0–1).
  Rect? _scanRoi;

  /// Creates a scanner. Pass [engine] / [accumulator] only in tests.
  OcrCardScanner({
    CardOcrEngine? engine,
    OcrResultAccumulator? accumulator,
  })  : _engine = engine ?? CardOcrEngine(),
        _accumulator = accumulator ?? OcrResultAccumulator();

  /// Latest 320×48 model-input PNG while [CardOcrEngine.debugDiagnostics] is on.
  ValueListenable<Uint8List?> get debugPreviewBytes =>
      _engine.debugPreviewBytes;

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
      if (CardOcrEngine.debugDiagnostics) {
        // ignore: avoid_print
        print(
          'OcrCardScanner frame: '
          '${image.width}x${image.height} '
          'sensorOrientation=$rotation° '
          'roi=$_scanRoi',
        );
      }

      // Per-frame: raw CTC digits (no Luhn). Consensus + Luhn happen below.
      final raw = await _engine.recognizeCameraImage(
        image,
        normalizedRoi: _scanRoi,
        rotationDegrees: rotation,
      );
      if (!_isScanning || raw == null) return;

      _accumulator.add(raw);
      final consensus = _accumulator.accumulateVotes();

      if (CardOcrEngine.debugDiagnostics) {
        // ignore: avoid_print
        print(
          'OcrCardScanner raw="$raw" '
          'buffer=${_accumulator.length} '
          'consensus=${consensus ?? "(pending)"}',
        );
      }

      if (consensus == null) return;
      if (consensus.length != CardOcrEngine.expectedPanLength) return;
      if (!Luhn.validate(consensus)) return;

      _emitSuccess(CardData.fromOcr(pan: consensus));
    } catch (e, st) {
      if (CardOcrEngine.debugDiagnostics) {
        // ignore: avoid_print
        print('OcrCardScanner frame error: $e\n$st');
      }
      // Ignore individual frame errors — keep scanning.
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
