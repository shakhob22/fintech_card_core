---
name: fintech-card-core
description: Project context for fintech_card_core Flutter plugin — a headless payment card reading engine (NFC/EMV, OCR, manual entry). Use at the start of any conversation about this project to instantly load architecture, API surface, file layout, platform contracts, and known caveats without re-reading source files.
---

# fintech_card_core — Project Context

**Package:** `fintech_card_core` v0.1.0  
**Type:** Flutter plugin (headless)  
**Platforms:** Android 24+, iOS 13+ only (no web/desktop)  
**Import:** `package:fintech_card_core/fintech_card_core.dart`

---

## Architecture

```
Host App
  └─ CardReaderController (unified entry point)
       ├─ NfcCardReader → NfcBridge (MethodChannel + EventChannel) → Android IsoDep / iOS CoreNFC
       ├─ OcrCardScanner → camera + CardScan SSD OCR (native) → OcrParser / PanHeuristics
       └─ submitManualInput() → inline Luhn + MM/YY validation
```

**Design rule:** Native platforms only start/stop NFC sessions and relay raw APDU bytes. All EMV sequencing, TLV parsing, Luhn check, and OCR post-processing are in Dart. OCR digit recognition uses CardScan SSD models (MIT) over `fintech_card_core/ocr` — not ML Kit / Vision UI SDKs.

---

## Public API

### Controller

```dart
// Entry point — injectable sub-readers for testing
final controller = CardReaderController();

controller.stateStream   // Stream<CardReaderState> broadcast
controller.currentState  // last emitted state

await controller.startNfcScan();
await controller.stopNfcScan();
await controller.startOcrScan();
await controller.stopOcrScan();
await controller.submitManualInput(pan: '...', expiryDate: 'MM/YY', cvv: '...', cardholderName: '...');
controller.reset();    // stop scans, emit idle
controller.dispose();  // release all resources
```

### Sealed state hierarchy

```dart
CardReaderIdleState
CardReaderScanningState(mode: CardReadMode, message: String?)
CardReaderSuccessState(data: CardData)
CardReaderErrorState(exception: CardReaderException)
```

### CardData (immutable, Equatable)

| Property | Type | Notes |
|----------|------|-------|
| `pan` | `String` | Raw PAN |
| `expiryDate` | `String` | `MM/YY` |
| `cvv` | `String?` | |
| `cardholderName` | `String?` | |
| `cardType` | `CardType` | BIN-detected |
| `readMode` | `CardReadMode` | `nfc/ocr/manual` |
| `timestamp` | `DateTime` | |
| `maskedPan` | getter | `**** **** **** 1234` |
| `formattedPan` | getter | space-grouped |

### Enums

- `CardReadMode`: `nfc`, `ocr`, `manual`
- `CardType`: `visa`, `mastercard`, `amex`, `discover`, `unionPay`, `jcb`, `unknown`
- `CardReaderErrorCode`: NFC/OCR/manual/unknown error codes

### Interfaces (DI / unit testing)

- `INfcReader` — `isAvailable`, `stateStream`, `startScan()`, `stopScan()`, `dispose()`
- `IOcrScanner` — `stateStream`, `cameraController`, `startScan()`, `stopScan()`, `dispose()`

---

## File Layout

