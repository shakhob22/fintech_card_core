# fintech_card_core_example

Demonstrates NFC, OCR, manual entry, and mock card flows for
`fintech_card_core`.

## iOS NFC

The example ships **without** the NFC Tag Reading entitlement so it builds on a
**personal/free** Apple ID team (OCR, manual, mock still work).

Info.plist already has `NFCReaderUsageDescription` and the ISO7816 AID list.
To enable NFC on a **paid** Apple Developer Program team:

1. Add to `ios/Runner/Runner.entitlements`:

```xml
<key>com.apple.developer.nfc.readersession.formats</key>
<array>
  <string>TAG</string>
</array>
```

2. Enable **Near Field Communication Tag Reading** on your App ID, use a unique
   Bundle Identifier, and select the paid team in Xcode Signing & Capabilities.
3. Run on a **physical iPhone** (Simulator has no NFC).

See [doc/IOS_NFC_SETUP.md](../doc/IOS_NFC_SETUP.md).

**Important:** Apple’s standard CoreNFC API does **not** allow reading
payment-related AIDs (Visa/Mastercard EMV applets).

## Getting Started

```sh
flutter pub get
cd example && flutter run
```
