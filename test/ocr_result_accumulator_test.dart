import 'package:fintech_card_core/fintech_card_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('OcrResultAccumulator', () {
    test('majority-votes each digit position across frames', () {
      final acc = OcrResultAccumulator(windowSize: 5, minFrames: 3);

      // First 4 digits jitter; last 12 stable (matches observed OCR behaviour).
      expect(acc.accumulateVotes(), isNull);

      acc.add('4111111111111111');
      acc.add('4211111111111111');
      expect(acc.accumulateVotes(), isNull); // need minFrames=3

      acc.add('4111111111111111');
      final consensus = acc.accumulateVotes();
      expect(consensus, '4111111111111111');
      expect(Luhn.validate(consensus!), isTrue);
    });

    test('rolling window drops oldest candidates', () {
      final acc = OcrResultAccumulator(windowSize: 3, minFrames: 3);
      acc.add('0000000000000000');
      acc.add('0000000000000000');
      acc.add('0000000000000000');
      expect(acc.accumulateVotes(), '0000000000000000');

      acc.add('1111111111111111');
      acc.add('1111111111111111');
      acc.add('1111111111111111');
      expect(acc.accumulateVotes(), '1111111111111111');
    });

    test('clear resets the buffer', () {
      final acc = OcrResultAccumulator(minFrames: 3);
      acc.add('4111111111111111');
      acc.add('4111111111111111');
      acc.add('4111111111111111');
      expect(acc.accumulateVotes(), isNotNull);
      acc.clear();
      expect(acc.length, 0);
      expect(acc.accumulateVotes(), isNull);
    });
  });
}
