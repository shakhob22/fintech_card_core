import '../core/luhn.dart';
import '../core/models/card_data.dart';

/// Partial fields extracted from a single OCR frame.
///
/// Either field may be null — glare often obscures PAN or expiry in isolation.
/// [OcrCardScanner] accumulates these across frames before emitting success.
class PartialOcrResult {
  final String? pan;
  final String? expiryDate;

  const PartialOcrResult({this.pan, this.expiryDate});

  bool get isEmpty => pan == null && expiryDate == null;
}

/// Extracts payment card fields from raw OCR text output.
///
/// Regex design notes:
///   - PAN   : matches 16-digit Visa/MC/Discover and 15-digit Amex formats,
///             allowing optional spaces or hyphens every 4 digits. Candidates
///             that fail the Luhn check are skipped.
///   - Expiry: matches MM/YY or MM-YY, MM YY patterns within a valid range.
abstract final class OcrParser {
  static final _panRegex = RegExp(
    r'\b(\d{4}[\s\-]?\d{4}[\s\-]?\d{4}[\s\-]?\d{4}' // 16-digit (Visa / MC)
    r'|\d{4}[\s\-]?\d{6}[\s\-]?\d{5})\b', // 15-digit (Amex)
  );

  static final _expiryRegex = RegExp(
    r'\b(0[1-9]|1[0-2])[\/\-\s]([2-9]\d)\b',
  );

  /// Parse [ocrText] and return a [CardData] if both PAN and expiry are found.
  /// Returns `null` when the text does not contain a recognisable card.
  static CardData? parse(String ocrText) {
    final partial = extract(ocrText);
    if (partial.pan == null || partial.expiryDate == null) return null;
    return CardData.fromOcr(pan: partial.pan!, expiryDate: partial.expiryDate!);
  }

  /// Extract whatever card fields are present in [ocrText].
  ///
  /// Unlike [parse], this does not require both fields in the same frame.
  /// PAN candidates must pass [Luhn.validate].
  static PartialOcrResult extract(String ocrText) {
    final normalised = ocrText.replaceAll('\n', ' ');
    return PartialOcrResult(
      pan: _extractPan(normalised),
      expiryDate: _extractExpiry(normalised),
    );
  }

  static String? _extractPan(String text) {
    for (final match in _panRegex.allMatches(text)) {
      final digits = match.group(0)?.replaceAll(RegExp(r'[\s\-]'), '');
      if (digits != null && Luhn.validate(digits)) return digits;
    }
    return null;
  }

  static String? _extractExpiry(String text) {
    final match = _expiryRegex.firstMatch(text);
    if (match == null) return null;
    return '${match.group(1)}/${match.group(2)}';
  }
}
