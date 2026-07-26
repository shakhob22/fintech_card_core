/// Phase 1 — Native frame pre-processing (OpenCV C++ via dart:ffi).
///
/// Wraps the `cardcv` native library (src/cardcv.cpp):
///   perspective correction (Canny → contours → aspect filter → warp) →
///   CLAHE glare/contrast normalisation → optional adaptive threshold →
///   optional PAN-band ROI crop.
///
/// All native calls run on a **long-lived worker isolate** so neither the
/// YUV→gray conversion nor OpenCV ever blocks the UI thread. Frame bytes are
/// moved between isolates with [TransferableTypedData] (zero-copy transfer).
///
/// The library has a stub flavour (built when the OpenCV SDK is absent);
/// [FramePreprocessor.spawn] detects it and reports [isAvailable] = false so
/// the caller can fall back to the platform ML Kit / Vision multi-pass path.
library;

import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io' show Platform;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart' as pkg_ffi;

// ── FFI surface (mirrors src/cardcv.h) ───────────────────────────────────────

/// Warped card canvas width (must match CARDCV_OUT_W).
const int cardCvOutWidth = 1024;

/// Warped card canvas height — 1024/646 ≈ 1.586, the ISO/IEC 7810 ID-1 ratio.
const int cardCvOutHeight = 646;

/// Processing mode bitmask (mirrors CARDCV_MODE_*).
abstract final class CardCvMode {
  static const clahe = 1;
  static const threshold = 2;
  static const panBand = 4;
}

final class _CardCvResultStruct extends ffi.Struct {
  @ffi.Int32()
  external int foundCard;
  @ffi.Int32()
  external int outWidth;
  @ffi.Int32()
  external int outHeight;
  @ffi.Array(8)
  external ffi.Array<ffi.Float> quad;
}

typedef _AvailableNative = ffi.Int32 Function();
typedef _ProcessNative = ffi.Int32 Function(
  ffi.Pointer<ffi.Uint8> gray,
  ffi.Int32 width,
  ffi.Int32 height,
  ffi.Int32 stride,
  ffi.Int32 rotationDegrees,
  ffi.Int32 mode,
  ffi.Pointer<ffi.Uint8> outBuf,
  ffi.Int32 outCap,
  ffi.Pointer<_CardCvResultStruct> result,
);
typedef _ProcessDart = int Function(
  ffi.Pointer<ffi.Uint8>,
  int,
  int,
  int,
  int,
  int,
  ffi.Pointer<ffi.Uint8>,
  int,
  ffi.Pointer<_CardCvResultStruct>,
);

class _CardCvBindings {
  final int Function() available;
  final _ProcessDart process;

  _CardCvBindings._(this.available, this.process);

  /// Loads libcardcv.so (Android) or resolves the statically linked symbols
  /// from the app binary (iOS). Throws when the library / symbols are missing.
  factory _CardCvBindings.open() {
    final lib = Platform.isAndroid
        ? ffi.DynamicLibrary.open('libcardcv.so')
        : ffi.DynamicLibrary.process();
    return _CardCvBindings._(
      lib.lookupFunction<_AvailableNative, int Function()>('cardcv_available'),
      lib.lookupFunction<_ProcessNative, _ProcessDart>('cardcv_process_frame'),
    );
  }
}

// ── Public result ────────────────────────────────────────────────────────────

/// A perspective-corrected, contrast-normalised card image (8-bit grayscale).
class PreprocessedFrame {
  /// Tightly packed gray8 rows, [width] × [height].
  final Uint8List bytes;
  final int width;
  final int height;

  /// Detected card corners (TL, TR, BR, BL as x,y pairs) in upright source
  /// frame coordinates — usable for a debug overlay.
  final Float32List quad;

  const PreprocessedFrame({
    required this.bytes,
    required this.width,
    required this.height,
    required this.quad,
  });
}

// ── Isolate protocol ─────────────────────────────────────────────────────────

class _Request {
  final int id;
  final TransferableTypedData bytes;
  final String format; // 'gray8' | 'bgra8888'
  final int width;
  final int height;
  final int bytesPerRow; // for bgra8888
  final int rotation;
  final int mode;

  _Request({
    required this.id,
    required this.bytes,
    required this.format,
    required this.width,
    required this.height,
    required this.bytesPerRow,
    required this.rotation,
    required this.mode,
  });
}

class _Response {
  final int id;
  final bool found;
  final TransferableTypedData? bytes;
  final int width;
  final int height;
  final Float32List quad;

  _Response(this.id, this.found, this.bytes, this.width, this.height, this.quad);
}

// ── Worker isolate entry point ───────────────────────────────────────────────

