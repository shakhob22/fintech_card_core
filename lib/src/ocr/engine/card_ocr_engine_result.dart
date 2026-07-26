/// Structured result from a native card OCR engine (CardScan SSD, etc.).
class CardOcrEngineResult {
  const CardOcrEngineResult({
    this.pan,
    this.expiryDate,
    this.confidence = 0,
    this.engine = 'unknown',
    this.rawText,
    this.debug,
  });

  final String? pan;
  final String? expiryDate;
  final double confidence;
  final String engine;

  /// Optional free-form text for parsers that still expect OCR prose
  /// (e.g. multi-pass `"pass1 ; pass2"`). Prefer [pan] / [expiryDate] when set.
  final String? rawText;

  /// Native diagnostic string (iOS bridge size / model status). Not for parsing.
  final String? debug;

  bool get hasPan => pan != null && pan!.isNotEmpty;

  /// Text blob for [OcrParser] / consensus when structured fields are sparse.
  String get textForParser {
    if (rawText != null && rawText!.isNotEmpty) return rawText!;
    final parts = <String>[];
    if (pan != null && pan!.isNotEmpty) parts.add(pan!);
    if (expiryDate != null && expiryDate!.isNotEmpty) parts.add(expiryDate!);
    return parts.join('\n');
  }

  factory CardOcrEngineResult.fromChannel(dynamic value) {
    if (value == null) return const CardOcrEngineResult();
    if (value is String) {
      return CardOcrEngineResult(rawText: value, engine: 'legacy_text');
    }
    if (value is Map) {
      final map = Map<String, dynamic>.from(value);
      return CardOcrEngineResult(
        pan: map['pan'] as String?,
        expiryDate: map['expiryDate'] as String?,
        confidence: (map['confidence'] as num?)?.toDouble() ?? 0,
        engine: map['engine'] as String? ?? 'cardscan_ssd',
        rawText: map['rawText'] as String?,
        debug: map['debug'] as String?,
      );
    }
    return const CardOcrEngineResult();
  }
}
