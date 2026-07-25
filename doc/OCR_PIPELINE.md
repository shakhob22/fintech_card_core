# OCR Card Scanning Pipeline

Four-phase card scanner used by `OcrCardScanner`. Phase 2 uses **CardScan SSD OCR**
(getbouncer MIT models) instead of general-purpose ML Kit / Vision.

```
CameraImage (Flutter)
    │  pack once (NV21 / BGRA), downsample ≤1600, optional overlay ROI
    ▼
Phase 1 — OpenCV C++ (dart:ffi isolate)          [optional]
    Canny → findContours → ID-1 aspect → warpPerspective
    → CLAHE on Y/L → optional adaptive threshold → PAN band crop
    │  gray8 canvas (≤1024×646)
    ▼
Phase 2 — CardScan SSD OCR (native)
    ocr/recognizeGray8  → SSD TFLite (Android) / CoreML (iOS)
    ocr/recognizeFrame  → same engine on full / ROI frame
    │  structured { pan, expiryDate?, confidence, engine }
    ▼
Phase 3 — FrameConsensusBuffer (Dart)
    rolling last-5 readings, per-position majority vote (≥3)
    │  "41118?1111111111"
    ▼
Phase 4 — PanHeuristics (Dart)
    letter→digit map → Uz BIN fill (9860/8600) → Luhn brute-force
    │  Luhn-valid PAN
    ▼
OcrResultAccumulator → CardReaderSuccessState
```

---

## Why CardScan (not drop-in UI SDK)

Public CardScan APIs (`CardScanActivity`, `ScanViewController`, Stripe
`CardScanSheet`) own the camera and UI. This plugin is **headless**: Flutter
`camera` + `CardScannerOverlay` supply preview/ROI. Integration uses only the
SSD digit OCR engines:

| Platform | Engine | Model |
|----------|--------|--------|
| Android | `SsdOcrEngine` (TFLite) | `assets/cardscan/darknite_1_1_1_16.tflite` |
| iOS | `OcrDD` / `SSDOcrDetect` (CoreML) | `SSDOcr.mlmodelc` |

Upstream: [cardscan-android](https://github.com/getbouncer/cardscan-android),
[cardscan-ios](https://github.com/getbouncer/cardscan-ios) (MIT, deprecated).
See [`third_party/README.md`](../third_party/README.md).

---

## MethodChannel contract (`fintech_card_core/ocr`)

| Method | Args | Returns |
|--------|------|---------|
| `ocr/recognizeFrame` | `width`, `height`, `rotation`, `format` (`nv21`\|`bgra8888`), `bytes`, optional ROI | `Map` `{pan, expiryDate, confidence, engine}` |
| `ocr/recognizeGray8` | `width`, `height`, `bytes` (gray8) | same `Map` |
| `ocr/recognizeText` | `imagePath` | same `Map` (still / debug) |

Legacy plain `String` replies are still accepted by
`CardOcrEngineResult.fromChannel` for tests.

---

## Passing `CameraImage` into native code without blocking the UI

### 1. Stream + throttle

```dart
await cameraCtrl.startImageStream(_onCameraImage);

void _onCameraImage(CameraImage image) {
  if (_isProcessing) return;
  if (now - _lastOcrAt < Duration(milliseconds: 70)) return;
  _isProcessing = true;
  _processFrame(image).whenComplete(() => _isProcessing = false);
}
```

### 2. Pack the frame once

| Platform | `imageFormatGroup` | Packed buffer |
|----------|--------------------|---------------|
| Android  | `yuv420`           | Contiguous **NV21** |
| iOS      | `bgra8888`         | Single BGRA plane |

Downsample when `max(width, height) > 1600`.

### 3. Hand-off

**A. OpenCV FFI (Phase 1)** — optional worker isolate → `ocr/recognizeGray8`.

**B. Full frame** — `ocr/recognizeFrame` with packed bytes + ROI.

| Side | Threading |
|------|-----------|
| Android | single-thread executor + TFLite |
| iOS | `DispatchQueue.global(qos: .userInitiated)` + CoreML |

---

## Dart modules

| Module | Role |
|--------|------|
| `lib/src/ocr/ocr_card_scanner.dart` | Live pipeline |
| `lib/src/ocr/engine/card_scan_card_ocr_backend.dart` | MethodChannel → CardScan |
| `lib/src/ocr/engine/card_ocr_engine_result.dart` | Structured result |
| `lib/src/ocr/frame_consensus_buffer.dart` | 5-frame positional vote |
| `lib/src/ocr/pan_heuristics.dart` | Swaps, BIN, Luhn repair |
| `lib/src/ocr/ocr_parser.dart` | Regex extract + raw candidate |

---

## Enabling OpenCV (optional)

Without OpenCV the plugin still works: Phase 1 reports unavailable and CardScan
runs on the ROI / full frame.

### Android

```properties
fintechCardCore.opencvAndroidSdk=/path/to/OpenCV-android-sdk
```

### iOS

In `ios/fintech_card_core.podspec`, uncomment OpenCV dependency lines, then
`pod install`.

---

## Heuristics cheat-sheet

```
substitutions:  b→6, B→8, O/D→0, I/l→1, S→5, Z→2, …
BIN fill:       9??? → 9860 (HUMO),  8??? → 8600 (UzCard)
Luhn repair:    exactly one `?` → try 0–9
```

Expiry may come from CardScan digit-box heuristics (Android) or remain unset
until `OcrResultAccumulator` expiry grace (~1.2s) after PAN lock.

---

## Device test checklist

- [ ] Visa / Mastercard emboss — PAN lock &lt; ~2s
- [ ] HUMO (`9860…`) flat / emboss
- [ ] UzCard (`8600…`) flat / emboss
- [ ] Offline (airplane mode) — models load from assets
- [ ] Overlay ROI + torch still work
- [ ] Latency: compare to previous ML Kit / Vision build
