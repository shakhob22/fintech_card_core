# OCR Card Scanning Pipeline

Four-phase, 100% open-source card scanner used by `OcrCardScanner`.

```
CameraImage (Flutter)
    │  pack once (NV21 / BGRA), downsample ≤1600, optional overlay ROI
    ▼
Phase 1 — OpenCV C++ (dart:ffi isolate)          [optional]
    Canny → findContours → ID-1 aspect → warpPerspective
    → CLAHE on Y/L → optional adaptive threshold → PAN band crop
    │  gray8 canvas (≤1024×646)
    ▼
Phase 2 — Digit OCR (native)
    ocr/recognizeGray8  → ML Kit (Android) / Vision (iOS)   [OpenCV path]
    ocr/recognizeFrame  → multi-pass platform preprocess     [fallback]
    │  raw text
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

## Passing `CameraImage` into native code without blocking the UI

### 1. Stream + throttle (Dart isolate / event loop)

```dart
await cameraCtrl.startImageStream(_onCameraImage);

void _onCameraImage(CameraImage image) {
  if (_isProcessing) return;                          // one in flight
  if (now - _lastOcrAt < Duration(milliseconds: 70)) return; // ~14 fps
  _isProcessing = true;
  _processFrame(image).whenComplete(() => _isProcessing = false);
}
```

Never run OpenCV or ML Kit on the UI isolate. The camera callback already
arrives off the raster thread; keep `_processFrame` async and never `await`
heavy work without yielding.

### 2. Pack the frame once

| Platform | `imageFormatGroup` | Packed buffer |
|----------|--------------------|---------------|
| Android  | `yuv420`           | Contiguous **NV21** (`Y` + interleaved `VU`) |
| iOS      | `bgra8888`         | Single BGRA plane (respect `bytesPerRow`) |

Downsample when `max(width, height) > 1600` (nearest-neighbour) before the
MethodChannel / FFI hop — cuts transfer cost ~4× with little OCR loss.

### 3. Two hand-off paths

**A. OpenCV FFI (Phase 1)** — worker isolate

```dart
final pre = await FramePreprocessor.spawn(); // once per scanner lifetime
final warped = await pre.process(
  bytes: packed.bytes,
  format: Platform.isAndroid ? 'gray8' : 'bgra8888',
  width: packed.width,
  height: packed.height,
  bytesPerRow: packed.bytesPerRow,
  rotation: sensorOrientation,
  mode: CardCvMode.clahe | CardCvMode.panBand,
);
```

- Uses `TransferableTypedData` (zero-copy to the worker).
- `FramePreprocessor` **copies** before transfer so the caller's buffer stays
  valid for the MethodChannel fallback.
- Native symbols: `cardcv_available`, `cardcv_process_frame` (`src/cardcv.cpp`).

**B. MethodChannel OCR (Phase 2)** — platform background executor

```dart
// OpenCV output (already upright, gray8):
await channel.invokeMethod('ocr/recognizeGray8', {
  'width': w, 'height': h, 'bytes': gray8,
});

// Full-frame fallback (NV21 / BGRA + rotation + ROI):
await channel.invokeMethod('ocr/recognizeFrame', packed.toRecognizeArgs());
```

| Side | Threading |
|------|-----------|
| Android | `Executors.newSingleThreadExecutor()` + `Tasks.await` for ML Kit |
| iOS | `DispatchQueue.global(qos: .userInitiated)` + Vision |

Results are posted back on the platform thread; Dart resumes the `Future`
without blocking the UI.

### 4. Digit whitelist

ML Kit Latin / Vision do not expose a hard `[0-9]` charset filter. Restriction
is enforced in Dart:

1. `PanHeuristics.normalize` — letter→digit / `?`
2. Regex + Luhn in `OcrParser`
3. Consensus votes only on `0-9` / `?`

---

## Enabling OpenCV (optional, free)

Without OpenCV the plugin still works: Phase 1 reports unavailable and the
Kotlin / Swift multi-pass path runs inside `ocr/recognizeFrame`.

### Android

1. Download the [OpenCV Android SDK](https://opencv.org/releases/) (Apache 2.0).
2. Point Gradle at it:

```properties
# android/gradle.properties (app or plugin)
fintechCardCore.opencvAndroidSdk=/path/to/OpenCV-android-sdk
```

or `export OPENCV_ANDROID_SDK=/path/to/OpenCV-android-sdk`.

CMake then sets `CARDCV_HAS_OPENCV=1` and links `core` + `imgproc`.

### iOS

In `ios/fintech_card_core.podspec`, uncomment:

```ruby
s.dependency 'OpenCV', '~> 4.3'
s.compiler_flags = '-DCARDCV_HAS_OPENCV=1'
```

Then `cd example/ios && pod install`.

---

## Key Dart modules

| Module | Role |
|--------|------|
| `lib/src/ocr/ocr_card_scanner.dart` | Live pipeline orchestration |
| `lib/src/ocr/native_preprocessor.dart` | FFI + isolate wrapper |
| `lib/src/ocr/frame_consensus_buffer.dart` | 5-frame positional vote |
| `lib/src/ocr/pan_heuristics.dart` | Swaps, BIN, Luhn repair |
| `lib/src/ocr/ocr_parser.dart` | Regex extract + raw candidate |
| `lib/src/core/luhn.dart` | Mod-10 checksum |
| `src/cardcv.cpp` / `cardcv.h` | OpenCV C ABI |

---

## Heuristics cheat-sheet

```
substitutions:  b→6, B→8, O/D→0, I/l→1, S→5, Z→2, …
BIN fill:       9??? → 9860 (HUMO),  8??? → 8600 (UzCard)
                ?860 → 9860,         ?600 → 8600
prefix realign: faded head digit(s) shift the whole read left —
                15-digit 860…  → prepend 9  → 9860…
                14-digit 60…   → prepend 98 → 9860…
                15-digit 600…  → prepend 8  → 8600…
                (fully-resolved 98xx≠9860 / 86xx≠8600 heads are rejected
                 as shifted reads, never accepted as-is)
stroke loss:    conflicting Luhn-valid readings across passes are
                arbitrated by glyph complexity — emboss OCR loses strokes
                (7→1, 4→1, 6→5, 9→5/4, 8→3/6/0, 2→7), never adds them,
                so the complex digit wins the disagreement
Luhn repair:    exactly one `?` (or one low-confidence index) → try 0–9
```

### Multi-pass cross-checking (native ↔ Dart)

A single preprocessing pass can misread embossed digits *systematically* —
the same 7→1 on every frame — and the wrong 16-digit string passes Luhn with
≈10 % probability, defeating both the checksum and consecutive-frame voting.
Defences:

1. **Native early exit requires cross-pass agreement**: recognition returns
   early only when two *different* preprocessing passes read the same digit
   run (one pass agreeing with itself proves nothing).
2. **All PAN-bearing pass outputs are returned joined with `" ; "`** (the
   `;` breaks the Dart PAN regexes between passes) instead of a single
   "best" text.
3. **Dart arbitrates conflicts**: `OcrParser.extractAllPans` surfaces every
   Luhn-valid reading; when they disagree, `PanHeuristics.chooseUndegraded`
   picks the reading whose digits the rivals look like stroke-lost copies
   of. Unresolvable conflicts are skipped — the scanner waits for more
   frames rather than locking a guess.
