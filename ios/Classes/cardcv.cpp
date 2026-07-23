// Relay file — standard Flutter FFI plugin pattern.
//
// CocoaPods only compiles sources under ios/Classes, but the cardcv core is
// shared with Android, so it lives in the plugin-root src/ directory. This
// file pulls it into the iOS build.
//
// By default the stub flavour is compiled (CARDCV_HAS_OPENCV is undefined →
// 0) so the plugin builds with zero extra dependencies. To enable the full
// OpenCV pipeline, see doc/OCR_PIPELINE.md — in short: add the free
// `OpenCV` pod to the podspec and define CARDCV_HAS_OPENCV=1.
#include "../../src/cardcv.cpp"