```
lib/
├── fintech_card_core.dart                    # barrel export
├── fintech_card_core_platform_interface.dart # scaffold (getPlatformVersion, unused by NFC)
├── fintech_card_core_method_channel.dart     # scaffold (unused by NFC)
└── src/
    ├── core/
    │   ├── card_reader_controller.dart       # CardReaderController + ICardReaderController
    │   ├── card_data.dart                    # CardData value object
    │   ├── card_reader_state.dart            # sealed state hierarchy
    │   ├── card_reader_exception.dart        # CardReaderException + CardReaderErrorCode
    │   ├── card_enums.dart                   # CardReadMode, CardType
    │   ├── i_nfc_reader.dart
    │   └── i_ocr_scanner.dart
    ├── nfc/
    │   ├── nfc_bridge.dart                   # MethodChannel + EventChannel
    │   ├── nfc_card_reader.dart              # EMV read flow (SELECT PPSE → READ RECORD)
    │   ├── apdu_command.dart                 # ISO 7816-4 APDU framing
    │   ├── apdu_response.dart                # parse SW1/SW2, GET RESPONSE chaining
    │   ├── emv_parser.dart                   # BER-TLV parser + extractors
    │   └── emv_tags.dart                     # TLV tag constants
    ├── ocr/
    │   ├── ocr_card_scanner.dart             # camera + ML Kit, 800ms interval
    │   └── ocr_parser.dart                   # static regex parse(ocrText)
    └── ui/                                   # optional widgets
        ├── smart_card_input.dart             # SmartCardInput form
        ├── nfc_scan_dialog.dart              # NfcScanDialog.show(context, controller:)
        └── card_scanner_overlay.dart         # CardScannerOverlay (full-screen OCR)

android/src/main/kotlin/.../FintechCardCorePlugin.kt   # IsoDep NFC bridge
ios/Classes/FintechCardCorePlugin.swift                 # CoreNFC bridge
example/lib/main.dart                                   # demo: NFC | Camera | Manual
test/fintech_card_core_test.dart                        # unit tests (no platform channels)
```

---

## Native Channel Contract

**MethodChannel:** `fintech_card_core/nfc`

| Method | Args | Returns |
|--------|------|---------|
| `nfc/isAvailable` | — | `bool` |
| `nfc/startSession` | `{alertMessage?: String}` | `null` |
| `nfc/stopSession` | `{errorMessage?: String}` | `null` |
| `nfc/transceive` | `{apdu: List<int>}` | `List<int>` |

**EventChannel:** `fintech_card_core/nfc/events`  
Payload: `Map` with `type`: `tagDetected` | `sessionEnded` | `error`; optional `message`

**MethodChannel:** `fintech_card_core/ocr`

| Method | Args | Returns |
|--------|------|---------|
| `ocr/recognizeFrame` | frame + optional ROI | `Map` `{pan, expiryDate, confidence, engine}` |
| `ocr/recognizeGray8` | gray8 canvas | same `Map` |
| `ocr/recognizeText` | `imagePath` | same `Map` |

---

## Key Dependencies

| Package | Purpose |
|---------|---------|
| `plugin_platform_interface ^2.0.2` | Platform interface pattern |
| `camera ^0.11.0` | OCR camera capture |
| `equatable ^2.0.7` | CardData value equality |
| `org.tensorflow:tensorflow-lite` (Android) | CardScan SSD PAN OCR |
| CoreML `SSDOcr.mlmodelc` (iOS) | CardScan SSD PAN OCR |

---

## Known Gaps & Caveats

- **README.md** — still the default Flutter plugin template, not yet written
- **`getPlatformVersion` scaffold** — present in platform interface/channel files but not wired to native NFC plugin; both native unit tests test this stale method
- **iOS NFC host setup** — TAG entitlement + `iso7816.select-identifiers` must be in the **host** app. Requires a **paid** Apple Developer Program team (personal/free teams cannot provision NFC Tag Reading). See `doc/IOS_NFC_SETUP.md`.
- **iOS payment cards** — standard CoreNFC (`NFCTagReaderSession`) does **not** allow payment-related AIDs. Android IsoDep can read EMV payment cards; iOS generally cannot without Apple’s separate payment NFC programs.
- **OpenCV** — optional; stub by default. Enable via `fintechCardCore.opencvAndroidSdk` / `OPENCV_ANDROID_SDK` (Android) or uncomment OpenCV pod (iOS). See `doc/OCR_PIPELINE.md`
- **Native unit tests** (Android `FintechCardCorePluginTest.kt`, iOS `RunnerTests.swift`) are out of sync — test `getPlatformVersion`, not the actual NFC methods
