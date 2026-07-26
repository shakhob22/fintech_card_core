import 'dart:ui' show Rect;

import 'package:fintech_card_core/fintech_card_core.dart';
import 'package:flutter_test/flutter_test.dart';

// Device checklist (contrast classes — colour is only an example):
// - A high-contrast flat: dark card + light PAN (e.g. black Mastercard)
// - B low-contrast flat: light card + grey PAN (e.g. white HUMO)
// - C same-hue emboss: embossed digits matching the face colour
//   (green / blue / purple Uzcard-style) — use side lighting

void main() {
  group('OcrResultAccumulator', () {
    late OcrResultAccumulator acc;
    final t0 = DateTime.utc(2026, 7, 18, 12);
    const pan = '4111111111111111';
    const otherPan = '5500005555555559';

    setUp(() => acc = OcrResultAccumulator());

    /// Feed the same PAN [OcrResultAccumulator.panVotesRequired] times.
    void votePan(String p, {DateTime? now, String? expiry}) {
      final clock = now ?? t0;
      for (var i = 0; i < OcrResultAccumulator.panVotesRequired; i++) {
        acc.accumulate(p, expiry, now: clock);
      }
    }

    test('does not lock PAN on a single Luhn-valid match', () {
      expect(acc.accumulate(pan, null, now: t0), isNull);
      expect(acc.lockedPan, isNull);
      expect(acc.hasLockedPan, isFalse);
    });

    test('locks PAN after panVotesRequired consecutive identical matches', () {
      for (var i = 0; i < OcrResultAccumulator.panVotesRequired - 1; i++) {
        acc.accumulate(pan, null, now: t0);
        expect(acc.lockedPan, isNull);
      }
      expect(acc.accumulate(pan, null, now: t0), isNull);
      expect(acc.lockedPan, pan);
      expect(acc.hasLockedPan, isTrue);
      expect(acc.preferExpiryRoi, isTrue);
    });

    test('resets vote count when a different PAN appears before lock', () {
      acc.accumulate(pan, null, now: t0);
      acc.accumulate(pan, null, now: t0);
      expect(acc.lockedPan, isNull);

      acc.accumulate(otherPan, null, now: t0);
      expect(acc.lockedPan, isNull);

      // Need a full streak of [otherPan] after the switch.
      for (var i = 0; i < OcrResultAccumulator.panVotesRequired - 1; i++) {
        acc.accumulate(otherPan, null, now: t0);
      }
      expect(acc.lockedPan, otherPan);
    });

    test('once locked, PAN is sticky — new PANs do not unlock', () {
      votePan(pan);
      expect(acc.lockedPan, pan);
      acc.accumulate(otherPan, null, now: t0);
      expect(acc.lockedPan, pan);
    });

    test('ignores non-Luhn PAN values (defense in depth)', () {
      const bad = '4111111111111112'; // fails Luhn
      for (var i = 0; i < OcrResultAccumulator.panVotesRequired; i++) {
        acc.accumulate(bad, null, now: t0);
      }
      expect(acc.lockedPan, isNull);
    });

    test('locks expiry on a single match', () {
      acc.accumulate(null, '12/28', now: t0);
      expect(acc.lockedExpiry, '12/28');
    });

    test('completes with PAN and expiry when both present after votes', () {
      CardData? data;
      for (var i = 0; i < OcrResultAccumulator.panVotesRequired; i++) {
        data = acc.accumulate(pan, '12/28', now: t0);
      }
      expect(data, isNotNull);
      expect(data!.pan, pan);
      expect(data.expiryDate, '12/28');
      expect(data.readMode, CardReadMode.ocr);
    });

    test('completes with PAN only after expiry grace', () {
      votePan(pan);
      expect(acc.lockedPan, isNotNull);
      expect(
        acc.accumulate(null, null, now: t0.add(const Duration(milliseconds: 100))),
        isNull,
      );

      final data = acc.completeIfReady(
        now: t0.add(OcrResultAccumulator.expiryGrace),
      );
      expect(data, isNotNull);
      expect(data!.pan, pan);
      expect(data.expiryDate, isNull);
    });

    test('late expiry during grace wins over null expiry', () {
      votePan(pan);
      final data = acc.accumulate(
        null,
        '01/30',
        now: t0.add(const Duration(milliseconds: 50)),
      );
      expect(data, isNotNull);
      expect(data!.expiryDate, '01/30');
    });

    test('reset clears all state', () {
      votePan(pan, expiry: '12/28');
      acc.reset();
      expect(acc.lockedPan, isNull);
      expect(acc.lockedExpiry, isNull);
      expect(acc.hasLockedPan, isFalse);
      expect(acc.preferExpiryRoi, isFalse);
    });
  });

  group('OcrRoi bands', () {
    test('panBand and expiryBand stay inside the card ROI', () {
      const card = Rect.fromLTWH(0.1, 0.2, 0.8, 0.5);
      final pan = OcrRoi.panBand(card);
      final expiry = OcrRoi.expiryBand(card);
      expect(pan.left, greaterThanOrEqualTo(card.left));
      expect(pan.right, lessThanOrEqualTo(card.right));
      expect(expiry.left, greaterThanOrEqualTo(card.left));
      expect(expiry.right, lessThanOrEqualTo(card.right));
    });
  });
}
