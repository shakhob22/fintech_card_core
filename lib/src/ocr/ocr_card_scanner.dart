import 'dart:async';
import 'dart:io' show Platform;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/interfaces/i_ocr_scanner.dart';
import '../core/luhn.dart';
import '../core/models/card_enums.dart';
import '../core/models/card_data.dart';
import '../core/models/card_reader_exception.dart';
import '../core/models/card_reader_state.dart';
import 'engine/card_ocr_backend.dart';
import 'engine/card_ocr_engine_result.dart';
import 'engine/card_scan_card_ocr_backend.dart';
import 'frame_consensus_buffer.dart';
import 'ocr_parser.dart';
import 'ocr_result_accumulator.dart';
import 'pan_heuristics.dart';

/// Camera-based OCR card scanner — CardScan SSD pipeline.
///
/// ```
/// CameraImage
///   → pack NV21/BGRA, downsample ≤960, optional overlay ROI
///   → CardScan SSD OCR (native TFLite / CoreML)
///   → FrameConsensusBuffer + PanHeuristics
///   → length/Luhn gate → OcrResultAccumulator (3 consecutive locks)
/// ```
class OcrCardScanner implements IOcrScanner {
  /// Minimum gap between OCR invocations (~20 fps when inference is fast).
  static const _throttleInterval = Duration(milliseconds: 45);

  /// Longest side above which frames are halved before the MethodChannel hop.
  /// SSD input is 600×375 — 960 is plenty and cuts transfer + preprocess cost.
  static const _maxNv21LongSide = 960;

  /// Expected PAN length for Visa / Mastercard / HUMO / UzCard.
  static const _expectedPanLength = 16;

  static const _msgPointCamera = 'Point camera at the card';
  static const _msgHoldSteady = 'Hold steady…';
  static const _msgAlignNumber = 'Align the card number';
  static const _msgReading = 'Reading card number…';

  OcrCardScanner({CardOcrBackend? backend})
      : _backend = backend ?? CardScanCardOcrBackend();

  final CardOcrBackend _backend;

  final _stateCtrl = StreamController<CardReaderState>.broadcast();
  final _accumulator = OcrResultAccumulator();

  /// Phase 3 — positional voting over the last 5 frame readings.
  final _consensus = FrameConsensusBuffer();

  CameraController? _cameraCtrl;
  CameraDescription? _camera;

  bool _isScanning = false;
  bool _isProcessing = false;
  DateTime _lastOcrAt = DateTime.fromMillisecondsSinceEpoch(0);
  String? _lastScanningMessage;

  /// One-shot diagnostics so Flutter console shows pipeline health on iOS.
  bool _loggedFirstFrame = false;
  bool _loggedFirstResult = false;
  bool _loggedChannelError = false;

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

      // medium (~720p) — SSD model is 600×375; high 1080p only added transfer cost.
      _cameraCtrl = CameraController(
        _camera!,
        ResolutionPreset.medium,
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
      _lastScanningMessage = null;
      _emitScanning(_msgPointCamera);

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
    if (!_loggedFirstFrame) {
      _loggedFirstFrame = true;
      debugPrint(
        '[OcrCardScanner] first camera frame '
        '${image.width}x${image.height} planes=${image.planes.length}',
      );
    }
    _processFrame(image).whenComplete(() => _isProcessing = false);
  }

