import 'dart:async';
import 'dart:io' show Directory, File, Platform;
import 'dart:isolate';
import 'dart:ui' show Rect;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

import '../core/luhn.dart';
import '../ocr/ocr_roi.dart';

/// On-device CRNN card-number recognizer backed by `card_ocr.tflite`.
///
/// Pipeline per frame:
/// ```
/// CameraImage
///   → Isolate preprocess (gray, resize 48×320, float32 NCHW)
///   → IsolateInterpreter inference (CTC logits)
///   → Greedy CTC decode → Luhn validate
/// ```
///
/// Heavy work (resize / normalize / TFLite) never blocks the UI isolate.
class CardOcrEngine {
  /// Package-scoped asset key (works for host apps and this plugin).
  ///
  /// Declared in `pubspec.yaml` as `assets/models/card_ocr.tflite`.
  static const modelAssetPath =
      'packages/fintech_card_core/assets/models/card_ocr.tflite';

  /// TEMPORARY diagnostics (tensor logs, RAW OCR print, 320×48 preview).
  ///
  /// Does **not** bypass Luhn — the camera path returns raw CTC text for
  /// multi-frame voting; [OcrCardScanner] applies length-16 + [Luhn] on the
  /// consensus string.
  static const bool debugDiagnostics = true;

  static const inputBatch = 1;
  static const inputChannels = 1;
  static const inputHeight = 48;
  static const inputWidth = 320;

  /// CTC blank index — digit classes are `1…10` → chars `'0'…'9'`.
  static const ctcBlankIndex = 0;

  /// PAN length produced by the CRNN head (16-digit cards).
  static const expectedPanLength = 16;

  Interpreter? _interpreter;
  IsolateInterpreter? _isolateInterpreter;

  List<int> _inputShape = const [
    inputBatch,
    inputChannels,
    inputHeight,
    inputWidth,
  ];
  List<int> _outputShape = const [];

  bool _disposed = false;
  bool _busy = false;
  bool _loggedCtcMapping = false;

  /// Latest model-input preview (grayscale PNG, typically 320×48).
  ///
  /// Updated only when [debugDiagnostics] is `true`.
  final ValueNotifier<Uint8List?> debugPreviewBytes = ValueNotifier(null);

  /// `true` after a successful [load] and before [dispose].
  bool get isReady =>
      !_disposed && _interpreter != null && _isolateInterpreter != null;

  /// Loads the bundled model and wraps inference in an [IsolateInterpreter].
  Future<void> load() async {
    if (_disposed) {
      throw StateError('CardOcrEngine has been disposed.');
    }
    if (isReady) return;

    final interpreter = await Interpreter.fromAsset(modelAssetPath);
    final isolateInterpreter =
        await IsolateInterpreter.create(address: interpreter.address);

    _interpreter = interpreter;
    _isolateInterpreter = isolateInterpreter;
    _inputShape = List<int>.from(interpreter.getInputTensor(0).shape);
    _outputShape = List<int>.from(interpreter.getOutputTensor(0).shape);

    if (debugDiagnostics) {
      _logTensorDiagnostics(interpreter);
      _logCtcMapping();
    }
  }

  void _logTensorDiagnostics(Interpreter interpreter) {
    // ignore: avoid_print
    print('═══ OCR Tensor Diagnostics ═══');
    final inputs = interpreter.getInputTensors();
    for (var i = 0; i < inputs.length; i++) {
      final t = inputs[i];
      // ignore: avoid_print
      print(
        'INPUT[$i] name=${t.name} shape=${t.shape} type=${t.type} '
        '(expected NCHW [1,1,48,320] or NHWC [1,48,320,1])',
      );
    }
    final outputs = interpreter.getOutputTensors();
    for (var i = 0; i < outputs.length; i++) {
      final t = outputs[i];
      // ignore: avoid_print
      print('OUTPUT[$i] name=${t.name} shape=${t.shape} type=${t.type}');
    }
    // ignore: avoid_print
    print(
      'Cached shapes: input=$_inputShape output=$_outputShape '
      '→ height=${_modelHeight(_inputShape)} width=${_modelWidth(_inputShape)}',
    );
  }

