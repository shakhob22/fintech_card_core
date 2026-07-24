import 'package:equatable/equatable.dart';
import 'card_enums.dart';

/// Immutable value object representing all data read from a payment card.
///
/// Use the named factory constructors ([fromNfc], [fromOcr], [fromManual],
/// [fromMock]) to create instances — they automatically tag the [readMode]
/// and detect the [cardType] from the BIN.
class CardData extends Equatable {
  /// Primary Account Number (digits only, no separators).
  final String pan;

  /// Expiry date in `MM/YY` format.
  ///
  /// May be `null` for OCR when only the PAN was confidently read (bank-app
  /// style). NFC / manual / mock factories still require a value.
  final String? expiryDate;

  /// Card Verification Value (optional — not available from NFC/OCR).
  final String? cvv;

  /// Cardholder name as printed on the card (optional).
  final String? cardholderName;

  /// Payment network detected from the BIN.
  final CardType cardType;

  /// Channel through which this data was acquired.
  final CardReadMode readMode;

  /// UTC timestamp when the data was captured.
  final DateTime timestamp;

  const CardData({
    required this.pan,
    this.expiryDate,
    this.cvv,
    this.cardholderName,
    required this.cardType,
    required this.readMode,
    required this.timestamp,
  });

  // ── Factories ────────────────────────────────────────────────────────────

  factory CardData.fromNfc({
    required String pan,
    required String expiryDate,
    String? cardholderName,
  }) =>
      CardData(
        pan: pan,
        expiryDate: expiryDate,
        cardholderName: cardholderName,
        cardType: _detectCardType(pan),
        readMode: CardReadMode.nfc,
        timestamp: DateTime.now().toUtc(),
      );

  /// OCR result. [expiryDate] / [cardholderName] are optional — PAN-first
  /// scanning may complete without them.
  factory CardData.fromOcr({
    required String pan,
    String? expiryDate,
    String? cardholderName,
  }) =>
      CardData(
        pan: pan,
        expiryDate: expiryDate,
        cardholderName: cardholderName,
        cardType: _detectCardType(pan),
        readMode: CardReadMode.ocr,
        timestamp: DateTime.now().toUtc(),
      );

  factory CardData.fromManual({
    required String pan,
    required String expiryDate,
    String? cvv,
    String? cardholderName,
  }) =>
      CardData(
        pan: pan,
        expiryDate: expiryDate,
        cvv: cvv,
        cardholderName: cardholderName,
        cardType: _detectCardType(pan),
        readMode: CardReadMode.manual,
        timestamp: DateTime.now().toUtc(),
      );

  factory CardData.fromMock({
    required String pan,
    required String expiryDate,
    String? cvv,
    String? cardholderName,
  }) =>
      CardData(
        pan: pan,
        expiryDate: expiryDate,
        cvv: cvv,
        cardholderName: cardholderName,
        cardType: _detectCardType(pan),
        readMode: CardReadMode.mock,
        timestamp: DateTime.now().toUtc(),
      );

  // ── Helpers ───────────────────────────────────────────────────────────────

  /// PAN with all but the last four digits replaced by `*`.
  String get maskedPan {
    if (pan.length < 4) return pan;
    final visible = pan.substring(pan.length - 4);
    final masked = '*' * (pan.length - 4);
    return masked + visible;
  }

  /// PAN formatted according to the card network's standard grouping.
  ///
  /// American Express uses 4-6-5 (`3782 822463 10005`).
  /// All other networks use 4-4-4-4 (`4111 1111 1111 1111`).
  String get formattedPan {
    if (cardType == CardType.amex && pan.length == 15) {
      return '${pan.substring(0, 4)} ${pan.substring(4, 10)} ${pan.substring(10)}';
    }
    final buffer = StringBuffer();
    for (int i = 0; i < pan.length; i++) {
      if (i > 0 && i % 4 == 0) buffer.write(' ');
      buffer.write(pan[i]);
    }
    return buffer.toString();
  }

  // ── BIN detection ─────────────────────────────────────────────────────────

  static CardType _detectCardType(String pan) {
    final p = pan.replaceAll(RegExp(r'[\s\-]'), '');
    // Uzbek local networks — check before generic ranges
    if (p.startsWith('9860')) return CardType.humo;
    if (p.startsWith('8600')) return CardType.uzcard;
    if (p.startsWith('4')) return CardType.visa;
    if (RegExp(r'^5[1-5]').hasMatch(p) ||
        RegExp(r'^2(2[2-9][1-9]|2[3-9]\d|[3-6]\d{2}|7[01]\d|720)').hasMatch(p)) {
      return CardType.mastercard;
    }
    if (RegExp(r'^3[47]').hasMatch(p)) return CardType.amex;
    if (RegExp(r'^6(011|22[1-9]|[45])').hasMatch(p)) return CardType.discover;
    if (RegExp(r'^62').hasMatch(p)) return CardType.unionPay;
    if (RegExp(r'^35(2[89]|[3-8])').hasMatch(p)) return CardType.jcb;
    return CardType.unknown;
  }

  @override
  List<Object?> get props => [
        pan,
        expiryDate,
        cvv,
        cardholderName,
        cardType,
        readMode,
        timestamp,
      ];
}
