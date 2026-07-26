# fintech_card_core

Headless Flutter plugin for payment card reading (NFC/EMV, OCR, manual).

## Platforms

- Android 24+ (IsoDep NFC)
- iOS 13+ (CoreNFC bridge + CardScan SSD OCR)

## iOS NFC setup

Host apps must add NFC entitlements and Info.plist keys. See
**[doc/IOS_NFC_SETUP.md](doc/IOS_NFC_SETUP.md)**.

Standard CoreNFC cannot read payment-card AIDs (Apple platform policy). Android
NFC working does not imply the same card can be read on iOS.

## Getting Started

This project is a Flutter [plug-in package](https://flutter.dev/to/develop-plugins).

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev).

