import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/services.dart';

import '../core/interfaces/i_ocr_scanner.dart';
import '../core/models/card_enums.dart';
import '../core/models/card_data.dart';
import '../core/models/card_reader_exception.dart';
import '../core/models/card_reader_state.dart';
import 'frame_consensus_buffer.dart';
import 'native_preprocessor.dart';
import 'ocr_parser.dart';
import 'ocr_result_accumulator.dart';
import 'pan_heuristics.dart';

/// Camera-based OCR card scanner — 4-phase pipeline.
///
/// ```
/// CameraImage
///   → Phase 1: OpenCV FFI (warp + CLAHE + PAN band) when available
///   → Phase 2: Native OCR (ML Kit / Vision), digits post-filtered in Dart
///   → Phase 3: FrameConsensusBuffer (positional vote, last 5 frames)
///   → Phase 4: PanHeuristics (letter swap → BIN fill → Luhn repair)
///   → OcrResultAccumulator (2 consecutive locks → success)
/// ```
///
/// When OpenCV is a stub / unavailable, Phase 1 is skipped and the platform
/// multi-pass preprocessor inside `ocr/recognizeFrame` is used instead.
class OcrCardScanner implements IOcrScanner {
  /// Minimum gap between OCR invocations (~12–14 fps target).
  static const _throttleInterval = Duration(milliseconds: 70);

  /// Longest side above which frames are halved before the MethodChannel hop.
  static const _maxNv21LongSide = 1600;

  /// OpenCV mode: CLAHE contrast + central-lower PAN band crop.
  static const _opencvMode = CardCvMode.clahe | CardCvMode.panBand;

  static const _ocrChannel = MethodChannel('fintech_card_core/ocr');

  final _stateCtrl = StreamController<CardReaderState>.broadcast();
  final _accumulator = OcrResultAccumulator();

  /// Phase 3 — positional voting over the last 5 frame readings.
  final _consensus = FrameConsensusBuffer();

  /// Phase 1 — OpenCV warp + CLAHE worker (null / unavailable → fall back to
  /// the platform's ML Kit / Vision multi-pass preprocessing).
  FramePreprocessor? _preprocessor;

  CameraController? _cameraCtrl;
  CameraDescription? _camera;

  bool _isScanning = false;
  bool _isProcessing = false;
  DateTime _lastOcrAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Full-card normalized ROI from the overlay (0–1).
  Rect? _scanRoi;

  Timer? _expiryGraceTimer;

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

    // Spawn the OpenCV FFI worker once; a stub / missing library simply
    // reports unavailable and the platform preprocessing path is used.
    if (_preprocessor == null) {
      try {
        _preprocessor = await FramePreprocessor.spawn();
      } catch (_) {
        _preprocessor = null;
      }
    }

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

      // high (~1080p) — hard cards need pixel density; Dart downsamples to 1600.
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
    _preprocessor?.dispose();
    _preprocessor = null;
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

  /// Full 4-phase pipeline for one camera frame.
  Future<void> _processFrame(CameraImage image) async {
    try {
      final packed = _packCameraFrame(image);
      if (packed == null) return;

      final text = await _recognizeText(packed);
      if (!_isScanning || text.isEmpty) {
        _maybeCompleteAfterGrace();
        return;
      }

      // Phase 3 — every distinct reading votes. The native layer may return
      // several preprocessing passes joined with ' ; ', so conflicting
      // readings of the same card vote against each other positionally.
      for (final reading in _extractConsensusReadings(text)) {
        _consensus.add(reading);
      }
      String? consensusPan;
      final consensus = _consensus.consensus;
      if (consensus != null) {
        // Phase 4 — BIN fill + Luhn repair of the voted string.
        consensusPan = PanHeuristics.repair(consensus);
      }

      // Fast path: all Luhn-valid readings in this frame's text.
      final pans = OcrParser.extractAllPans(text);
      final expiry = OcrParser.extract(text).expiryDate;

      String? pan;
      if (pans.length == 1) {
        pan = pans.first;
      } else if (pans.length > 1) {
        // Conflicting Luhn-valid readings — a systematic emboss misread
        // (7→1, 6→5, 4→1) can itself pass Luhn, so the checksum cannot
        // arbitrate. Prefer the reading whose digits the rivals look like
        // stroke-lost copies of; otherwise wait for more frames.
        pan = PanHeuristics.chooseUndegraded(pans) ??
            (consensusPan != null && pans.contains(consensusPan)
                ? consensusPan
                : null);
      }
      pan ??= consensusPan;

      if (pan == null && expiry == null) {
        _maybeCompleteAfterGrace();
        return;
      }

      final hadPan = _accumulator.hasLockedPan;
      final data = _accumulator.accumulate(pan, expiry);
      if (!hadPan && _accumulator.hasLockedPan) {
        _armExpiryGraceTimer();
      }
      if (data != null) {
        _emitSuccess(data);
      }
    } catch (_) {
      // Ignore individual frame errors — keep scanning.
    }
  }