  /// Full 4-phase pipeline for one camera frame.
  Future<void> _processFrame(CameraImage image) async {
    try {
      final packed = _packCameraFrame(image);
      if (packed == null) {
        debugPrint('[OcrCardScanner] packCameraFrame returned null');
        return;
      }

      final engineResult = await _recognize(packed);
      if (!_loggedFirstResult) {
        _loggedFirstResult = true;
        debugPrint(
          '[OcrCardScanner] first OCR result engine=${engineResult.engine} '
          'pan=${engineResult.pan} conf=${engineResult.confidence} '
          'debug=${engineResult.debug}',
        );
      }
      final text = engineResult.textForParser;
      if (!_isScanning || (!engineResult.hasPan && text.isEmpty)) {
        _maybeCompleteAfterGrace();
        return;
      }

      // Prefer structured PAN from CardScan; also feed text for consensus.
      for (final reading in _extractConsensusReadings(text)) {
        _consensus.add(reading);
      }
      if (engineResult.hasPan) {
        final normalized = PanHeuristics.normalize(engineResult.pan!);
        if (normalized.isNotEmpty) _consensus.add(normalized);
      }

      String? consensusPan;
      final consensus = _consensus.consensus;
      if (consensus != null) {
        consensusPan = PanHeuristics.repair(consensus);
      }
      if (consensusPan != null && !_isAcceptablePan(consensusPan)) {
        consensusPan = null;
      }

      final pans = <String>{
        ...OcrParser.extractAllPans(text),
        if (engineResult.hasPan) ...OcrParser.extractAllPans(engineResult.pan!),
      }.where(_isAcceptablePan).toList();

      var expiry = engineResult.expiryDate ?? OcrParser.extract(text).expiryDate;
      if (expiry != null) {
        expiry = _normalizeExpiry(expiry);
      }

      // Prefer multi-frame consensus; single-frame hits only vote when they
      // agree with consensus (or consensus is not warm yet).
      String? pan;
      if (consensusPan != null) {
        pan = consensusPan;
      } else if (pans.length == 1) {
        pan = pans.first;
      } else if (pans.length > 1) {
        pan = PanHeuristics.chooseUndegraded(pans);
      }
      if (pan == null && engineResult.hasPan) {
        final repaired =
            PanHeuristics.repair(PanHeuristics.normalize(engineResult.pan!));
        if (repaired != null && _isAcceptablePan(repaired)) pan = repaired;
      }
      if (pan != null && !_isAcceptablePan(pan)) pan = null;

      if (pan == null && !_accumulator.hasLockedPan) {
        if (!_consensus.isWarm || consensus == null) {
          _emitScanning(_msgAlignNumber);
        } else {
          _emitScanning(_msgHoldSteady);
        }
      } else if (pan != null && !_accumulator.hasLockedPan) {
        _emitScanning(_msgReading);
      }

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
    } catch (e, st) {
      if (!_loggedChannelError) {
        _loggedChannelError = true;
        debugPrint('[OcrCardScanner] OCR frame error: $e\n$st');
      }
      // Keep scanning unless the plugin channel is missing entirely.
      if (e is MissingPluginException) {
        _emitError(
          CardReaderErrorCode.ocrParsingFailed,
          'OCR plugin not registered on this platform.',
          cause: e,
        );
      }
    }
  }

  /// Length + digit + Luhn gate before accumulator (Visa/MC/HUMO/UzCard = 16).
  static bool _isAcceptablePan(String pan) {
    if (pan.length != _expectedPanLength) return false;
    if (pan.contains('?')) return false;
    return Luhn.validate(pan);
  }

  void _emitScanning(String message) {
    if (!_isScanning) return;
    if (_lastScanningMessage == message) return;
    _lastScanningMessage = message;
    _emit(CardReaderScanningState(
      mode: CardReadMode.ocr,
      message: message,
    ));
  }

  String? _normalizeExpiry(String raw) {
    final digits = raw.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length == 4) {
      final mm = digits.substring(0, 2);
      final yy = digits.substring(2);
      final month = int.tryParse(mm);
      if (month != null && month >= 1 && month <= 12) return '$mm/$yy';
    }
    final m = RegExp(r'(\d{2})\s*/\s*(\d{2})').firstMatch(raw);
    if (m != null) {
      final month = int.tryParse(m.group(1)!);
      if (month != null && month >= 1 && month <= 12) {
        return '${m.group(1)}/${m.group(2)}';
      }
    }
    return null;
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

  /// Phase 1 skipped — CardScan SSD crops ROI itself (600×375).
  Future<CardOcrEngineResult> _recognize(_PackedFrame packed) {
    return _backend.recognizeFrame(packed.toRecognizeArgs());
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
    // Always copy — CameraImage plane bytes are only valid during the stream
    // callback; iOS reuses the buffer as soon as the callback returns.
    final copied = Uint8List.fromList(plane.bytes);
    final scaled = _maybeDownsampleBgra(
      copied,
      image.width,
      image.height,
      plane.bytesPerRow,
    );
    // iOS AVFoundation (via camera plugin) already delivers an upright buffer
    // when height >= width (e.g. 480x640). Re-applying sensorOrientation=90
    // sideways-rotates the frame and CardScan finds no digits.
    final iosRotation =
        (scaled.height >= scaled.width) ? 0 : rotation;
    return _PackedFrame(
      bytes: scaled.bytes,
      width: scaled.width,
      height: scaled.height,
      rotation: iosRotation,
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
    _lastScanningMessage = null;
    _loggedFirstFrame = false;
    _loggedFirstResult = false;
    _loggedChannelError = false;
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