void _workerMain(SendPort mainPort) {
  _CardCvBindings? bindings;
  try {
    bindings = _CardCvBindings.open();
    if (bindings.available() == 0) bindings = null; // stub build
  } catch (_) {
    bindings = null; // library not built / not linked
  }

  final receivePort = ReceivePort();
  // Handshake: report capability + our command port.
  mainPort.send([receivePort.sendPort, bindings != null]);

  if (bindings == null) {
    receivePort.listen((message) {
      if (message == null) receivePort.close();
    });
    return;
  }

  // Persistent native buffers — grown lazily, freed on shutdown.
  ffi.Pointer<ffi.Uint8> inBuf = ffi.nullptr;
  var inCap = 0;
  final outCap = cardCvOutWidth * cardCvOutHeight;
  final outBuf = pkg_ffi.malloc.allocate<ffi.Uint8>(outCap);
  final result = pkg_ffi.malloc.allocate<_CardCvResultStruct>(
    ffi.sizeOf<_CardCvResultStruct>(),
  );
  final process = bindings.process;

  void shutdown() {
    if (inBuf != ffi.nullptr) pkg_ffi.malloc.free(inBuf);
    pkg_ffi.malloc.free(outBuf);
    pkg_ffi.malloc.free(result);
    receivePort.close();
  }

  receivePort.listen((message) {
    if (message == null) {
      shutdown();
      return;
    }
    final req = message as _Request;

    final raw = req.bytes.materialize().asUint8List();

    // Reduce to a tightly packed luminance plane.
    Uint8List gray;
    if (req.format == 'bgra8888') {
      gray = _bgraToGray(raw, req.width, req.height, req.bytesPerRow);
    } else {
      // gray8 / NV21 Y-plane prefix: first width*height bytes are luminance.
      gray = raw;
    }

    final needed = req.width * req.height;
    if (inCap < needed) {
      if (inBuf != ffi.nullptr) pkg_ffi.malloc.free(inBuf);
      inBuf = pkg_ffi.malloc.allocate<ffi.Uint8>(needed);
      inCap = needed;
    }
    inBuf.asTypedList(needed).setRange(0, needed, gray);

    final code = process(
      inBuf,
      req.width,
      req.height,
      req.width, // tightly packed
      req.rotation,
      req.mode,
      outBuf,
      outCap,
      result,
    );

    if (code != 0 || result.ref.foundCard == 0) {
      mainPort.send(_Response(req.id, false, null, 0, 0, Float32List(8)));
      return;
    }

    final w = result.ref.outWidth;
    final h = result.ref.outHeight;
    final out = Uint8List.fromList(outBuf.asTypedList(w * h));
    final quad = Float32List(8);
    for (var i = 0; i < 8; i++) {
      quad[i] = result.ref.quad[i];
    }
    mainPort.send(
      _Response(req.id, true, TransferableTypedData.fromList([out]), w, h, quad),
    );
  });
}

/// BT.601 integer luma from BGRA rows (respecting row stride).
Uint8List _bgraToGray(Uint8List bgra, int width, int height, int bytesPerRow) {
  final out = Uint8List(width * height);
  var oi = 0;
  for (var y = 0; y < height; y++) {
    var si = y * bytesPerRow;
    for (var x = 0; x < width; x++) {
      final b = bgra[si];
      final g = bgra[si + 1];
      final r = bgra[si + 2];
      out[oi++] = (r * 77 + g * 150 + b * 29) >> 8;
      si += 4;
    }
  }
  return out;
}

// ── Public API ───────────────────────────────────────────────────────────────

/// Owns the pre-processing worker isolate and serialises frame requests.
class FramePreprocessor {
  final Isolate _isolate;
  final SendPort _commands;
  final ReceivePort _responses;
  final bool _available;

  final _pending = <int, Completer<_Response>>{};
  var _nextId = 0;
  var _disposed = false;

  FramePreprocessor._(
    this._isolate,
    this._commands,
    this._responses,
    this._available,
  ) {
    _responses.listen((message) {
      if (message is _Response) {
        _pending.remove(message.id)?.complete(message);
      }
    });
  }

  /// Spawns the worker and probes cardcv availability. Never throws — when
  /// the native library is a stub or missing, [isAvailable] is simply false.
  static Future<FramePreprocessor> spawn() async {
    final handshake = ReceivePort();
    late final Isolate isolate;
    try {
      isolate = await Isolate.spawn(
        _workerMain,
        handshake.sendPort,
        debugName: 'cardcv-preprocessor',
      );
    } catch (_) {
      handshake.close();
      rethrow;
    }
    final first = await handshake.first as List<Object?>;
    final commands = first[0] as SendPort;
    final available = first[1] as bool;
    return FramePreprocessor._(isolate, commands, handshake, available);
  }

  /// Whether the full OpenCV pipeline is compiled in and loadable.
  bool get isAvailable => _available && !_disposed;

  /// Runs Phase 1 on one camera frame.
  ///
  /// [bytes] is either a gray8 / NV21 buffer (`format: 'gray8'`, only the
  /// leading width×height luminance bytes are read) or a BGRA8888 buffer
  /// (`format: 'bgra8888'` with [bytesPerRow]).
  ///
  /// Returns `null` when no card quad was detected (caller should fall back
  /// to full-frame OCR) or when the pipeline is unavailable.
  Future<PreprocessedFrame?> process({
    required Uint8List bytes,
    required String format,
    required int width,
    required int height,
    int bytesPerRow = 0,
    int rotation = 0,
    int mode = CardCvMode.clahe,
  }) async {
    if (!isAvailable) return null;

    final id = _nextId++;
    final completer = Completer<_Response>();
    _pending[id] = completer;
    // Copy before transfer — TransferableTypedData detaches the source
    // buffer, and the scanner still needs [bytes] for MethodChannel fallback.
    _commands.send(_Request(
      id: id,
      bytes: TransferableTypedData.fromList([Uint8List.fromList(bytes)]),
      format: format,
      width: width,
      height: height,
      bytesPerRow: bytesPerRow,
      rotation: rotation,
      mode: mode,
    ));

    final response = await completer.future;
    if (!response.found || response.bytes == null) return null;
    return PreprocessedFrame(
      bytes: response.bytes!.materialize().asUint8List(),
      width: response.width,
      height: response.height,
      quad: response.quad,
    );
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final completer in _pending.values) {
      completer.complete(_Response(-1, false, null, 0, 0, Float32List(8)));
    }
    _pending.clear();
    _commands.send(null); // worker frees native buffers and closes its port
    _responses.close();
    _isolate.kill(priority: Isolate.beforeNextEvent);
  }
}
