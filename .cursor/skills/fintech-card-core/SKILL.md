---
name: fintech-card-core
description: Project context for fintech_card_core Flutter plugin — a headless payment card reading engine (NFC/EMV, TFLite OCR, manual entry, mock). Use at the start of any conversation about this project to instantly load architecture, API surface, file layout, platform contracts, and known caveats without re-reading source files.
---

# fintech_card_core — Project Context

**Package:** `fintech_card_core` v0.1.0  
**Type:** Flutter plugin (headless)  
**Platforms:** Android 24+, iOS 13+ only (no web/desktop)  
**Import:** `package:fintech_card_core/fintech_card_core.dart`  
**OCR-only import:** `package:fintech_card_core/card_ocr_plugin.dart`

---

## Architecture

```
Host App
  └─ CardReaderController (unified entry point)
       ├─ NfcCardReader → NfcBridge (MethodChannel + EventChannel) → Android IsoDep / iOS CoreNFC
       ├─ OcrCardScanner → camera + CardOcrEngine (TFLite CRNN, isolate) → Luhn
       ├─ MockCardProvider → MockCards (static Luhn-valid test PANs)
       └─ submitManualInput() → inline Luhn + MM/YY validation
```

**Design rule:** Native platforms only start/stop NFC sessions and relay raw APDU bytes. All EMV sequencing, TLV parsing, Luhn check, and card OCR (TFLite) are in Dart.

---

## Public API

### Controller

```dart
final controller = CardReaderController();

controller.stateStream   // Stream<CardReaderState> broadcast
controller.currentState  // last emitted state

await controller.startNfcScan();
await controller.stopNfcScan();
await controller.startOcrScan();   // TFLite on-device CRNN
await controller.stopOcrScan();
await controller.submitManualInput(pan: '...', expiryDate: 'MM/YY', cvv: '...', cardholderName: '...');
await controller.loadMockCard(preset: MockCardPreset.visa, simulatedDelay: Duration(seconds: 1), simulateError: false);
controller.reset();
controller.dispose();
```

### OCR UI

```dart
// Controller-driven full-screen overlay (returns CardData?)
final card = await CardScannerOverlay.show(context, controller: controller);

// Standalone widget (PAN callback only)
CardScannerView(onCardScanned: (pan) { ... });
```

### Sealed state hierarchy

```dart
CardReaderIdleState
CardReaderScanningState(mode: CardReadMode, message: String?)
CardReaderSuccessState(data: CardData)
CardReaderErrorState(exception: CardReaderException)
```

### Interfaces (DI / unit testing)

- `INfcReader` — `isAvailable`, `stateStream`, `startScan()`, `stopScan()`, `dispose()`
- `IOcrScanner` — `stateStream`, `cameraController`, `setScanRoi()`, `startScan()`, `stopScan()`, `dispose()`
- `IMockProvider` — `getCard()`, `getCardWithDelay()`, `simulateError()`

---

## File Layout

```
lib/
├── fintech_card_core.dart                    # barrel export
├── card_ocr_plugin.dart                      # TFLite OCR-only export
└── src/
    ├── core/                                 # controller, models, Luhn, interfaces
    ├── nfc/                                  # bridge, EMV, APDU
    ├── ocr/
    │   ├── ocr_card_scanner.dart             # camera + CardOcrEngine (IOcrScanner)
    │   └── ocr_roi.dart                      # overlay → camera ROI mapping
    ├── services/
    │   └── card_ocr_engine.dart              # TFLite load, CTC decode, isolates
    ├── mock/
    └── ui/
        ├── smart_card_input.dart
        ├── nfc_scan_dialog.dart
        ├── card_scanner_overlay.dart         # full-screen OCR via controller
        └── card_scanner_view.dart            # standalone OCR widget

assets/models/card_ocr.tflite                 # CRNN card-number model
android/.../FintechCardCorePlugin.kt          # NFC IsoDep bridge only
ios/Classes/FintechCardCorePlugin.swift       # CoreNFC bridge only
```

---

## Native Channel Contract

**MethodChannel:** `fintech_card_core/nfc` only (no native OCR channel)

| Method | Args | Returns |
|--------|------|---------|
| `nfc/isAvailable` | — | `bool` |
| `nfc/startSession` | `{alertMessage?: String}` | `null` |
| `nfc/stopSession` | `{errorMessage?: String}` | `null` |
| `nfc/transceive` | `{apdu: List<int>}` | `List<int>` |

**EventChannel:** `fintech_card_core/nfc/events`  
Payload: `Map` with `type`: `tagDetected` | `sessionEnded` | `error`; optional `message`

---

## OCR (TFLite) pipeline

```
CameraImage → Isolate preprocess (gray 48×320, float32 NCHW)
  → IsolateInterpreter (card_ocr.tflite)
  → Greedy CTC → 16 digits → Luhn
  → 2 consecutive identical PANs → CardData.fromOcr
```

Asset key: `packages/fintech_card_core/assets/models/card_ocr.tflite`  
Input shape: `[1, 1, 48, 320]`

---

## Key Dependencies

| Package | Purpose |
|---------|---------|
| `plugin_platform_interface ^2.0.2` | Platform interface pattern |
| `camera ^0.11.0` | OCR camera capture |
| `image ^4.5.4` | Frame resize / grayscale |
| `tflite_flutter ^0.12.1` | On-device CRNN inference |
| `equatable ^2.0.7` | CardData value equality |

---

## Known Gaps & Caveats

- **README.md** — still the default Flutter plugin template
- **`getPlatformVersion` scaffold** — present in platform interface/channel files but unused by NFC
- **OCR expiry** — TFLite path currently returns PAN only (`CardData.expiryDate` may be null)
- **Native unit tests** may still reference stale `getPlatformVersion`
