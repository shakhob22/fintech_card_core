import 'package:fintech_card_core/card_ocr_plugin.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CardFieldExtractor', () {
    test('assembles HUMO PAN from 4×4 groups and drops BIN echo', () {
      final fields = CardFieldExtractor.extract([
        const OcrTextBox(text: 'HUMO', confidence: 0.99, cx: 900, cy: 40),
        const OcrTextBox(text: '9860', confidence: 0.99, cx: 80, cy: 140),
        const OcrTextBox(text: '1234', confidence: 0.99, cx: 220, cy: 150),
        const OcrTextBox(text: '9860', confidence: 0.99, cx: 90, cy: 210), // BIN
        const OcrTextBox(text: '5678', confidence: 0.99, cx: 360, cy: 160),
        const OcrTextBox(text: '9876', confidence: 0.99, cx: 500, cy: 170),
        const OcrTextBox(text: '07/22', confidence: 0.99, cx: 400, cy: 260),
        const OcrTextBox(text: 'VALID THRU', confidence: 0.95, cx: 380, cy: 290),
      ]);

      expect(fields.pan, '9860123456789876');
      expect(fields.expiryDate, '07/22');
    });

    test('reads full-line HUMO PAN with space and Luhn', () {
      final fields = CardFieldExtractor.extract([
        const OcrTextBox(
          text: '98603501 4284 9073',
          confidence: 0.97,
          cx: 400,
          cy: 200,
        ),
        const OcrTextBox(text: '01/30', confidence: 0.99, cx: 700, cy: 210),
        const OcrTextBox(text: 'VALID THRU', confidence: 0.96, cx: 700, cy: 240),
      ]);

      expect(fields.pan, '9860350142849073');
      expect(fields.luhnPass, isTrue);
      expect(fields.expiryDate, '01/30');
    });

    test('prefixes missing 9 for 15-digit 860… HUMO miss', () {
      final fields = CardFieldExtractor.extract([
        const OcrTextBox(
          text: '860350142849073',
          confidence: 0.95,
          cx: 400,
          cy: 200,
        ),
      ]);

      expect(fields.pan, '9860350142849073');
      expect(fields.luhnPass, isTrue);
    });

    test('prefers correct Uzcard order over rotated Luhn false-positive', () {
      final fields = CardFieldExtractor.extract([
        const OcrTextBox(
          text: '5614682711859654',
          confidence: 0.98,
          cx: 300,
          cy: 200,
        ),
        const OcrTextBox(text: '01/27', confidence: 0.99, cx: 500, cy: 260),
      ]);

      expect(fields.pan, '5614682711859654');
      expect(fields.luhnPass, isTrue);
      expect(fields.expiryDate, '01/27');
    });
  });
}