  void _logCtcMapping() {
    if (_loggedCtcMapping) return;
    _loggedCtcMapping = true;
    final digitMap = List.generate(
      10,
      (i) => 'class ${i + 1} → \'$i\'',
    ).join(', ');
    // ignore: avoid_print
    print(
      '═══ CTC Greedy Decoder Mapping ═══\n'
      'blankIndex = $ctcBlankIndex (must be 0)\n'
      'digit classes: $digitMap\n'
      'formula: digit = classIndex - 1  (class 1→\'0\' … class 10→\'9\')',
    );
  }

  /// Recognizes digits from a live [CameraImage] (raw CTC, no Luhn gate).
  ///
  /// Returns `null` when the frame is rejected or another inference is
  /// already in flight (camera streams must not pile up work).
  ///
  /// [normalizedRoi] should be the PAN digit strip. A full-card frame ROI is
  /// automatically narrowed via [OcrRoi.digitStripRoi].
  ///
  /// Callers (e.g. [OcrCardScanner]) must run multi-frame consensus then
  /// enforce length-16 + Luhn before accepting a PAN.
  Future<String?> recognizeCameraImage(
    CameraImage image, {
    Rect? normalizedRoi,
    int rotationDegrees = 0,
  }) async {
    if (!isReady || _busy) return null;
    _busy = true;
    try {
      final packed = _packCameraImage(image);
      if (packed == null) return null;

      // Prefer a digits-only strip; never squash a full ISO card into 320×48.
      final roi = normalizedRoi == null
          ? null
          : OcrRoi.digitStripRoi(normalizedRoi);

      final shape = List<int>.from(_inputShape);
      final prep = await Isolate.run(
        () => preprocessFrame(
          bytes: packed.bytes,
          width: packed.width,
          height: packed.height,
          bytesPerRow: packed.bytesPerRow,
          isBgra: packed.isBgra,
          rotationDegrees: rotationDegrees,
          roiLeft: roi?.left,
          roiTop: roi?.top,
          roiWidth: roi?.width,
          roiHeight: roi?.height,
          inputShape: shape,
          emitDebugPreview: debugDiagnostics,
        ),
      );

      if (debugDiagnostics) {
        final aspect = (roi == null || roi.height == 0)
            ? null
            : roi.width / roi.height;
        // ignore: avoid_print
        print(
          'OCR preprocess: rotation=$rotationDegrees° '
          'camera=${packed.width}x${packed.height} '
          'modelInput=${prep.previewWidth}x${prep.previewHeight} '
          'roi=$roi aspect=${aspect?.toStringAsFixed(2)} '
          'height=${roi?.height} (card-relative band '
          '${OcrRoi.panBandLtrb})',
        );
        _publishDebugPreview(prep);
      }

      final output = allocateOutputBuffer(_outputShape);
      await _isolateInterpreter!.run(prep.input, output);

      // Raw CTC for temporal voting — Luhn is applied after consensus.
      return decodeRaw(output, _outputShape);
    } finally {
      _busy = false;
    }
  }

  void _publishDebugPreview(OcrPreprocessResult prep) {
    final png = prep.debugPreviewPng;
    if (png == null) return;

    debugPreviewBytes.value = png;

    try {
      final path = '${Directory.systemTemp.path}/ocr_debug_model_input.png';
      File(path).writeAsBytesSync(png);
      // ignore: avoid_print
      print(
        'OCR debug preview saved: $path '
        '(${prep.previewWidth}x${prep.previewHeight}, '
        'check if card digits are horizontal)',
      );
    } catch (e) {
      // ignore: avoid_print
      print('OCR debug preview file write failed: $e');
    }
  }

  /// Runs recognition on a pre-built model input tensor (tests / offline).
  Future<String?> recognizeTensor(Object input) async {
    if (!isReady) {
      throw StateError('Call load() before recognizeTensor().');
    }
    final output = allocateOutputBuffer(_outputShape);
    await _isolateInterpreter!.run(input, output);
    return decodeAndValidate(output, _outputShape);
  }

