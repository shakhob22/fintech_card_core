import 'package:flutter/services.dart';

import 'card_ocr_backend.dart';
import 'card_ocr_engine_result.dart';

/// CardScan SSD OCR via `fintech_card_core/ocr` MethodChannel.
class CardScanCardOcrBackend implements CardOcrBackend {
  CardScanCardOcrBackend({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('fintech_card_core/ocr');

  final MethodChannel _channel;

  @override
  String get name => 'cardscan_ssd';

  @override
  Future<CardOcrEngineResult> recognizeFrame(Map<String, dynamic> args) async {
    final raw = await _channel.invokeMethod<dynamic>('ocr/recognizeFrame', args);
    return CardOcrEngineResult.fromChannel(raw);
  }

  @override
  Future<CardOcrEngineResult> recognizeGray8({
    required int width,
    required int height,
    required List<int> bytes,
  }) async {
    final raw = await _channel.invokeMethod<dynamic>('ocr/recognizeGray8', {
      'width': width,
      'height': height,
      'bytes': bytes,
    });
    return CardOcrEngineResult.fromChannel(raw);
  }
}
