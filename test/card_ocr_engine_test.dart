import 'dart:typed_data';

import 'package:fintech_card_core/card_ocr_plugin.dart';
import 'package:flutter_test/flutter_test.dart';

Float32List _logitsForPan(String pan, {int padBlanks = 4}) {
  // Alphabet: blank=0, '0'=1 … '9'=10
  // Emit digit, blank, digit… so identical consecutive digits survive CTC.
  final steps = <int>[];
  for (var i = 0; i < pan.length; i++) {
    steps.add(pan.codeUnitAt(i) - 0x30 + 1);
    steps.add(0); // blank separator
  }
  for (var i = 0; i < padBlanks; i++) {
    steps.add(0);
  }

  const c = 11;
  final t = steps.length;
  final logits = Float32List(t * c);
  for (var ti = 0; ti < t; ti++) {
    final best = steps[ti];
    for (var ci = 0; ci < c; ci++) {
      logits[ti * c + ci] = ci == best ? 1.0 : 0.0;
    }
  }
  return logits;
}

List<List<List<double>>> _nestedLogitsForPan(String pan) {
  final flat = _logitsForPan(pan);
  const c = 11;
  final t = flat.length ~/ c;
  return [
    List.generate(t, (ti) {
      return List.generate(c, (ci) => flat[ti * c + ci]);
    }),
  ];
}

void main() {
  group('CardOcrEngine.greedyCtcDecode', () {
    test('collapses repeats, drops blank, maps classes to digits', () {
      const t = 8;
      const c = 11;
      final logits = Float32List(t * c);

      void setBest(int time, int classIndex) {
        for (var i = 0; i < c; i++) {
          logits[time * c + i] = i == classIndex ? 1.0 : 0.0;
        }
      }

      // blank, 4, 4, blank, 1, 1, blank, 1  → "411"
      setBest(0, 0);
      setBest(1, 5); // '4'
      setBest(2, 5); // repeat → collapse
      setBest(3, 0); // blank
      setBest(4, 2); // '1'
      setBest(5, 2); // repeat → collapse
      setBest(6, 0); // blank (allows another '1')
      setBest(7, 2); // '1'

      final pan = CardOcrEngine.greedyCtcDecode(
        logits,
        timeSteps: t,
        numClasses: c,
      );
      expect(pan, '411');
    });

    test('returns null for empty decode', () {
      const t = 4;
      const c = 11;
      final logits = Float32List(t * c); // all zeros → blank wins
      expect(
        CardOcrEngine.greedyCtcDecode(logits, timeSteps: t, numClasses: c),
        isNull,
      );
    });
  });

  group('CtcLayout.fromShape', () {
    test('detects [1, T, C]', () {
      final layout = CtcLayout.fromShape(const [1, 80, 11]);
      expect(layout, isNotNull);
      expect(layout!.timeSteps, 80);
      expect(layout.numClasses, 11);
      expect(layout.channelsFirst, isFalse);
    });

    test('detects [1, C, T]', () {
      final layout = CtcLayout.fromShape(const [1, 11, 80]);
      expect(layout, isNotNull);
      expect(layout!.timeSteps, 80);
      expect(layout.numClasses, 11);
      expect(layout.channelsFirst, isTrue);
    });
  });

  group('decodeAndValidate', () {
    test('accepts Luhn-valid 16-digit PAN from [T,C] logits', () {
      const pan = '4111111111111111';
      final nested = _nestedLogitsForPan(pan);
      final t = nested[0].length;
      final result = CardOcrEngine.decodeAndValidate(nested, [1, t, 11]);
      expect(result, pan);
      expect(Luhn.validate(result!), isTrue);
    });

    test('rejects Luhn-invalid PAN', () {
      const pan = '4111111111111112';
      final nested = _nestedLogitsForPan(pan);
      final t = nested[0].length;
      expect(CardOcrEngine.decodeAndValidate(nested, [1, t, 11]), isNull);
    });

    test('decodeRaw returns digits without Luhn gate', () {
      const pan = '4111111111111112';
      final nested = _nestedLogitsForPan(pan);
      final t = nested[0].length;
      expect(CardOcrEngine.decodeRaw(nested, [1, t, 11]), pan);
    });
  });
}
