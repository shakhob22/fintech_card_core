// cardcv.h — C ABI for the fintech_card_core OpenCV pre-processing stage.
//
// Consumed from Dart via dart:ffi. Keep this header pure C so the symbol
// names are stable (no C++ mangling) on both Android (libcardcv.so) and
// iOS (statically linked into the app binary, resolved with
// DynamicLibrary.process()).
//
// Pipeline implemented by cardcv_process_frame():
//   1. Rotate the grayscale frame upright (sensor rotation).
//   2. Detect the card quad: Gaussian blur → Canny → dilate → findContours →
//      approxPolyDP, filtered by convexity, area and the ISO/IEC 7810 ID-1
//      aspect ratio (85.60 / 53.98 ≈ 1.586 ± tolerance).
//   3. warpPerspective the quad onto a flat CARDCV_OUT_W × CARDCV_OUT_H canvas.
//   4. CLAHE on the luminance channel (the input *is* luminance — the Y plane
//      of NV21 / a grayscale reduction of BGRA — which is equivalent to the
//      L channel of LAB for a single-channel image).
//   5. Optional adaptive Gaussian threshold (embossed digits vs. glare).
//   6. Optional PAN-band ROI crop (central-lower horizontal band).

#ifndef FINTECH_CARDCV_H
#define FINTECH_CARDCV_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Symbols must survive dead-code stripping on iOS (static link) and be
// visible from the stripped .so on Android.
#if defined(_WIN32)
#define CARDCV_EXPORT __declspec(dllexport)
#else
#define CARDCV_EXPORT __attribute__((visibility("default"))) __attribute__((used))
#endif

// ── Output geometry ──────────────────────────────────────────────────────────
// Warped card canvas. 1024 / 646 = 1.585 ≈ ISO ID-1 aspect ratio, and 1024 px
// width keeps ~64 px per PAN glyph — comfortably above ML Kit's ~16 px floor.
#define CARDCV_OUT_W 1024
#define CARDCV_OUT_H 646

// Central-lower band that holds the embossed / printed 16-digit PAN.
// Fractions of the warped card height.
#define CARDCV_PAN_BAND_Y0 0.48f
#define CARDCV_PAN_BAND_Y1 0.80f

// ── Processing mode flags (bitmask) ──────────────────────────────────────────
#define CARDCV_MODE_CLAHE 1      // CLAHE local contrast on the L/Y channel
#define CARDCV_MODE_THRESHOLD 2  // adaptive Gaussian threshold after CLAHE
#define CARDCV_MODE_PAN_BAND 4   // return only the PAN band ROI of the card

// ── Error codes ──────────────────────────────────────────────────────────────
#define CARDCV_OK 0
#define CARDCV_ERR_UNAVAILABLE -1  // built without OpenCV (stub)
#define CARDCV_ERR_BAD_ARGS -2
#define CARDCV_ERR_BUFFER_TOO_SMALL -3
#define CARDCV_ERR_INTERNAL -4

typedef struct {
  // 1 when a card quad was found and warped; 0 when the frame was returned
  // unwarped (caller should fall back to full-frame OCR).
  int32_t found_card;
  // Dimensions of the image written to out_buf.
  int32_t out_width;
  int32_t out_height;
  // Detected quad corners in *rotated source frame* coordinates,
  // ordered TL, TR, BR, BL as (x, y) pairs. Useful for a debug overlay.
  float quad[8];
} CardCvResult;

// Returns 1 when compiled with OpenCV, 0 for the stub build.
CARDCV_EXPORT int32_t cardcv_available(void);

// Semantic version of the native core, e.g. "1.0.0+opencv4.9".
CARDCV_EXPORT const char* cardcv_version(void);

// Process one grayscale (8-bit, single channel) camera frame.
//
//   gray             luminance plane, `stride` bytes per row, `height` rows
//   width/height     frame dimensions in pixels (pre-rotation)
//   stride           bytes per source row (>= width)
//   rotation_degrees 0 / 90 / 180 / 270 clockwise, from the camera sensor
//   mode             bitmask of CARDCV_MODE_* flags
//   out_buf          caller-allocated, capacity >= CARDCV_OUT_W * CARDCV_OUT_H
//   out_cap          capacity of out_buf in bytes
//   result           output metadata (must not be NULL)
//
// Returns CARDCV_OK or a CARDCV_ERR_* code. On CARDCV_OK the processed
// image is in out_buf as tightly packed 8-bit grayscale rows
// (result->out_width × result->out_height).
CARDCV_EXPORT int32_t cardcv_process_frame(const uint8_t* gray,
                                           int32_t width,
                                           int32_t height,
                                           int32_t stride,
                                           int32_t rotation_degrees,
                                           int32_t mode,
                                           uint8_t* out_buf,
                                           int32_t out_cap,
                                           CardCvResult* result);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // FINTECH_CARDCV_H
