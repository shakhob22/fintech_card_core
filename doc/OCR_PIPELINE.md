# OCR Card Scanning Pipeline (TFLite)

On-device CRNN scanner used by `OcrCardScanner` / `CardOcrEngine`.

```
CameraImage (Flutter)
    │  Y plane (Android) / BGRA (iOS) + optional overlay ROI
    ▼
Isolate preprocess (package:image)
    resize → grayscale → float32 NCHW [1, 1, 48, 320]
    ▼
IsolateInterpreter (tflite_flutter)
    assets: packages/fintech_card_core/assets/models/card_ocr.tflite
    ▼
Greedy CTC decode → 16 digits → Luhn
    ▼
2 consecutive identical PANs → CardReaderSuccessState / onCardScanned
```

## Public entry points

| API | Role |
|-----|------|
| `CardReaderController.startOcrScan()` | Headless / overlay via `OcrCardScanner` |
| `CardScannerOverlay.show(...)` | Full-screen UI returning `CardData?` |
| `CardScannerView(onCardScanned:)` | Standalone camera widget (PAN string) |
| `CardOcrEngine` | Low-level load / recognize / dispose |

## Notes

- No native ML Kit / Vision OCR channel — inference is 100% Dart + TFLite.
- Native plugins only handle NFC (`fintech_card_core/nfc`).
