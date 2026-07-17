import 'dart:async';
import 'dart:io' show Platform;

import 'package:camera/camera.dart';
import 'package:flutter/services.dart';

import '../core/interfaces/i_ocr_scanner.dart';
import '../core/models/card_enums.dart';
import '../core/models/card_data.dart';
import '../core/models/card_reader_exception.dart';
import '../core/models/card_reader_state.dart';
import 'ocr_parser.dart';

/// Camera-based OCR card scanner.
///
/// Uses a live [CameraController.startImageStream] feed and delegates text
/// recognition to the native platform via [_ocrChannel]:
/// - iOS  → Vision.framework / VNRecognizeTextRequest (iOS 13+)
/// - Android → com.google.mlkit:text-recognition (native SDK)
///
/// ## Reliability strategy for shiny / embossed cards
///
/// 1. **Live frames** — avoids JPEG encode/write latency of still photos.
/// 2. **Native preprocessing** — grayscale, local contrast / glare compression,
///    unsharp mask, optional boost pass when no digit run is found.
/// 3. **Cross-frame accumulation** — PAN (Luhn-valid) and expiry are collected
///    independently across frames; the same PAN must appear twice before lock.
/// 4. **ROI crop** — optional normalized card-frame ROI from the overlay.
class OcrCardScanner implements IOcrScanner {
  /// Minimum gap between OCR invocations (~12–14 fps target).
  static const _throttleInterval = Duration(milliseconds: 70);

  /// Consecutive identical Luhn-valid PANs required before locking.
  /// Luhn already rejects most glare misreads; two matches stay as a light guard.
  static const _panVotesRequired = 2;

  /// Longest side above which NV21 frames are halved before the MethodChannel
  /// hop — cuts transfer + native OCR cost with little accuracy loss on PANs.
  static const _maxNv21LongSide = 960;

  static const _ocrChannel = MethodChannel('fintech_card_core/ocr');

  final _stateCtrl = StreamController<CardReaderState>.broadcast();

  CameraController? _cameraCtrl;
  CameraDescription? _camera;

  bool _isScanning = false;
  bool _isProcessing = false;
  DateTime _lastOcrAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Normalized ROI in camera-image space (0–1), set by the overlay.
  Rect? _scanRoi;

  // ── Cross-frame accumulator ───────────────────────────────────────────────
  String? _lastPan;
  int _panMatchCount = 0;
  String? _lockedPan;
  String? _lockedExpiry;

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

    _resetAccumulator();

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

      final format = Platform.isAndroid
          ? ImageFormatGroup.yuv420
          : ImageFormatGroup.bgra8888;

      // medium (~720p) is enough for embossed PAN digits and keeps the
      // MethodChannel payload / native OCR much cheaper than high/1080p.
      _cameraCtrl = CameraController(
        _camera!,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: format,
      );

