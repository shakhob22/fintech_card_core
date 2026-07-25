# Third-party OCR sources

Vendored references for the **CardScan SSD OCR** engine used by
`fintech_card_core` (headless; no CardScan UI / camera Activity).

## Upstream (MIT)

| Path | Upstream | Notes |
|------|----------|--------|
| *(optional clone)* `cardscan-android/` | [getbouncer/cardscan-android](https://github.com/getbouncer/cardscan-android) | Gitignored reference; runtime uses lean port in `android/.../cardscan/SsdOcrEngine.kt` |
| *(optional clone)* `cardscan-ios/` | [getbouncer/cardscan-ios](https://github.com/getbouncer/cardscan-ios) | Gitignored reference; runtime uses `ios/Classes/CardScan/*` |

```bash
# Optional — for comparing upstream sources
git clone --depth 1 https://github.com/getbouncer/cardscan-android.git third_party/cardscan-android
git clone --depth 1 https://github.com/getbouncer/cardscan-ios.git third_party/cardscan-ios
```

Both upstream repos are **deprecated** (Stripe migration). Stripe’s Android
`stripecardscan` module has since been removed in favour of Google Pay Card
Recognition, which is unsuitable for this headless Flutter plugin.

## Licenses

- `cardscan-android-LICENSE.txt` — MIT (Stripe / Bouncer)
- `cardscan-ios-LICENSE.txt` — MIT (Stripe / Bouncer)

## What ships in the plugin

**Android**

- Asset: `android/src/main/assets/cardscan/darknite_1_1_1_16.tflite`
- Code: `CardScanOcrBridge.kt`, `cardscan/SsdOcrEngine.kt`
- Dep: `org.tensorflow:tensorflow-lite`

**iOS**

- Model: `ios/Classes/CardScan/SSDOcr.mlmodelc` (+ `Generated/SSDOcr.swift`)
- Engine helpers under `ios/Classes/CardScan/` (no `ScanViewController`)
- Bridge: `CardScanOcrBridge.swift`
