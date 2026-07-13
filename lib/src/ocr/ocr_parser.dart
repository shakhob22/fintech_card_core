import '../core/models/card_data.dart';

/// Extracts payment card fields from raw OCR text output.
///
/// Regex design notes:
///   - PAN   : matches 16-digit Visa/MC/Discover and 15-digit Amex formats,
///             allowing optional spaces or hyphens every 4 digits.
///   - Expiry: matches MM/YY or MM-YY, MM YY patterns within a valid range.
abstract final class OcrParser {
  static final _panRegex = RegExp(
    r'\b(\d{4}[\s\-]?\d{4}[\s\-]?\d{4}[\s\-]?\d{4}'  // 16-digit (Visa / MC)
    r'|\d{4}[\s\-]?\d{6}[\s\-]?\d{5})\b',             // 15-digit (Amex)
  );

  static final _expiryRegex = RegExp(
    r'\b(0[1-9]|1[0-2])[\/\-\s]([2-9]\d)\b',
  );

  /// Parse [ocrText] and return a [CardData] if both PAN and expiry are found.
  /// Returns `null` when the text does not contain a recognisable card.
  static CardData? parse(String ocrText) {
    final normalised = ocrText.replaceAll('\n', ' ');

    final pan = _extractPan(normalised);
    if (pan == null) return null;

    final expiry = _extractExpiry(normalised);
    if (expiry == null) return null;

    return CardData.fromOcr(pan: pan, expiryDate: expiry);
  }

  static String? _extractPan(String text) {
    final match = _panRegex.firstMatch(text);
    if (match == null) return null;
    return match.group(0)?.replaceAll(RegExp(r'[\s\-]'), '');
  }

  static String? _extractExpiry(String text) {
    final match = _expiryRegex.firstMatch(text);
    if (match == null) return null;
    return '${match.group(1)}/${match.group(2)}';
  }
}
