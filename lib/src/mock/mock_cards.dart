import '../core/models/card_enums.dart';

/// Static catalogue of dummy payment card parameters for developer testing.
///
/// ⚠️ IMPORTANT — Safety guarantees:
///   • Every PAN listed here is a well-known test number (Luhn-valid, never
///     issued to a real cardholder).
///   • No real banking endpoints, maps, locations, or external integrations
///     are referenced anywhere in this file.
///   • These values are intentionally identical to numbers published in
///     official card-brand developer documentation and are safe to use in
///     automated test suites.
abstract final class MockCards {
  static const Map<MockCardPreset, MockCardData> _catalogue = {
    MockCardPreset.visa: MockCardData(
      pan: '4111111111111111',
      expiryDate: '12/28',
      cvv: '737',
      cardholderName: 'TEST VISA CARD',
    ),
    MockCardPreset.mastercard: MockCardData(
      pan: '5500005555555559',
      expiryDate: '08/27',
      cvv: '912',
      cardholderName: 'TEST MASTERCARD',
    ),
    MockCardPreset.amex: MockCardData(
      pan: '371449635398431',
      expiryDate: '03/26',
      cvv: '4532',
      cardholderName: 'TEST AMEX CARD',
    ),
    MockCardPreset.discover: MockCardData(
      pan: '6011111111111117',
      expiryDate: '11/27',
      cvv: '555',
      cardholderName: 'TEST DISCOVER',
    ),
    MockCardPreset.declined: MockCardData(
      pan: '4000000000000002',
      expiryDate: '01/26',
      cvv: '000',
      cardholderName: 'DECLINED TEST',
    ),
    MockCardPreset.expired: MockCardData(
      pan: '4111111111111111',
      expiryDate: '01/20',
      cvv: '737',
      cardholderName: 'EXPIRED TEST CARD',
    ),
  };

  static MockCardData get(MockCardPreset preset) => _catalogue[preset]!;
}

/// Internal value holder — not exported from the package barrel.
final class MockCardData {
  final String pan;
  final String expiryDate;
  final String cvv;
  final String cardholderName;

  const MockCardData({
    required this.pan,
    required this.expiryDate,
    required this.cvv,
    required this.cardholderName,
  });
}