  /// CTC greedy decode only (no length / Luhn). Used for multi-frame voting.
  static String? decodeRaw(Object output, List<int> outputShape) {
    final layout = CtcLayout.fromShape(outputShape);
    if (layout == null) {
      if (debugDiagnostics) {
        // ignore: avoid_print
        print('RAW OCR RESULT:  (layout null for shape=$outputShape)');
      }
      return null;
    }

    final logits = flattenToTc(output, layout);
    final pan = greedyCtcDecode(
      logits,
      timeSteps: layout.timeSteps,
      numClasses: layout.numClasses,
    );

    final rawText = pan ?? '';
    // ignore: avoid_print
    print('RAW OCR RESULT: $rawText');

    if (debugDiagnostics) {
      // ignore: avoid_print
      print(
        'OCR decode debug: layout T=${layout.timeSteps} C=${layout.numClasses} '
        'channelsFirst=${layout.channelsFirst} len=${rawText.length}',
      );
    }

    return rawText.isEmpty ? null : rawText;
  }

  /// CTC greedy decode + strict length-16 + Luhn gate.
  static String? decodeAndValidate(Object output, List<int> outputShape) {
    final pan = decodeRaw(output, outputShape);
    if (pan == null || pan.length != expectedPanLength) return null;
    if (!Luhn.validate(pan)) return null;
    return pan;
  }

  /// Greedy CTC: argmax → collapse repeats → drop blank → digit chars.
  static String? greedyCtcDecode(
    Float32List logits, {
    required int timeSteps,
    required int numClasses,
    int blankIndex = ctcBlankIndex,
  }) {
    if (timeSteps <= 0 || numClasses <= 0) return null;
    if (logits.length < timeSteps * numClasses) return null;

    // Sanity: blank must be 0; digits occupy 1…10.
    assert(blankIndex == 0, 'CTC blank index must be 0, got $blankIndex');

    final chars = StringBuffer();
    var prev = -1;
    for (var t = 0; t < timeSteps; t++) {
      var bestIdx = 0;
      var bestVal = logits[t * numClasses];
      for (var c = 1; c < numClasses; c++) {
        final v = logits[t * numClasses + c];
        if (v > bestVal) {
          bestVal = v;
          bestIdx = c;
        }
      }
      if (bestIdx != blankIndex && bestIdx != prev) {
        // class 1 → '0' … class 10 → '9'
        final digit = bestIdx - 1;
        if (digit < 0 || digit > 9) return null;
        chars.writeCharCode(0x30 + digit);
      }
      prev = bestIdx;
    }
    final result = chars.toString();
    return result.isEmpty ? null : result;
  }

  /// Releases interpreter + isolate resources.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _busy = false;
    final isolate = _isolateInterpreter;
    final interpreter = _interpreter;
    _isolateInterpreter = null;
    _interpreter = null;
    debugPreviewBytes.value = null;
    debugPreviewBytes.dispose();
    await isolate?.close();
    interpreter?.close();
  }

  // ── Camera packing ─────────────────────────────────────────────────────────

  _PackedImage? _packCameraImage(CameraImage image) {
    if (Platform.isAndroid) {
      final y = extractYPlane(image);
      if (y == null) return null;
      return _PackedImage(
        bytes: y,
        width: image.width,
        height: image.height,
        bytesPerRow: image.width,
        isBgra: false,
      );
    }

    if (image.planes.isEmpty) return null;
    final plane = image.planes.first;
    return _PackedImage(
      bytes: Uint8List.fromList(plane.bytes),
      width: image.width,
      height: image.height,
      bytesPerRow: plane.bytesPerRow,
      isBgra: true,
    );
  }

  /// Contiguous luminance plane from Android YUV_420_888.
  static Uint8List? extractYPlane(CameraImage image) {
    if (image.planes.isEmpty) return null;
    final yPlane = image.planes.first;
    final width = image.width;
    final height = image.height;
    final rowStride = yPlane.bytesPerRow;
    final src = yPlane.bytes;

    if (rowStride == width) {
      final needed = width * height;
      if (src.length >= needed) {
        return Uint8List.fromList(src.sublist(0, needed));
      }
    }

    final out = Uint8List(width * height);
    var di = 0;
    for (var row = 0; row < height; row++) {
      final start = row * rowStride;
      out.setRange(di, di + width, src, start);
      di += width;
    }
    return out;
  }

  /// Nested float list matching [shape], filled by `Tensor.copyTo`.
  static Object allocateOutputBuffer(List<int> shape) {
    Object build(List<int> dims) {
      if (dims.length == 1) {
        return List<double>.filled(dims[0], 0.0);
      }
      return List.generate(dims[0], (_) => build(dims.sublist(1)));
    }

    return build(shape);
  }
}

