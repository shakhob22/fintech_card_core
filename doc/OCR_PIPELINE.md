# OCR Card Scanning Pipeline (PaddleOCR)

On-device general OCR used by `OcrCardScanner` / `PaddleCardOcrEngine`.

```
CameraImage (Flutter)
    │  Y plane (Android) / BGRA (iOS) + optional full-card overlay ROI
    ▼
Isolate JPEG encode (package:image, max side 1280)
    ▼
Paddle Lite (flutter_paddle_ocr)
    assets → app support dir:
      det_db.nb + rec_crnn.nb + cls.nb + ppocr_keys_v1.txt  (PP-OCRv2 slim)
    ▼
CardFieldExtractor
    16-digit PAN (4×4 / Luhn / BIN heuristics) + MM/YY expiry + name
    ▼
OcrResultAccumulator (2 matching frames) → CardReaderSuccessState
```

## Public entry points

| API | Role |
|-----|------|
| `CardReaderController.startOcrScan()` | Headless / overlay via `OcrCardScanner` |
| `CardScannerOverlay.show(...)` | Full-screen UI returning `CardData?` |
| `CardScannerView(onCardScanned:)` | Standalone camera widget (PAN string) |
| `PaddleCardOcrEngine` | Low-level load / recognize / dispose |
| `CardFieldExtractor` | Pure-Dart PAN/expiry post-process |
| `CardOcrEngine` | Legacy TFLite CRNN strip model (kept for experiments) |

## Offline models

Bundled under `assets/models/paddle/` (~4.7 MB). Copied once to
`getApplicationSupportDirectory()/paddle_ocr_v2/` because Paddle Lite needs
filesystem paths.

## Platform notes

- **Android**: `flutter_paddle_ocr` pins NDK `25.2.9519653`. Install via sdkmanager if missing.
- **iOS**: physical arm64 device (simulator not supported by Paddle Lite v2.10).
- First cold start loads native Paddle Lite + OpenCV (cached by the plugin).

## Notes

- No network required at runtime after the app is installed (models are assets).
- Native plugins: NFC (`fintech_card_core`) + Paddle (`flutter_paddle_ocr`).
