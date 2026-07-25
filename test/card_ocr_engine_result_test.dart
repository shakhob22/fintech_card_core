import 'package:fintech_card_core/fintech_card_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CardOcrEngineResult.fromChannel', () {
    test('parses structured CardScan map', () {
      final r = CardOcrEngineResult.fromChannel({
        'pan': '4111111111111111',
        'expiryDate': '12/28',
        'confidence': 0.91,
        'engine': 'cardscan_ssd',
      });
      expect(r.pan, '4111111111111111');
      expect(r.expiryDate, '12/28');
      expect(r.confidence, closeTo(0.91, 1e-9));
      expect(r.engine, 'cardscan_ssd');
      expect(r.hasPan, isTrue);
      expect(r.textForParser, contains('4111111111111111'));
      expect(r.textForParser, contains('12/28'));
    });

    test('accepts legacy plain string', () {
      final r = CardOcrEngineResult.fromChannel('4111 1111 1111 1111\n12/28');
      expect(r.rawText, isNotNull);
      expect(r.engine, 'legacy_text');
      expect(OcrParser.extract(r.textForParser).pan, isNotNull);
    });

    test('null / empty map is empty result', () {
      expect(CardOcrEngineResult.fromChannel(null).hasPan, isFalse);
      expect(CardOcrEngineResult.fromChannel(<String, dynamic>{}).hasPan, isFalse);
    });
  });

  group('OcrResultAccumulator with CardScan-style fields', () {
    test('locks and completes after consecutive Luhn-valid PAN + expiry', () {
      final acc = OcrResultAccumulator();
      final t0 = DateTime.utc(2026, 1, 1);
      CardData? data;
      for (var i = 0; i < OcrResultAccumulator.panVotesRequired; i++) {
        data = acc.accumulate('4111111111111111', '12/28', now: t0);
      }
      expect(data, isNotNull);
      expect(data!.pan, '4111111111111111');
      expect(data.expiryDate, '12/28');
    });

    test('single frame does not complete', () {
      final acc = OcrResultAccumulator();
      final t0 = DateTime.utc(2026, 1, 1);
      expect(
        acc.accumulate('4111111111111111', '12/28', now: t0),
        isNull,
      );
      expect(acc.lockedPan, isNull);
    });
  });
}
