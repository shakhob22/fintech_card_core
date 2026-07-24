import 'dart:ui' show Rect;

import 'package:fintech_card_core/fintech_card_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('OcrRoi.panBand', () {
    test('uses fixed LTRB(0.08, 0.42, 0.92, 0.58) inside the card', () {
      const card = Rect.fromLTWH(0.1, 0.2, 0.8, 0.5);
      final band = OcrRoi.panBand(card);

      expect(band.left, closeTo(card.left + card.width * 0.08, 1e-9));
      expect(band.top, closeTo(card.top + card.height * 0.42, 1e-9));
      expect(band.right, closeTo(card.left + card.width * 0.92, 1e-9));
      expect(band.bottom, closeTo(card.top + card.height * 0.58, 1e-9));
      expect(band.height, greaterThan(0));
      expect(
        band.height / card.height,
        closeTo(0.58 - 0.42, 1e-9),
      );
    });

    test('digitStripRoi narrows full-card ROI but keeps an existing strip', () {
      const card = Rect.fromLTWH(0.1, 0.3, 0.8, 0.5);
      final narrowed = OcrRoi.digitStripRoi(card);
      expect(narrowed.height, lessThan(card.height));
      expect(narrowed.width / narrowed.height, greaterThan(4.0));

      final strip = OcrRoi.panBand(card);
      expect(OcrRoi.digitStripRoi(strip), strip);
    });
  });
}
