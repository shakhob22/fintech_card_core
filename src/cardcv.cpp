// cardcv.cpp — OpenCV pre-processing core for fintech_card_core.
//
// Build modes:
//   CARDCV_HAS_OPENCV=1 → full pipeline (requires OpenCV core + imgproc).
//   CARDCV_HAS_OPENCV=0 → stub; every call reports CARDCV_ERR_UNAVAILABLE and
//                         the Dart layer silently falls back to the existing
//                         Kotlin / Swift multi-pass preprocessing. This keeps
//                         the plugin buildable for consumers who have not
//                         installed the OpenCV SDK.

#include "cardcv.h"

#ifndef CARDCV_HAS_OPENCV
#define CARDCV_HAS_OPENCV 0
#endif

#if CARDCV_HAS_OPENCV

#include <opencv2/core.hpp>
#include <opencv2/imgproc.hpp>

#include <algorithm>
#include <array>
#include <cstring>
#include <vector>

namespace {

// ── Geometry helpers ─────────────────────────────────────────────────────────

// Order 4 corners as TL, TR, BR, BL.
// TL has the smallest x+y, BR the largest; TR has the smallest y−x,
// BL the largest. Classic and robust for near-axis-aligned card quads.
std::array<cv::Point2f, 4> orderQuad(const std::vector<cv::Point2f>& pts) {
  std::array<cv::Point2f, 4> out{};
  float minSum = 1e30f, maxSum = -1e30f, minDiff = 1e30f, maxDiff = -1e30f;
  for (const auto& p : pts) {
    const float sum = p.x + p.y;
    const float diff = p.y - p.x;
    if (sum < minSum) { minSum = sum; out[0] = p; }   // TL
    if (diff < minDiff) { minDiff = diff; out[1] = p; } // TR
    if (sum > maxSum) { maxSum = sum; out[2] = p; }   // BR
    if (diff > maxDiff) { maxDiff = diff; out[3] = p; } // BL
  }
  return out;
}

float sideLength(const cv::Point2f& a, const cv::Point2f& b) {
  const float dx = a.x - b.x;
  const float dy = a.y - b.y;
  return std::sqrt(dx * dx + dy * dy);
}

// ── Card quad detection ──────────────────────────────────────────────────────
//
// Runs on a ≤480 px copy for speed (Canny + contours scale ~linearly with
// pixel count), then maps the winning quad back to full resolution.
//
// Filters:
//   * ≥ 12 % of the frame area (rejects text blocks / logos)
//   * exactly 4 vertices after approxPolyDP, convex
//   * aspect ratio within [1.30, 1.90] around the ISO ID-1 ratio 1.586
//     (loose on purpose: perspective skew distorts the observed ratio)
bool detectCardQuad(const cv::Mat& gray, std::array<cv::Point2f, 4>& quad) {
  const int longSide = std::max(gray.cols, gray.rows);
  const float scale = longSide > 480 ? 480.0f / longSide : 1.0f;

  cv::Mat small;
  if (scale < 1.0f) {
    cv::resize(gray, small, cv::Size(), scale, scale, cv::INTER_AREA);
  } else {
    small = gray;
  }

  cv::Mat blurred, edges;
  cv::GaussianBlur(small, blurred, cv::Size(5, 5), 0);
  cv::Canny(blurred, edges, 60, 180);
  // Close single-pixel gaps in the card border caused by glare highlights.
  cv::dilate(edges, edges,
             cv::getStructuringElement(cv::MORPH_RECT, cv::Size(3, 3)));

  std::vector<std::vector<cv::Point>> contours;
  cv::findContours(edges, contours, cv::RETR_EXTERNAL, cv::CHAIN_APPROX_SIMPLE);

  const double frameArea = static_cast<double>(small.cols) * small.rows;
  double bestArea = 0.0;
  bool found = false;

  for (const auto& contour : contours) {
    const double area = cv::contourArea(contour);
    if (area < frameArea * 0.12) continue;

    std::vector<cv::Point> approx;
    const double peri = cv::arcLength(contour, true);
    cv::approxPolyDP(contour, approx, 0.02 * peri, true);
    if (approx.size() != 4 || !cv::isContourConvex(approx)) continue;

    std::vector<cv::Point2f> ptsF(approx.begin(), approx.end());
    auto ordered = orderQuad(ptsF);

    const float wTop = sideLength(ordered[0], ordered[1]);
    const float wBottom = sideLength(ordered[3], ordered[2]);
    const float hLeft = sideLength(ordered[0], ordered[3]);
    const float hRight = sideLength(ordered[1], ordered[2]);
    const float w = std::max(wTop, wBottom);
    const float h = std::max(hLeft, hRight);
    if (w < 1.0f || h < 1.0f) continue;

    const float aspect = std::max(w, h) / std::min(w, h);
    if (aspect < 1.30f || aspect > 1.90f) continue;

    if (area > bestArea) {
      bestArea = area;
      quad = ordered;
      found = true;
    }
  }

  if (found && scale < 1.0f) {
    const float inv = 1.0f / scale;
    for (auto& p : quad) {
      p.x *= inv;
      p.y *= inv;
    }
  }
  return found;
}

// ── Enhancement ──────────────────────────────────────────────────────────────

// CLAHE on the luminance channel. The input is already the Y plane, which for
// a single-channel image is equivalent to running CLAHE on the L channel of a
// LAB conversion — without paying for two cvtColor round trips per frame.
// clipLimit 3.0 lifts digits on dark / same-hue backgrounds while the limit
// prevents glare speckle from being amplified into noise.
void applyClahe(cv::Mat& img) {
  static thread_local cv::Ptr<cv::CLAHE> clahe =
      cv::createCLAHE(3.0, cv::Size(8, 8));
  clahe->apply(img, img);
}

// Adaptive Gaussian threshold: each pixel is compared against a Gaussian
// weighted mean of its 25×25 neighbourhood, so a specular highlight only
// raises the local threshold instead of blowing out the whole card.
void applyAdaptiveThreshold(cv::Mat& img) {
  cv::adaptiveThreshold(img, img, 255, cv::ADAPTIVE_THRESH_GAUSSIAN_C,
                        cv::THRESH_BINARY, 25, 9);
  // Remove salt-and-pepper speckle left by emboss texture.
  cv::medianBlur(img, img, 3);
}

}  // namespace

