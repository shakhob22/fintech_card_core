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
    r'(?:^|[^\dA-Za-z])('
    r'\d{4}[\s\-]?\d{4}[\s\-]?\d{4}[\s\-]?\d{4}' // 16-digit
    r'|\d{4}[\s\-]?\d{6}[\s\-]?\d{5}' // 15-digit Amex
    r'|\d{13,19}' // contiguous digit run
    r')(?:[^\dA-Za-z]|$)',
  );

  /// Looser pattern for OCR text with letter/digit confusions (O/0, I/1, …).
  static final _messyPanRegex = RegExp(
    r'(?:^|[^\w])('
    r'[0-9OoIlSBZG]{4}[\s\-]?[0-9OoIlSBZG]{4}[\s\-]?[0-9OoIlSBZG]{4}[\s\-]?[0-9OoIlSBZG]{4}'
    r'|[0-9OoIlSBZG]{13,19}'
    r')(?:[^\w]|$)',
  );

  static final _expiryRegex = RegExp(
    r'\b(0[1-9]|1[0-2])[\/\-\s]([2-9]\d)\b',
  );

  /// Parse [ocrText] and return a [CardData] if a Luhn-valid PAN is found.
  ///
  /// Expiry is attached when present in the same text; PAN-only results are
  /// valid (matches live scanner PAN-first completion).
  static CardData? parse(String ocrText) {
    final partial = extract(ocrText);
    if (partial.pan == null) return null;
    return CardData.fromOcr(pan: partial.pan!, expiryDate: partial.expiryDate);
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

  static String _toDigits(String raw) {
    final cleaned = raw
        .replaceAll(RegExp('[OoDd]'), '0')
        .replaceAll(RegExp('[Il|]'), '1')
        .replaceAll(RegExp('[Ss]'), '5')
        .replaceAll(RegExp('[Bb]'), '8')
        .replaceAll(RegExp('[Gg]'), '6')
        .replaceAll(RegExp('[Zz]'), '2')
        .replaceAll(RegExp(r'[\s\-]'), '');
    return cleaned.replaceAll(RegExp(r'\D'), '');
  }

  static String? _extractPan(String text) {
    for (final match in _panRegex.allMatches(text)) {
      final digits = _toDigits(match.group(1) ?? '');
      if (digits.length >= 13 &&
          digits.length <= 19 &&
          Luhn.validate(digits)) {
        return digits;
      }
    }
    for (final match in _messyPanRegex.allMatches(text)) {
      final digits = _toDigits(match.group(1) ?? '');
      if (digits.length >= 13 &&
          digits.length <= 19 &&
          Luhn.validate(digits)) {
        return digits;
      }
    }
    return null;
  }

  static String? _extractExpiry(String text) {
    final match = _expiryRegex.firstMatch(text);
    if (match == null) return null;
    return '${match.group(1)}/${match.group(2)}';
  }
}