/// Describes how CTC logits are laid out in the model output tensor.
class CtcLayout {
  final int timeSteps;
  final int numClasses;

  /// When `true`, flattened storage is `[C, T]` and must be transposed to
  /// `[T, C]` before greedy decode.
  final bool channelsFirst;

  const CtcLayout({
    required this.timeSteps,
    required this.numClasses,
    required this.channelsFirst,
  });

  /// Infers `[T, C]` vs `[C, T]` from the two non-batch dims.
  ///
  /// Digit alphabet + blank ≈ 11 classes, so the smaller dim is treated as C.
  static CtcLayout? fromShape(List<int> shape) {
    if (shape.isEmpty) return null;

    // Drop leading batch dimension when present.
    final effective = shape.length >= 2 && shape.first == 1
        ? shape.sublist(1)
        : List<int>.from(shape);

    if (effective.length < 2) return null;

    final a = effective[effective.length - 2];
    final b = effective.last;
    if (a <= 0 || b <= 0) return null;

    // Smaller dim ≈ class count (blank + 10 digits ≈ 11).
    if (a <= b) {
      return CtcLayout(
        timeSteps: b,
        numClasses: a,
        channelsFirst: true, // [C, T]
      );
    }
    return CtcLayout(
      timeSteps: a,
      numClasses: b,
      channelsFirst: false, // [T, C]
    );
  }
}

/// Flattens nested TFLite output into row-major `[T, C]` floats.
Float32List flattenToTc(Object output, CtcLayout layout) {
  final flat = <double>[];
  void walk(Object node) {
    if (node is List) {
      for (final child in node) {
        walk(child);
      }
    } else if (node is num) {
      flat.add(node.toDouble());
    }
  }

  walk(output);

  final t = layout.timeSteps;
  final c = layout.numClasses;
  final out = Float32List(t * c);

  if (!layout.channelsFirst) {
    // Already […, T, C]
    final n = flat.length < out.length ? flat.length : out.length;
    for (var i = 0; i < n; i++) {
      out[i] = flat[i];
    }
    return out;
  }

  // Transpose [C, T] → [T, C]
  for (var ti = 0; ti < t; ti++) {
    for (var ci = 0; ci < c; ci++) {
      final src = ci * t + ti;
      if (src < flat.length) {
        out[ti * c + ci] = flat[src];
      }
    }
  }
  return out;
}

// ── Isolate preprocessing (top-level for Isolate.run) ────────────────────────

class _PackedImage {
  final Uint8List bytes;
  final int width;
  final int height;
  final int bytesPerRow;
  final bool isBgra;

  const _PackedImage({
    required this.bytes,
    required this.width,
    required this.height,
    required this.bytesPerRow,
    required this.isBgra,
  });
}

/// Result of [preprocessFrame] (isolate-safe).
class OcrPreprocessResult {
  /// Nested float tensor matching the model input shape.
  final Object input;

  /// Grayscale PNG of the exact image fed to the model (when requested).
  final Uint8List? debugPreviewPng;

  final int previewWidth;
  final int previewHeight;

  const OcrPreprocessResult({
    required this.input,
    this.debugPreviewPng,
    this.previewWidth = 0,
    this.previewHeight = 0,
  });
}