  /// All distinct 16-char `[0-9?]` readings for the consensus buffer.
  ///
  /// Falls back to 15/14-char runs realigned through
  /// [PanHeuristics.realignDroppedPrefix] — a faded HUMO leading `9` makes
  /// OCR drop it and shift every digit one position left, which would
  /// otherwise poison positional voting.
  List<String> _extractConsensusReadings(String text) {
    final full = OcrParser.extractRawCandidates(text);
    if (full.isNotEmpty) return full;

    for (final len in const [15, 14]) {
      final shorts = OcrParser.extractRawCandidates(text, expectedLength: len);
      final realigned = <String>[];
      for (final short in shorts) {
        final fixed = PanHeuristics.realignDroppedPrefix(short);
        if (fixed != null && !realigned.contains(fixed)) realigned.add(fixed);
      }
      if (realigned.isNotEmpty) return realigned;
    }
    return const [];
  }

  /// Phase 1 (optional OpenCV) → Phase 2 (native OCR).
  Future<String> _recognizeText(_PackedFrame packed) async {
    final pre = _preprocessor;
    if (pre != null && pre.isAvailable) {
      try {
        final processed = await pre.process(
          bytes: packed.bytes,
          format: packed.preprocessFormat,
          width: packed.width,
          height: packed.height,
          bytesPerRow: packed.bytesPerRow,
          rotation: packed.rotation,
          mode: _opencvMode,
        );
        if (processed != null) {
          final warped = await _ocrChannel.invokeMethod<String>(
            'ocr/recognizeGray8',
            {
              'width': processed.width,
              'height': processed.height,
              'bytes': processed.bytes,
            },
          );
          // Usable warped result → skip the heavier full-frame multi-pass.
          if (warped != null &&
              warped.isNotEmpty &&
              (OcrParser.extract(warped).pan != null ||
                  OcrParser.extractRawCandidate(warped) != null)) {
            return warped;
          }
        }
      } catch (_) {
        // Fall through to platform path.
      }
    }

    // Platform multi-pass (Kotlin CLAHE / Swift Vision filters).
    return await _ocrChannel.invokeMethod<String>(
          'ocr/recognizeFrame',
          packed.toRecognizeArgs(),
        ) ??
        '';
  }

  void _armExpiryGraceTimer() {
    _expiryGraceTimer?.cancel();
    _expiryGraceTimer = Timer(OcrResultAccumulator.expiryGrace, () {
      if (!_isScanning) return;
      final data = _accumulator.completeIfReady();
      if (data != null) _emitSuccess(data);
    });
  }

  void _maybeCompleteAfterGrace() {
    final data = _accumulator.completeIfReady();
    if (data != null) _emitSuccess(data);
  }

  void _emitSuccess(CardData data) {
    if (!_isScanning) return;
    _isScanning = false;
    _expiryGraceTimer?.cancel();
    _expiryGraceTimer = null;
    _emit(CardReaderSuccessState(data));
    unawaited(_stopStreamOnly());
  }

  // ── Frame packing (CameraImage → MethodChannel / FFI) ─────────────────────

  /// Converts a [CameraImage] once for both OpenCV and platform OCR.
  _PackedFrame? _packCameraFrame(CameraImage image) {
    final rotation = _camera?.sensorOrientation ?? 0;
    final roi = _scanRoi;

    if (Platform.isAndroid) {
      final nv21 = _yuv420ToNv21(image);
      if (nv21 == null) return null;
      final scaled = _maybeDownsampleNv21(nv21, image.width, image.height);
      return _PackedFrame(
        bytes: scaled.bytes,
        width: scaled.width,
        height: scaled.height,
        rotation: rotation,
        format: 'nv21',
        // NV21 Y plane prefix is luminance — OpenCV reads width×height bytes.
        preprocessFormat: 'gray8',
        bytesPerRow: scaled.width,
        roi: roi,
      );
    }

    if (image.planes.isEmpty) return null;
    final plane = image.planes.first;
    final scaled = _maybeDownsampleBgra(
      plane.bytes,
      image.width,
      image.height,
      plane.bytesPerRow,
    );
    return _PackedFrame(
      bytes: scaled.bytes,
      width: scaled.width,
      height: scaled.height,
      rotation: rotation,
      format: 'bgra8888',
      preprocessFormat: 'bgra8888',
      bytesPerRow: scaled.bytesPerRow,
      roi: roi,
    );
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

  Future<void> _stopStreamOnly() async {
    final ctrl = _cameraCtrl;
    if (ctrl != null && ctrl.value.isStreamingImages) {
      try {
        await ctrl.stopImageStream();
      } catch (_) {}
    }
  }

  void _resetAccumulator() {
    _expiryGraceTimer?.cancel();
    _expiryGraceTimer = null;
    _accumulator.reset();
    _consensus.clear();
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

/// Packed camera frame shared by OpenCV FFI and the OCR MethodChannel.
class _PackedFrame {
  final Uint8List bytes;
  final int width;
  final int height;
  final int rotation;
  final String format;
  final String preprocessFormat;
  final int bytesPerRow;
  final Rect? roi;

  const _PackedFrame({
    required this.bytes,
    required this.width,
    required this.height,
    required this.rotation,
    required this.format,
    required this.preprocessFormat,
    required this.bytesPerRow,
    required this.roi,
  });

  Map<String, dynamic> toRecognizeArgs() => {
        'width': width,
        'height': height,
        'rotation': rotation,
        'format': format,
        'bytes': bytes,
        if (format == 'bgra8888') 'bytesPerRow': bytesPerRow,
        if (roi != null) ...{
          'roiLeft': roi!.left,
          'roiTop': roi!.top,
          'roiWidth': roi!.width,
          'roiHeight': roi!.height,
        },
      };
}
