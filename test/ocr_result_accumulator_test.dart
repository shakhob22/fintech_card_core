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

    setUp(() => acc = OcrResultAccumulator());

    test('locks PAN on a single Luhn-valid match (CardScan-tuned)', () {
      expect(acc.accumulate('4111111111111111', null, now: t0), isNull);
      expect(acc.lockedPan, '4111111111111111');
      expect(acc.hasLockedPan, isTrue);
      expect(acc.preferExpiryRoi, isTrue);
    });

    test('replaces unlocked vote when a different PAN appears before complete', () {
      acc.accumulate('4111111111111111', null, now: t0);
      expect(acc.lockedPan, '4111111111111111');
      // Once locked, PAN is sticky — new PANs do not unlock.
      acc.accumulate('5500005555555559', null, now: t0);
      expect(acc.lockedPan, '4111111111111111');
    });

    test('locks expiry on a single match', () {
      acc.accumulate(null, '12/28', now: t0);
      expect(acc.lockedExpiry, '12/28');
    });

    test('completes with PAN and expiry when both present', () {
      final data = acc.accumulate(
        '4111111111111111',
        '12/28',
        now: t0,
      );
      expect(data, isNotNull);
      expect(data!.pan, '4111111111111111');
      expect(data.expiryDate, '12/28');
      expect(data.readMode, CardReadMode.ocr);
    });

    test('completes with PAN only after expiry grace', () {
      acc.accumulate('4111111111111111', null, now: t0);
      expect(acc.lockedPan, isNotNull);
      expect(
        acc.accumulate(null, null, now: t0.add(const Duration(milliseconds: 100))),
        isNull,
      );

      final data = acc.completeIfReady(
        now: t0.add(OcrResultAccumulator.expiryGrace),
      );
      expect(data, isNotNull);
      expect(data!.pan, '4111111111111111');
      expect(data.expiryDate, isNull);
    });

    test('late expiry during grace wins over null expiry', () {
      acc.accumulate('4111111111111111', null, now: t0);
      final data = acc.accumulate(
        null,
        '01/30',
        now: t0.add(const Duration(milliseconds: 50)),
      );
      expect(data, isNotNull);
      expect(data!.expiryDate, '01/30');
    });

    test('reset clears all state', () {
      acc.accumulate('4111111111111111', '12/28', now: t0);
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
