import 'dart:ui' show Rect, Size;

import 'package:camera/camera.dart';

/// Maps the on-screen ISO-7810 card-frame guide to a normalized ROI in
/// camera-image coordinates (0–1), matching the overlay's [BoxFit.cover]
/// preview layout.
abstract final class OcrRoi {
  /// Card-frame width as a fraction of the overlay / paint size.
  static const frameWidthFraction = 0.88;

  /// ISO 7810 ID-1 aspect ratio (width / height).
  static const cardAspect = 1.586;

  /// PAN digit strip inside the card frame, as fractions of the card rect.
  ///
  /// `Rect.fromLTRB(left, top, right, bottom)` — height must be > 0
  /// (`0.58 - 0.42 = 0.16`) so the first digits are not clipped.
  static const panBandLtrb = Rect.fromLTRB(0.08, 0.42, 0.92, 0.58);

  /// Screen-space card frame rect for an overlay of [overlaySize].
  static Rect screenFrame(Size overlaySize) {
    final cardW = overlaySize.width * frameWidthFraction;
    final cardH = cardW / cardAspect;
    final left = (overlaySize.width - cardW) / 2;
    final top = (overlaySize.height - cardH) / 2;
    return Rect.fromLTWH(left, top, cardW, cardH);
  }

  /// Display aspect used by the overlay preview (portrait inverts sensor ratio).
  static double displayAspect(CameraValue cameraValue, {required bool isLandscape}) {
    final previewAspect = cameraValue.aspectRatio;
    return isLandscape ? previewAspect : 1 / previewAspect;
  }

  /// Normalized ROI (left, top, width, height in 0–1) relative to the camera
  /// image, or `null` when the preview size is not yet available.
  ///
  /// Uses the same [BoxFit.cover] math as the card scanner overlay preview:
  /// the preview is scaled uniformly to fill the screen and excess is cropped.
  static Rect? normalizedFromOverlay({
    required Size overlaySize,
    required CameraValue cameraValue,
    bool isLandscape = false,
  }) {
    if (!cameraValue.isInitialized || cameraValue.previewSize == null) {
      return null;
    }

    final frame = screenFrame(overlaySize);
    final aspect = displayAspect(cameraValue, isLandscape: isLandscape);
    final screenAspect = overlaySize.width / overlaySize.height;

    late final double displayW;
    late final double displayH;
    late final double offsetX;
    late final double offsetY;

    if (screenAspect > aspect) {
      // Screen wider than preview → cover by width; crop top/bottom.
      displayW = overlaySize.width;
      displayH = displayW / aspect;
      offsetX = 0;
      offsetY = (overlaySize.height - displayH) / 2;
    } else {
      // Screen taller → cover by height; crop left/right.
      displayH = overlaySize.height;
      displayW = displayH * aspect;
      offsetX = (overlaySize.width - displayW) / 2;
      offsetY = 0;
    }

    final left = ((frame.left - offsetX) / displayW).clamp(0.0, 1.0);
    final top = ((frame.top - offsetY) / displayH).clamp(0.0, 1.0);
    final right = ((frame.right - offsetX) / displayW).clamp(0.0, 1.0);
    final bottom = ((frame.bottom - offsetY) / displayH).clamp(0.0, 1.0);

    final w = right - left;
    final h = bottom - top;
    if (w <= 0.05 || h <= 0.05) return null;

    return Rect.fromLTRB(left, top, right, bottom);
  }

  /// PAN digit band within a full-card [cardRoi] (normalized camera space).
  ///
  /// Uses fixed card-relative [panBandLtrb] so the crop has real vertical
  /// extent (not a zero-height line) and includes padding around the digits.
  static Rect panBand(Rect cardRoi) {
    final b = panBandLtrb;
    return _band(
      cardRoi,
      leftFrac: b.left,
      topFrac: b.top,
      widthFrac: b.right - b.left,
      heightFrac: b.bottom - b.top,
    );
  }

  /// Ensures [roi] is a digits-only strip.
  ///
  /// If [roi] already looks like a PAN band (aspect ≥ 4), it is returned
  /// unchanged. Otherwise it is treated as a full-card frame and narrowed
  /// with [panBand].
  static Rect digitStripRoi(Rect roi) {
    final h = roi.height;
    if (h <= 0) return panBand(roi);
    final aspect = roi.width / h;
    if (aspect >= 4.0) return roi;
    return panBand(roi);
  }

  /// Expiry band within a full-card [cardRoi] (normalized camera space).
  ///
  /// Right-centre strip covering VALID THRU / EXP dates on most layouts.
  static Rect expiryBand(Rect cardRoi) {
    return _band(
      cardRoi,
      leftFrac: 0.40,
      topFrac: 0.40,
      widthFrac: 0.52,
      heightFrac: 0.35,
    );
  }

  static Rect _band(
    Rect cardRoi, {
    required double leftFrac,
    required double topFrac,
    required double widthFrac,
    required double heightFrac,
  }) {
    final left = cardRoi.left + cardRoi.width * leftFrac;
    final top = cardRoi.top + cardRoi.height * topFrac;
    final width = cardRoi.width * widthFrac;
    final height = cardRoi.height * heightFrac;
    return Rect.fromLTWH(left, top, width, height);
  }
}
