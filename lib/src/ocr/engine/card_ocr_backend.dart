import 'card_ocr_engine_result.dart';

/// Pluggable native card OCR backend (MethodChannel, FFI, …).
abstract class CardOcrBackend {
  String get name;

  Future<CardOcrEngineResult> recognizeFrame(Map<String, dynamic> args);

  Future<CardOcrEngineResult> recognizeGray8({
    required int width,
    required int height,
    required List<int> bytes,
  });
}
