# iOS NFC host setup

`fintech_card_core` exposes a thin CoreNFC bridge. The **host app** (not the
plugin pod) must declare NFC entitlements and Info.plist keys. CocoaPods cannot
inject these into the host target.

## Paid Apple Developer Program required

**Personal / free Apple ID teams cannot sign apps that use NFC Tag Reading.**

If Xcode reports:

> Personal development teams … do not support the NFC Tag Reading capability  
> Provisioning profile … doesn't include the com.apple.developer.nfc.readersession.formats entitlement

you must use an active **Apple Developer Program** membership (paid), not a free
personal team. There is no workaround in the plugin — Apple blocks this
capability for personal teams.

### Fix steps (paid team)

1. Enroll / use a paid team: [developer.apple.com](https://developer.apple.com/programs/).
2. In **Certificates, Identifiers & Profiles → Identifiers**, create an App ID
   with a **unique** bundle ID (avoid reserved `com.example.*` if the portal
   rejects it).
3. Enable **Near Field Communication Tag Reading** on that App ID.
4. In Xcode (`example/ios/Runner.xcworkspace`):
   - Signing & Capabilities → select the **paid** team
   - Set Bundle Identifier to match the App ID
   - Confirm **Near Field Communication Tag Reading** appears (and
     `Runner.entitlements` still contains `TAG`)
5. Clean + rebuild on a **physical iPhone** (Simulator has no NFC).

To build the example **without** NFC (OCR / manual only) on a personal
team, leave `Runner.entitlements` empty of the TAG key (this is the default in
`example/ios/`). NFC sessions will fail at runtime until you add `TAG` under a
paid team as above.

The example app under `example/ios/` includes `CODE_SIGN_ENTITLEMENTS`, usage
description, and a starter AID list. The **TAG** entitlement is commented out
by default so personal-team `flutter run` succeeds.

## Checklist

1. **Real device** — Simulator has no NFC (`NFCTagReaderSession.readingAvailable`
   is always `false`).
2. **Paid Apple Developer team** — personal teams cannot provision NFC (see above).
3. **Apple Developer App ID** — enable **Near Field Communication Tag Reading**
   for the app’s bundle identifier and regenerate provisioning profiles.
4. **Entitlements** — add a `.entitlements` file referenced by
   `CODE_SIGN_ENTITLEMENTS`:

```xml
<key>com.apple.developer.nfc.readersession.formats</key>
<array>
  <string>TAG</string>
</array>
```

5. **Info.plist**
   - `NFCReaderUsageDescription` — user-facing purpose string.
   - `com.apple.developer.nfc.readersession.iso7816.select-identifiers` — hex
     AID list CoreNFC may auto-SELECT before `didDetect` (include at least
     PPSE `325041592E5359532E4444463031` plus any brand AIDs you expect).

6. **Minimum iOS** — plugin targets iOS 13+ (`NFCTagReaderSession`).

## Apple payment AID restriction

`NFCTagReaderSession` **does not support payment-related Application IDs**.
Attempting to talk to Visa / Mastercard / similar EMV payment applets typically
fails with “Missing required entitlement” or a security violation — even when
TAG entitlement and the AID list are correct.

| Platform | Payment card PAN / expiry via NFC |
|----------|-----------------------------------|
| Android (`IsoDep`) | Generally allowed |
| iOS (standard CoreNFC) | **Blocked by Apple** |

Android working does **not** imply iOS can read the same payment card.

Reading payment cards on iPhone requires a separate Apple program (for example
EU `NFCPaymentTagReaderSession`, or NFC & SE / HCE eligibility). That is outside
this plugin’s current CoreNFC bridge.

## Symptom → cause

| Symptom | Likely cause |
|---------|--------------|
| Personal team / provisioning profile missing NFC entitlement | Free Apple ID — need paid Developer Program |
| Session never opens / “Missing required entitlement” | Missing TAG entitlement or App ID capability |
| Tag never detected | Missing or empty `iso7816.select-identifiers` |
| Entitlement / security violation on card present | Payment AID blocked by CoreNFC |
| Success briefly then Idle / empty UI | Fixed in `NfcCardReader` (sessionEnded race); upgrade plugin |

## Channel contract (unchanged)

MethodChannel `fintech_card_core/nfc`: `nfc/isAvailable`, `nfc/startSession`,
`nfc/stopSession`, `nfc/transceive`.

EventChannel `fintech_card_core/nfc/events`: `tagDetected` | `sessionEnded` |
`error`.
