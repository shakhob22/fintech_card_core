import 'dart:io' show Platform;
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:camera/camera.dart';
import 'package:flutter_paddle_ocr/flutter_paddle_ocr.dart';
import 'package:image/image.dart' as img;

import '../ocr/card_field_extractor.dart';
import 'paddle_model_store.dart';

/// On-device card OCR powered by Paddle Lite (PP-OCRv2 slim via
/// `flutter_paddle_ocr`) + [CardFieldExtractor] post-process.
///
/// Unlike the legacy TFLite CRNN strip model, this engine reads the **full
/// card** (PAN, expiry, name fragments) offline on device.
class PaddleCardOcrEngine {
  static const bool debugDiagnostics = true;

  final PaddleModelStore _store;
  PaddleOcr? _ocr;
  bool _disposed = false;
  bool _busy = false;

  PaddleCardOcrEngine({PaddleModelStore? store})
      : _store = store ?? PaddleModelStore.instance;

  bool get isReady => !_disposed && _ocr != null;

  /// Loads bundled `.nb` models and creates the native Paddle Lite runtime.
  Future<void> load() async {
    if (_disposed) {
      throw StateError('PaddleCardOcrEngine has been disposed.');
    }
    if (isReady) return;

    await _store.ensureReady();
    _ocr = await PaddleOcr.create(
      source: ModelSource.filePaths(
        det: _store.detPath,
        rec: _store.recPath,
        cls: _store.clsPath,
        dict: _store.dictPath,
      ),
    );
  }

  /// Runs OCR on encoded image bytes (JPEG/PNG/WebP).
  Future<CardFields?> recognizeBytes(
    Uint8List bytes, {
    bool runClassification = true,
  }) async {
    if (!isReady || _busy) return null;
    _busy = true;
    try {
      final results = await _ocr!.recognize(
        bytes,
        runClassification: runClassification,
      );
      final boxes = [
        for (final r in results)
          OcrTextBox.fromPoints(
            text: r.text,
            confidence: r.confidence,
            points: [
              for (final p in r.points) [p.dx, p.dy],
            ],
          ),
      ];
      final fields = CardFieldExtractor.extract(boxes);
      if (debugDiagnostics) {
        // ignore: avoid_print
        print(
          'PaddleOCR: pan=${fields.pan} '
          'luhn=${fields.luhnPass} '
          'expiry=${fields.expiryDate} '
          'texts=${boxes.map((b) => b.text).toList()}',
        );
      }
      return fields;
    } finally {
      _busy = false;
    }
  }

  /// Camera frame → JPEG → Paddle → [CardFields].
  ///
  /// Uses the full card [normalizedRoi] when provided (not the digit strip).
  Future<CardFields?> recognizeCameraImage(
    CameraImage image, {
    Rect? normalizedRoi,
    int rotationDegrees = 0,
  }) async {
    if (!isReady || _busy) return null;

    final jpeg = await Isolate.run(
      () => _encodeCameraImageJpeg(
        image: _IsolateCameraImage.from(image),
        rotationDegrees: rotationDegrees,
        roiLeft: normalizedRoi?.left,
        roiTop: normalizedRoi?.top,
        roiWidth: normalizedRoi?.width,
        roiHeight: normalizedRoi?.height,
      ),
    );
    if (jpeg == null) return null;
    return recognizeBytes(jpeg);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _busy = false;
    final ocr = _ocr;
    _ocr = null;
    await ocr?.dispose();
  }
}

/// Isolate-safe camera plane snapshot.
class _IsolateCameraImage {
  final int width;
  final int height;
  final bool isBgra;
  final Uint8List bytes;
  final int bytesPerRow;

  const _IsolateCameraImage({
    required this.width,
    required this.height,
    required this.isBgra,
    required this.bytes,
    required this.bytesPerRow,
  });

  factory _IsolateCameraImage.from(CameraImage image) {
    if (Platform.isAndroid) {
      final y = _extractYPlane(image);
      return _IsolateCameraImage(
        width: image.width,
        height: image.height,
        isBgra: false,
        bytes: y ?? Uint8List(0),
        bytesPerRow: image.width,
      );
    }
    final plane = image.planes.first;
    return _IsolateCameraImage(
      width: image.width,
      height: image.height,
      isBgra: true,
      bytes: Uint8List.fromList(plane.bytes),
      bytesPerRow: plane.bytesPerRow,
    );
  }
}

Uint8List? _extractYPlane(CameraImage image) {
  if (image.planes.isEmpty) return null;
  final yPlane = image.planes.first;
  final width = image.width;
  final height = image.height;
  final rowStride = yPlane.bytesPerRow;
  final src = yPlane.bytes;
  if (rowStride == width && src.length >= width * height) {
    return Uint8List.fromList(src.sublist(0, width * height));
  }
  final out = Uint8List(width * height);
  var di = 0;
  for (var row = 0; row < height; row++) {
    out.setRange(di, di + width, src, row * rowStride);
    di += width;
  }
  return out;
}

/// Top-level isolate entry: camera bytes → JPEG for Paddle Lite.
Uint8List? _encodeCameraImageJpeg({
  required _IsolateCameraImage image,
  required int rotationDegrees,
  double? roiLeft,
  double? roiTop,
  double? roiWidth,
  double? roiHeight,
  int quality = 90,
}) {
  if (image.bytes.isEmpty) return null;

  var raw = img.Image.fromBytes(
    width: image.width,
    height: image.height,
    bytes: image.bytes.buffer,
    bytesOffset: image.bytes.offsetInBytes,
    rowStride: image.bytesPerRow,
    numChannels: image.isBgra ? 4 : 1,
    order: image.isBgra ? img.ChannelOrder.bgra : null,
  );

  final d = ((rotationDegrees % 360) + 360) % 360;
  if (d == 90) {
    raw = img.copyRotate(raw, angle: 90);
  } else if (d == 180) {
    raw = img.copyRotate(raw, angle: 180);
  } else if (d == 270) {
    raw = img.copyRotate(raw, angle: 270);
  }

  if (roiLeft != null &&
      roiTop != null &&
      roiWidth != null &&
      roiHeight != null) {
    // Full-card ROI (overlay frame) — do not narrow to digit strip.
    final left = (roiLeft * raw.width).round().clamp(0, raw.width - 1);
    final top = (roiTop * raw.height).round().clamp(0, raw.height - 1);
    final width = (roiWidth * raw.width).round().clamp(1, raw.width - left);
    final height =
        (roiHeight * raw.height).round().clamp(1, raw.height - top);
    raw = img.copyCrop(raw, x: left, y: top, width: width, height: height);
  }

  // Cap long side for latency while keeping card text readable.
  const maxSide = 1280;
  final longSide = raw.width > raw.height ? raw.width : raw.height;
  if (longSide > maxSide) {
    final scale = maxSide / longSide;
    raw = img.copyResize(
      raw,
      width: (raw.width * scale).round(),
      height: (raw.height * scale).round(),
      interpolation: img.Interpolation.linear,
    );
  }

  return Uint8List.fromList(img.encodeJpg(raw, quality: quality));
}
