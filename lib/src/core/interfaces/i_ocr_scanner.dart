import 'dart:ui' show Rect;

import 'package:camera/camera.dart';
import '../models/card_reader_state.dart';

/// Contract for the camera-based OCR card scanner.
abstract interface class IOcrScanner {
  /// Broadcast stream of state transitions.
  Stream<CardReaderState> get stateStream;

  /// Exposes the underlying [CameraController] so the UI layer can render
  /// a live preview without owning the controller lifecycle.
  CameraController? get cameraController;

  /// Normalized card-frame ROI in camera-image coordinates (0–1), or `null`
  /// to OCR the full frame. Updated by the overlay as layout settles.
  void setScanRoi(Rect? normalizedRoi);

  /// Initialize the camera and start the live OCR image stream.
  Future<void> startScan();

  /// Stop capturing and release the camera.
  Future<void> stopScan();

  /// Release all resources including the OCR engine.
  Future<void> dispose();
}
