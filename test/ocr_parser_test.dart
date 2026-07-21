import 'package:fintech_card_core/fintech_card_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Luhn', () {
    test('accepts well-known Visa test PAN', () {
      expect(Luhn.validate('4111111111111111'), isTrue);
    });

    test('accepts Mastercard test PAN', () {
      expect(Luhn.validate('5500005555555559'), isTrue);
    });

    test('rejects single-digit substitution', () {
      // 4111111111111111 with last digit flipped
      expect(Luhn.validate('4111111111111112'), isFalse);
    });

    test('rejects non-digit and short input', () {
      expect(Luhn.validate('4111abcd11111111'), isFalse);
      expect(Luhn.validate('411111111111'), isFalse);
    });
  });

  group('OcrParser.extract', () {
    test('extracts PAN and expiry from the same frame', () {
      const text = 'VISA 4111 1111 1111 1111\nEXP 12/28';
      final partial = OcrParser.extract(text);
      expect(partial.pan, '4111111111111111');
      expect(partial.expiryDate, '12/28');
    });

    test('extracts PAN alone when expiry is missing', () {
      final partial = OcrParser.extract('4111 1111 1111 1111');
      expect(partial.pan, '4111111111111111');
      expect(partial.expiryDate, isNull);
    });

    test('extracts expiry alone when PAN is missing', () {
      final partial = OcrParser.extract('VALID THRU 08/27');
      expect(partial.pan, isNull);
      expect(partial.expiryDate, '08/27');
    });

    test('skips Luhn-invalid PAN candidates', () {
      // Same length pattern but fails Luhn
      final partial = OcrParser.extract('4111 1111 1111 1112 12/28');
      expect(partial.pan, isNull);
      expect(partial.expiryDate, '12/28');
    });

    test('parse succeeds with PAN only (expiry optional)', () {
      final panOnly = OcrParser.parse('4111 1111 1111 1111');
      expect(panOnly?.pan, '4111111111111111');
      expect(panOnly?.expiryDate, isNull);

      final both = OcrParser.parse('4111 1111 1111 1111\n12/28');
      expect(both?.pan, '4111111111111111');
      expect(both?.expiryDate, '12/28');
    });
  });
}