extern "C" {

CARDCV_EXPORT int32_t cardcv_available(void) { return 1; }

CARDCV_EXPORT const char* cardcv_version(void) {
  return "1.0.0+opencv" CV_VERSION;
}

CARDCV_EXPORT int32_t cardcv_process_frame(const uint8_t* gray,
                                           int32_t width,
                                           int32_t height,
                                           int32_t stride,
                                           int32_t rotation_degrees,
                                           int32_t mode,
                                           uint8_t* out_buf,
                                           int32_t out_cap,
                                           CardCvResult* result) {
  if (gray == nullptr || out_buf == nullptr || result == nullptr ||
      width < 32 || height < 32 || stride < width) {
    return CARDCV_ERR_BAD_ARGS;
  }
  if (out_cap < CARDCV_OUT_W * CARDCV_OUT_H) {
    return CARDCV_ERR_BUFFER_TOO_SMALL;
  }

  std::memset(result, 0, sizeof(CardCvResult));

  try {
    // Wrap the caller's buffer without copying, then rotate upright.
    cv::Mat src(height, width, CV_8UC1, const_cast<uint8_t*>(gray), stride);
    cv::Mat upright;
    switch (((rotation_degrees % 360) + 360) % 360) {
      case 90:
        cv::rotate(src, upright, cv::ROTATE_90_CLOCKWISE);
        break;
      case 180:
        cv::rotate(src, upright, cv::ROTATE_180);
        break;
      case 270:
        cv::rotate(src, upright, cv::ROTATE_90_COUNTERCLOCKWISE);
        break;
      default:
        upright = src.clone();  // clone: src memory belongs to the caller
        break;
    }

    // ── Phase 1.1: perspective correction ──────────────────────────────────
    std::array<cv::Point2f, 4> quad{};
    const bool found = detectCardQuad(upright, quad);
    if (!found) {
      // No confident quad — tell Dart to fall back to full-frame OCR rather
      // than warping garbage (a mis-warp is worse than no warp).
      result->found_card = 0;
      return CARDCV_OK;
    }

    for (int i = 0; i < 4; i++) {
      result->quad[i * 2] = quad[i].x;
      result->quad[i * 2 + 1] = quad[i].y;
    }

    const cv::Point2f dst[4] = {
        {0.0f, 0.0f},
        {static_cast<float>(CARDCV_OUT_W - 1), 0.0f},
        {static_cast<float>(CARDCV_OUT_W - 1),
         static_cast<float>(CARDCV_OUT_H - 1)},
        {0.0f, static_cast<float>(CARDCV_OUT_H - 1)},
    };
    const cv::Mat m = cv::getPerspectiveTransform(quad.data(), dst);

    cv::Mat card;
    cv::warpPerspective(upright, card, m,
                        cv::Size(CARDCV_OUT_W, CARDCV_OUT_H),
                        cv::INTER_LINEAR, cv::BORDER_REPLICATE);

    // ── Phase 1.2: glare & contrast normalisation ──────────────────────────
    if (mode & CARDCV_MODE_CLAHE) applyClahe(card);
    if (mode & CARDCV_MODE_THRESHOLD) applyAdaptiveThreshold(card);

    // ── Phase 1.3: PAN band ROI ────────────────────────────────────────────
    if (mode & CARDCV_MODE_PAN_BAND) {
      const int y0 = static_cast<int>(CARDCV_OUT_H * CARDCV_PAN_BAND_Y0);
      const int y1 = static_cast<int>(CARDCV_OUT_H * CARDCV_PAN_BAND_Y1);
      card = card.rowRange(y0, y1);
    }

    // Tightly packed copy-out.
    result->found_card = 1;
    result->out_width = card.cols;
    result->out_height = card.rows;
    for (int row = 0; row < card.rows; row++) {
      std::memcpy(out_buf + static_cast<size_t>(row) * card.cols,
                  card.ptr<uint8_t>(row), card.cols);
    }
    return CARDCV_OK;
  } catch (...) {
    return CARDCV_ERR_INTERNAL;
  }
}

}  // extern "C"

#else  // !CARDCV_HAS_OPENCV — stub build

extern "C" {

CARDCV_EXPORT int32_t cardcv_available(void) { return 0; }

CARDCV_EXPORT const char* cardcv_version(void) { return "1.0.0+stub"; }

CARDCV_EXPORT int32_t cardcv_process_frame(const uint8_t* gray,
                                           int32_t width,
                                           int32_t height,
                                           int32_t stride,
                                           int32_t rotation_degrees,
                                           int32_t mode,
                                           uint8_t* out_buf,
                                           int32_t out_cap,
                                           CardCvResult* result) {
  (void)gray;
  (void)width;
  (void)height;
  (void)stride;
  (void)rotation_degrees;
  (void)mode;
  (void)out_buf;
  (void)out_cap;
  (void)result;
  return CARDCV_ERR_UNAVAILABLE;
}

}  // extern "C"

#endif  // CARDCV_HAS_OPENCV
