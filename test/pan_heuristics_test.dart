import 'package:fintech_card_core/fintech_card_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PanHeuristics.normalize', () {
    test('maps emboss confusions (b→6, B→8, O→0)', () {
      expect(PanHeuristics.normalize('b11B OIlS'), '61180115');
      expect(PanHeuristics.normalize('4111-1111-1111-1111'), '4111111111111111');
    });

    test('marks unmappable glyphs as ?', () {
      expect(PanHeuristics.normalize('4111X11111111111'), '4111?11111111111');
    });
  });

  group('PanHeuristics.applyBinCompletion', () {
    test('completes HUMO 9860 when first digit is 9 and rest ambiguous', () {
      expect(
        PanHeuristics.applyBinCompletion('9???111111111111'),
        '9860111111111111',
      );
    });

    test('completes UzCard 8600 when first digit is 8', () {
      expect(
        PanHeuristics.applyBinCompletion('8?0?555555555555'),
        '8600555555555555',
      );
    });

    test('recovers missing first digit from HUMO pattern x860', () {
      expect(
        PanHeuristics.applyBinCompletion('?86?111111111111'),
        '9860111111111111',
      );
    });

    test('does not overwrite confident non-matching BIN digits', () {
      expect(
        PanHeuristics.applyBinCompletion('9123111111111111'),
        '9123111111111111',
      );
    });
  });

  group('PanHeuristics.repair', () {
    test('brute-forces a single ambiguous check digit via Luhn', () {
      // 4111111111111111 is the well-known Luhn-valid Visa test PAN.
      expect(PanHeuristics.repair('411111111111111?'), '4111111111111111');
    });

    test('repairs letter confusion then brute-forces one ?', () {
      // 'b' → '6'; trailing 'X' → '?'.
      final normalized = PanHeuristics.normalize('4111 1111 1111 116X');
      expect(normalized, '411111111111116?');
      final fixed = PanHeuristics.repair(normalized);
      expect(fixed, isNotNull);
      expect(Luhn.validate(fixed!), isTrue);
      expect(fixed.substring(0, 15), '411111111111116');
    });

    test('rejects ≥2 unknowns (no guessing)', () {
      expect(PanHeuristics.repair('41111111111111??'), isNull);
    });

    test('repairs via lowConfidenceIndex when checksum fails', () {
      // Flip last digit of a valid PAN, point repair at that index.
      const bad = '4111111111111112';
      expect(Luhn.validate(bad), isFalse);
      expect(
        PanHeuristics.repair(bad, lowConfidenceIndex: 15),
        '4111111111111111',
      );
    });
  });

  group('PanHeuristics.realignDroppedPrefix (faded HUMO leading digit)', () {
    // Synthetic Luhn-valid local PANs.
    const humo = '9860123456789015';
    const uzcard = '8600123456789012';

    test('synthetic fixtures are Luhn-valid', () {
      expect(Luhn.validate(humo), isTrue);
      expect(Luhn.validate(uzcard), isTrue);
    });

    test('restores dropped 9 on a 15-digit HUMO read', () {
      final shifted = humo.substring(1); // '860123456789015'
      expect(PanHeuristics.realignDroppedPrefix(shifted), humo);
      expect(PanHeuristics.repair(shifted), humo);
    });

    test('restores dropped 98 on a 14-digit HUMO read', () {
      final shifted = humo.substring(2); // '60123456789015'
      expect(PanHeuristics.realignDroppedPrefix(shifted), humo);
      expect(PanHeuristics.repair(shifted), humo);
    });

    test('restores dropped 8 on a 15-digit UzCard read', () {
      final shifted = uzcard.substring(1); // '600123456789012'
      expect(PanHeuristics.realignDroppedPrefix(shifted), uzcard);
      expect(PanHeuristics.repair(shifted), uzcard);
    });

    test('repairs 16-char shifted read with stray trailing glyph', () {
      // Head 9 lost, junk '7' glued to the tail → still 16 chars but shifted.
      final shifted = '${humo.substring(1)}7';
      expect(PanHeuristics.repair(shifted), humo);
    });

    test('rejects implausible fully-resolved 98xx / 86xx heads', () {
      // '8601…' cannot be a real card here — it is a shifted HUMO read that
      // realign cannot rescue (no Luhn match) → must return null, never the
      // shifted string itself.
      expect(PanHeuristics.repair('8601234567890123'), isNull);
    });

    test('does not touch Amex-length readings', () {
      expect(
        PanHeuristics.realignDroppedPrefix('378282246310005'),
        isNull,
      );
    });
  });

  group('PanHeuristics.chooseUndegraded (systematic emboss misread)', () {
    // Real regression: green same-hue UzCard emboss was read as
    // …6821…9551 instead of …6827…9654 (7→1, 6→5, 4→1 stroke loss).
    // BOTH strings pass Luhn, so the checksum alone cannot arbitrate.
    const wrong = '5614682111859551';
    const right = '5614682711859654';

    test('regression fixtures are both Luhn-valid', () {
      expect(Luhn.validate(wrong), isTrue);
      expect(Luhn.validate(right), isTrue);
    });

    test('prefers complex digits over their stroke-lost rivals', () {
      expect(PanHeuristics.chooseUndegraded([wrong, right]), right);
      expect(PanHeuristics.chooseUndegraded([right, wrong]), right);
    });

    test('single candidate passes through; empty returns null', () {
      expect(
        PanHeuristics.chooseUndegraded(['4111111111111111']),
        '4111111111111111',
      );
      expect(PanHeuristics.chooseUndegraded(const []), isNull);
    });

    test('returns null when the conflict is not stroke-loss shaped', () {
      // 1 vs 9 at the last position — neither degrades into the other.
      expect(
        PanHeuristics.chooseUndegraded(
          ['4111111111111111', '4111111111111119'],
        ),
        isNull,
      );
    });
  });

  group('OcrParser.extractAllPans (multi-pass native output)', () {
    test('returns every conflicting Luhn-valid reading', () {
      final pans = OcrParser.extractAllPans(
        'MKBANK 5614 6821 1185 9551 ; 5614 6827 1185 9654 01/27',
      );
      expect(
        pans,
        containsAll(['5614682111859551', '5614682711859654']),
      );
    });

    test('deduplicates identical readings across passes', () {
      final pans = OcrParser.extractAllPans(
        '4111 1111 1111 1111 ; 4111 1111 1111 1111',
      );
      expect(pans, ['4111111111111111']);
    });
  });

  group('OcrParser.extractRawCandidates (plural)', () {
    test('returns one reading per pass for consensus voting', () {
      final readings = OcrParser.extractRawCandidates(
        '5614 6821 1185 9551 ; 5614 6827 1185 9654',
      );
      expect(
        readings,
        containsAll(['5614682111859551', '5614682711859654']),
      );
    });
  });

  group('FrameConsensusBuffer', () {
    test('votes per position across frames', () {
      final buf = FrameConsensusBuffer(capacity: 5, minVotes: 3);
      // Position 4 flickers 8→3 once; majority keeps 8.
      buf.add('4111811111111111');
      buf.add('4111811111111111');
      buf.add('4111311111111111');
      buf.add('4111811111111111');
      expect(buf.isWarm, isTrue);
      expect(buf.consensus, '4111811111111111');
    });

    test('emits ? when votes fall short of minVotes', () {
      final buf = FrameConsensusBuffer(capacity: 5, minVotes: 3);
      buf.add('4111111111111111');
      buf.add('4111111111111112');
      buf.add('4111111111111113');
      expect(buf.consensus![15], '?');
    });

    test('rejects misaligned lengths', () {
      final buf = FrameConsensusBuffer();
      expect(buf.add('411111111111111'), isFalse);
      expect(buf.frameCount, 0);
    });
  });

  group('OcrParser + heuristics integration', () {
    test('extract recovers clean PAN', () {
      final partial = OcrParser.extract('VISA 4111 1111 1111 1111');
      expect(partial.pan, '4111111111111111');
    });

    test('extract realigns a shifted HUMO read from OCR text', () {
      // Faded leading 9: OCR emits '860 1234 5678 9015'.
      final partial = OcrParser.extract('HUMO 860 1234 5678 9015 01/30');
      expect(partial.pan, '9860123456789015');
      expect(partial.expiryDate, '01/30');
    });

    test('extractRawCandidate keeps ? for consensus', () {
      final raw = OcrParser.extractRawCandidate(
        'card 4111 1111 1111 111X held',
      );
      expect(raw, '411111111111111?');
    });
  });
}