/// Top-level isolate entry: camera bytes → NCHW float32 model input.
OcrPreprocessResult preprocessFrame({
  required Uint8List bytes,
  required int width,
  required int height,
  required int bytesPerRow,
  required bool isBgra,
  required int rotationDegrees,
  required double? roiLeft,
  required double? roiTop,
  required double? roiWidth,
  required double? roiHeight,
  required List<int> inputShape,
  bool emitDebugPreview = false,
}) {
  final raw = img.Image.fromBytes(
    width: width,
    height: height,
    bytes: bytes.buffer,
    bytesOffset: bytes.offsetInBytes,
    rowStride: bytesPerRow,
    numChannels: isBgra ? 4 : 1,
    order: isBgra ? img.ChannelOrder.bgra : null,
  );

  final rotated = _rotate(raw, rotationDegrees);
  final cropped = _cropRoi(
    rotated,
    roiLeft: roiLeft,
    roiTop: roiTop,
    roiWidth: roiWidth,
    roiHeight: roiHeight,
  );

  final h = _modelHeight(inputShape);
  final w = _modelWidth(inputShape);

  final resized = img.copyResize(
    cropped,
    width: w,
    height: h,
    interpolation: img.Interpolation.linear,
  );

  final gray =
      resized.numChannels == 1 ? resized : img.grayscale(resized);

  Uint8List? previewPng;
  if (emitDebugPreview) {
    previewPng = Uint8List.fromList(img.encodePng(gray));
  }

  return OcrPreprocessResult(
    input: _toInputTensor(gray, inputShape),
    debugPreviewPng: previewPng,
    previewWidth: gray.width,
    previewHeight: gray.height,
  );
}

int _modelHeight(List<int> shape) {
  // NCHW [1,1,H,W] or NHWC [1,H,W,1]
  if (shape.length == 4) {
    if (shape[1] == 1 && shape[3] != 1) return shape[2]; // NCHW
    return shape[1]; // NHWC
  }
  return CardOcrEngine.inputHeight;
}

int _modelWidth(List<int> shape) {
  if (shape.length == 4) {
    if (shape[1] == 1 && shape[3] != 1) return shape[3]; // NCHW
    return shape[2]; // NHWC
  }
  return CardOcrEngine.inputWidth;
}

img.Image _rotate(img.Image src, int degrees) {
  final d = ((degrees % 360) + 360) % 360;
  if (d == 0) return src;
  if (d == 90) return img.copyRotate(src, angle: 90);
  if (d == 180) return img.copyRotate(src, angle: 180);
  if (d == 270) return img.copyRotate(src, angle: 270);
  return src;
}

img.Image _cropRoi(
  img.Image src, {
  required double? roiLeft,
  required double? roiTop,
  required double? roiWidth,
  required double? roiHeight,
}) {
  if (roiLeft == null ||
      roiTop == null ||
      roiWidth == null ||
      roiHeight == null) {
    return src;
  }
  final left = (roiLeft * src.width).round().clamp(0, src.width - 1);
  final top = (roiTop * src.height).round().clamp(0, src.height - 1);
  final width = (roiWidth * src.width).round().clamp(1, src.width - left);
  final height =
      (roiHeight * src.height).round().clamp(1, src.height - top);
  return img.copyCrop(src, x: left, y: top, width: width, height: height);
}

/// Builds nested floats matching [inputShape], values in `[0.0, 1.0]`.
Object _toInputTensor(img.Image gray, List<int> inputShape) {
  final h = gray.height;
  final w = gray.width;
  final flat = Float32List(h * w);
  var i = 0;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      flat[i++] = gray.getPixel(x, y).r / 255.0;
    }
  }

  // NCHW: [1, 1, H, W]
  if (inputShape.length == 4 && inputShape[1] == 1 && inputShape.last != 1) {
    return [
      [
        List.generate(
          h,
          (y) => List.generate(w, (x) => flat[y * w + x]),
        ),
      ],
    ];
  }

  // NHWC: [1, H, W, 1]
  if (inputShape.length == 4 && inputShape.last == 1) {
    return [
      List.generate(
        h,
        (y) => List.generate(w, (x) => [flat[y * w + x]]),
      ),
    ];
  }

  return [List<double>.from(flat)];
}
