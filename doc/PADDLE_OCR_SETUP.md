# PaddleOCR (offline) setup for host apps

`fintech_card_core` now defaults OCR to **on-device Paddle Lite** via
[`flutter_paddle_ocr`](https://pub.dev/packages/flutter_paddle_ocr).

## What you get

- Bundled PP-OCRv2 slim models (`det_db.nb`, `rec_crnn.nb`, `cls.nb`, dict)
- Full-card scan (PAN + expiry + name heuristics)
- No runtime network — assets are copied to app support on first load

## Host app checklist

1. Depend on `fintech_card_core` as usual (plugin registration pulls in
   `flutter_paddle_ocr` automatically).
2. **Android**: install NDK r25c once (required by Paddle Lite v2.10):

```bash
sdkmanager --install "ndk;25.2.9519653"
```

3. **iOS**: run on a **physical arm64 device** (simulator not supported by
   Paddle Lite v2.10). First `pod install` downloads OpenCV + Paddle Lite libs.
4. Camera permission strings (already needed for OCR):

```xml
<!-- AndroidManifest.xml -->
<uses-permission android:name="android.permission.CAMERA" />
```

```xml
<!-- ios/Runner/Info.plist -->
<key>NSCameraUsageDescription</key>
<string>Scan your payment card</string>
```

## Usage (unchanged API)

```dart
final controller = CardReaderController();
await controller.startOcrScan();
// or
CardScannerView(onCardScanned: (pan) => print(pan));
```

## Architecture

See [OCR_PIPELINE.md](OCR_PIPELINE.md).

Legacy TFLite CRNN (`CardOcrEngine`) remains in the package for experiments
but is no longer used by `OcrCardScanner` / `CardScannerView`.
