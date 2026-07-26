# fintech_card_core_example

Simple demo of `fintech_card_core`: **NFC**, **Camera (OCR)**, and **Manual** entry.

```sh
cd example
flutter pub get
flutter run
```

Use a physical device for NFC and camera. Manual entry works in the simulator.

## iOS NFC

The example ships **without** the NFC Tag Reading entitlement so it builds on a
personal/free Apple ID team (camera and manual still work).

See [doc/IOS_NFC_SETUP.md](../doc/IOS_NFC_SETUP.md).