      await _cameraCtrl!.initialize();
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
    _resetAccumulator();
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
    if (!_stateCtrl.isClosed) await _stateCtrl.close();
  }

  // ── Image stream ──────────────────────────────────────────────────────────

  void _onCameraImage(CameraImage image) {
    if (!_isScanning || _isProcessing) return;

    final now = DateTime.now();
    if (now.difference(_lastOcrAt) < _throttleInterval) return;

    _isProcessing = true;
    _lastOcrAt = now;
    _processFrame(image).whenComplete(() => _isProcessing = false);
  }

  Future<void> _processFrame(CameraImage image) async {
    try {
      final args = _buildFrameArgs(image);
      if (args == null) return;

      final text = await _ocrChannel.invokeMethod<String>(
        'ocr/recognizeFrame',
        args,
      );

      if (!_isScanning) return;

      final partial = OcrParser.extract(text ?? '');
      if (partial.isEmpty) return;

      _accumulate(partial.pan, partial.expiryDate);
    } catch (_) {
      // Ignore individual frame errors — keep scanning.
    }
  }

  Map<String, dynamic>? _buildFrameArgs(CameraImage image) {
    final rotation = _camera?.sensorOrientation ?? 0;
    final roi = _scanRoi;

    final base = <String, dynamic>{
      'width': image.width,
      'height': image.height,
      'rotation': rotation,
      if (roi != null) ...{
        'roiLeft': roi.left,
        'roiTop': roi.top,
        'roiWidth': roi.width,
        'roiHeight': roi.height,
      },
    };

    if (Platform.isAndroid) {
      final nv21 = _yuv420ToNv21(image);
      if (nv21 == null) return null;
      final scaled = _maybeDownsampleNv21(nv21, image.width, image.height);
      return {
        ...base,
        'width': scaled.width,
        'height': scaled.height,
        'format': 'nv21',
        'bytes': scaled.bytes,
      };
    }

    // iOS BGRA8888 — single plane; optional 2× subsample for large frames.
    if (image.planes.isEmpty) return null;
    final plane = image.planes.first;
    final scaled = _maybeDownsampleBgra(
      plane.bytes,
      image.width,
      image.height,
      plane.bytesPerRow,
    );
    return {
      ...base,
      'width': scaled.width,
      'height': scaled.height,
      'format': 'bgra8888',
      'bytes': scaled.bytes,
      'bytesPerRow': scaled.bytesPerRow,
    };
  }

  ({Uint8List bytes, int width, int height}) _maybeDownsampleNv21(
    Uint8List nv21,
    int width,
    int height,
  ) {
    final longSide = width > height ? width : height;
    if (longSide <= _maxNv21LongSide) {
      return (bytes: nv21, width: width, height: height);
    }

    // Even dimensions required for NV21 chroma.
    final outW = (width ~/ 2) & ~1;
    final outH = (height ~/ 2) & ~1;
    if (outW < 64 || outH < 64) {
      return (bytes: nv21, width: width, height: height);
    }

    final ySize = outW * outH;
    final out = Uint8List(ySize + ySize ~/ 2);

    // Nearest-neighbour Y.
    var oi = 0;
    for (var y = 0; y < outH; y++) {
      final srcRow = (y * 2) * width;
      for (var x = 0; x < outW; x++) {
        out[oi++] = nv21[srcRow + x * 2];
      }
    }

    // Nearest-neighbour NV21 VU (interleaved), one chroma sample per 2×2.
    final srcUvBase = width * height;
    for (var y = 0; y < outH ~/ 2; y++) {
      final srcRow = srcUvBase + (y * 2) * width;
      for (var x = 0; x < outW ~/ 2; x++) {
        final si = srcRow + x * 4;
        out[oi++] = nv21[si]; // V
        out[oi++] = nv21[si + 1]; // U
      }
    }

    return (bytes: out, width: outW, height: outH);
  }

  ({Uint8List bytes, int width, int height, int bytesPerRow}) _maybeDownsampleBgra(
    Uint8List bgra,
    int width,
    int height,
    int bytesPerRow,
  ) {
    final longSide = width > height ? width : height;
    if (longSide <= _maxNv21LongSide) {
      return (
        bytes: bgra,
        width: width,
        height: height,
        bytesPerRow: bytesPerRow,
      );
    }

    final outW = width ~/ 2;
    final outH = height ~/ 2;
    if (outW < 64 || outH < 64) {
      return (
        bytes: bgra,
        width: width,
        height: height,
        bytesPerRow: bytesPerRow,
      );
    }

    final outRow = outW * 4;
    final out = Uint8List(outRow * outH);
    for (var y = 0; y < outH; y++) {
      final srcRow = (y * 2) * bytesPerRow;
      final dstRow = y * outRow;
      for (var x = 0; x < outW; x++) {
        final si = srcRow + x * 8; // skip every other pixel (4 bytes each)
        final di = dstRow + x * 4;
        out[di] = bgra[si];
        out[di + 1] = bgra[si + 1];
        out[di + 2] = bgra[si + 2];
        out[di + 3] = bgra[si + 3];
      }
    }
    return (bytes: out, width: outW, height: outH, bytesPerRow: outRow);
  }

  /// Convert Android YUV_420_888 [CameraImage] planes to a contiguous NV21 buffer.
  Uint8List? _yuv420ToNv21(CameraImage image) {
    if (image.planes.length < 3) return null;

    final width = image.width;
    final height = image.height;
    final yPlane = image.planes[0];
    final uPlane = image.planes[1];
    final vPlane = image.planes[2];

    final ySize = width * height;
    final uvSize = width * height ~/ 2;
    final out = Uint8List(ySize + uvSize);

    // Copy Y, respecting row stride.
    var outIndex = 0;
    final yRowStride = yPlane.bytesPerRow;
    final yBytes = yPlane.bytes;
    for (var row = 0; row < height; row++) {
      final start = row * yRowStride;
      out.setRange(outIndex, outIndex + width, yBytes, start);
      outIndex += width;
    }

    // Interleave V/U for NV21 (VU VU …).
    final uvRowStride = uPlane.bytesPerRow;
    final uvPixelStride = uPlane.bytesPerPixel ?? 1;
    final uBytes = uPlane.bytes;
    final vBytes = vPlane.bytes;
    final uvHeight = height ~/ 2;
    final uvWidth = width ~/ 2;

    for (var row = 0; row < uvHeight; row++) {
      for (var col = 0; col < uvWidth; col++) {
        final uvIndex = row * uvRowStride + col * uvPixelStride;
        out[outIndex++] = vBytes[uvIndex];
        out[outIndex++] = uBytes[uvIndex];
      }
    }

    return out;
  }

  // ── Accumulator ───────────────────────────────────────────────────────────

  void _accumulate(String? pan, String? expiry) {
    if (expiry != null) {
      _lockedExpiry = expiry;
    }

    if (pan != null) {
      if (pan == _lastPan) {
        _panMatchCount++;
      } else {
        _lastPan = pan;
        _panMatchCount = 1;
      }

      if (_panMatchCount >= _panVotesRequired) {
        _lockedPan = pan;
      }
    }

    if (_lockedPan != null && _lockedExpiry != null) {
      _isScanning = false;
      final data = CardData.fromOcr(
        pan: _lockedPan!,
        expiryDate: _lockedExpiry!,
      );
      _emit(CardReaderSuccessState(data));
      // Stop stream asynchronously — do not await inside the frame callback.
      unawaited(_stopStreamOnly());
    }
  }

  Future<void> _stopStreamOnly() async {
    final ctrl = _cameraCtrl;
    if (ctrl != null && ctrl.value.isStreamingImages) {
      try {
        await ctrl.stopImageStream();
      } catch (_) {}
    }
  }

  void _resetAccumulator() {
    _lastPan = null;
    _panMatchCount = 0;
    _lockedPan = null;
    _lockedExpiry = null;
    _lastOcrAt = DateTime.fromMillisecondsSinceEpoch(0);
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
