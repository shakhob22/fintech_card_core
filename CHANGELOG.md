## 0.1.2

* Compress README OCR demo GIF so it loads on pub.dev (~50 MB → ~3 MB).

## 0.1.1

* `CardScannerOverlay`: English default coaching hints, with
  `enableCoachingHints`, `sideLightHint`, and `torchHint` overrides.
* README screenshots for NFC, Camera OCR, and Manual entry.

## 0.1.0

* Initial public release of the headless card-reading engine.
* NFC (EMV/ISO 7816) via native IsoDep / CoreNFC bridge; APDU/EMV logic in Dart.
* OCR via CardScan SSD models (Android TFLite / iOS CoreML).
* Manual entry validation (Luhn, expiry, CVV).
* `SmartCardInput` form with `CardInputScheme` (autoDetect, Visa/Mastercard,
  Humo/Uzcard, American Express).
* BIN detection for Visa, Mastercard, Amex, Discover, UnionPay, JCB, Humo, and
  Uzcard; custom `CardBrandBadge` support.
