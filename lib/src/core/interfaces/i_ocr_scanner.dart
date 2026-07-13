import 'package:camera/camera.dart';
import '../models/card_reader_state.dart';

/// Contract for the camera-based OCR card scanner.
abstract interface class IOcrScanner {
  /// Broadcast stream of state transitions.
  Stream<CardReaderState> get stateStream;

  /// Exposes the underlying [CameraController] so the UI layer can render
  /// a live preview without owning the controller lifecycle.
  CameraController? get cameraController;

  /// Initialize the camera and start periodic OCR captures.
  Future<void> startScan();

  /// Stop capturing and release the camera.
  Future<void> stopScan();

  /// Release all resources including the ML text-recognizer.
  Future<void> dispose();
}
