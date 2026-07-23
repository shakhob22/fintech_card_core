---
name: fintech-card-core
description: Project context for fintech_card_core Flutter plugin — a headless payment card reading engine (NFC/EMV, OCR, manual entry, mock). Use at the start of any conversation about this project to instantly load architecture, API surface, file layout, platform contracts, and known caveats without re-reading source files.
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
       ├─ OcrCardScanner → camera + google_mlkit_text_recognition → OcrParser (regex)
       ├─ MockCardProvider → MockCards (static Luhn-valid test PANs)
       └─ submitManualInput() → inline Luhn + MM/YY validation
```

**Design rule:** Native platforms only start/stop NFC sessions and relay raw APDU bytes. All EMV sequencing, TLV parsing, Luhn check, and OCR parsing are in Dart.

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
await controller.loadMockCard(preset: MockCardPreset.visa, simulatedDelay: Duration(seconds: 1), simulateError: false);
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
| `readMode` | `CardReadMode` | `nfc/ocr/manual/mock` |
| `timestamp` | `DateTime` | |
| `maskedPan` | getter | `**** **** **** 1234` |
| `formattedPan` | getter | space-grouped |

### Enums

- `CardReadMode`: `nfc`, `ocr`, `manual`, `mock`
- `CardType`: `visa`, `mastercard`, `amex`, `discover`, `unionPay`, `jcb`, `unknown`
- `MockCardPreset`: `visa`, `mastercard`, `amex`, `discover`, `declined`, `expired`
- `CardReaderErrorCode`: NFC/OCR/manual/mock/unknown error codes

### Interfaces (DI / unit testing)

- `INfcReader` — `isAvailable`, `stateStream`, `startScan()`, `stopScan()`, `dispose()`
- `IOcrScanner` — `stateStream`, `cameraController`, `startScan()`, `stopScan()`, `dispose()`
- `IMockProvider` — `getCard()`, `getCardWithDelay()`, `simulateError()`

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
    │   ├── card_enums.dart                   # CardReadMode, CardType, MockCardPreset
    │   ├── i_nfc_reader.dart
    │   ├── i_ocr_scanner.dart
    │   └── i_mock_provider.dart
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
    ├── mock/
    │   ├── mock_card_provider.dart
    │   └── mock_cards.dart                   # Luhn-valid test PANs
    └── ui/                                   # optional widgets
        ├── smart_card_input.dart             # SmartCardInput form
        ├── nfc_scan_dialog.dart              # NfcScanDialog.show(context, controller:)
        └── card_scanner_overlay.dart         # CardScannerOverlay (full-screen OCR)

android/src/main/kotlin/.../FintechCardCorePlugin.kt   # IsoDep NFC bridge
ios/Classes/FintechCardCorePlugin.swift                 # CoreNFC bridge
example/lib/main.dart                                   # demo: NFC | Manual | Mock tabs
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

---

## Key Dependencies

| Package | Purpose |
|---------|---------|
| `plugin_platform_interface ^2.0.2` | Platform interface pattern |
| `camera ^0.11.0` | OCR camera capture |
| `google_mlkit_text_recognition ^0.14.0` | ML Kit OCR |
| `equatable ^2.0.7` | CardData value equality |

---

## Known Gaps & Caveats

- **README.md** — still the default Flutter plugin template, not yet written
- **`getPlatformVersion` scaffold** — present in platform interface/channel files but not wired to native NFC plugin; both native unit tests test this stale method
- **OpenCV** — optional; stub by default. Enable via `fintechCardCore.opencvAndroidSdk` / `OPENCV_ANDROID_SDK` (Android) or uncomment OpenCV pod (iOS). See `doc/OCR_PIPELINE.md`
- **Native unit tests** (Android `FintechCardCorePluginTest.kt`, iOS `RunnerTests.swift`) are out of sync — test `getPlatformVersion`, not the actual NFC methods
