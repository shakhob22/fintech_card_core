import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../core/card_reader_controller.dart';
import '../core/models/card_data.dart';
import '../core/models/card_reader_state.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Status enum
// ─────────────────────────────────────────────────────────────────────────────

/// The current visual phase of [CardScannerOverlay].
///
/// Passed to the state so the frame painter and status badge can adapt
/// their colours to each phase.
enum CardScannerOverlayStatus { scanning, success, error }

// ─────────────────────────────────────────────────────────────────────────────
// Theme / customisation
// ─────────────────────────────────────────────────────────────────────────────

/// Visual and textual customisation for [CardScannerOverlay].
///
/// All properties are optional — omit any to keep the built-in default.
///
/// ### Minimal Uzbek localisation example
/// ```dart
/// const CardScannerOverlayTheme(
///   title:          'Kartani skanerlash',
///   subtitle:       'Kamerani kartangizga yo\'naltiring…',
///   initialMessage: 'Kamerani kartangizga yo\'naltiring…',
///   successMessage: 'Karta muvaffaqiyatli o\'qildi!',
///   cancelLabel:    'Bekor qilish',
/// )
/// ```
///
/// ### With retry on error
/// ```dart
/// const CardScannerOverlayTheme(
///   showRetryOnError: true,
///   retryLabel: 'Qayta urinish',
/// )
/// ```
class CardScannerOverlayTheme {
  /// Large title shown at the very top of the screen (default: `'Scan Card'`).
  final String title;

  /// Smaller subtitle shown directly below [title]
  /// (default: `'Point the camera at your card'`).
  final String subtitle;

  /// Body message shown as soon as the overlay opens
  /// (default: `'Point the camera at your card'`).
  final String initialMessage;

  /// Label for the close / cancel button (default: `'Cancel'`).
  final String cancelLabel;

  /// Label for the retry button shown on error when [showRetryOnError] is
  /// `true` (default: `'Try Again'`).
  final String retryLabel;

  /// When `true` a **Try Again** button is shown on error below the status
  /// badge. Defaults to `false`.
  final bool showRetryOnError;

  /// How long the success state is displayed before the overlay auto-dismisses.
  /// Defaults to `Duration(milliseconds: 800)`.
  final Duration successDismissDelay;

  const CardScannerOverlayTheme({
    this.title = 'Scan Card',
    this.subtitle = 'Point the camera at your card',
    this.initialMessage = 'Point the camera at your card',
    this.cancelLabel = 'Cancel',
    this.retryLabel = 'Try Again',
    this.showRetryOnError = false,
    this.successDismissDelay = const Duration(milliseconds: 800),
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// Widget
// ─────────────────────────────────────────────────────────────────────────────

/// A full-screen camera overlay for OCR card scanning.
///
/// Renders the live camera preview with an ISO-7810 card-frame guide and a
/// status badge. Drives [ICardReaderController.startOcrScan] automatically and
/// returns the scanned [CardData] to the caller via [show].
///
/// Uses the **same** [CameraController] that [OcrCardScanner] initialises
/// internally — no secondary camera resource is created.
///
/// ## Usage
///
/// ### 1 — Default look
/// ```dart
/// final card = await CardScannerOverlay.show(context, controller: controller);
/// if (card != null) print(card.maskedPan);
/// ```
///
/// ### 2 — Custom-themed overlay
/// ```dart
/// final card = await CardScannerOverlay.show(
///   context,
///   controller: controller,
///   theme: const CardScannerOverlayTheme(
///     title:          'Kartani skanerlash',
///     initialMessage: 'Kamerani kartangizga yo\'naltiring…',
///     successMessage: 'Karta muvaffaqiyatli o\'qildi!',
///     cancelLabel:    'Bekor qilish',
///     showRetryOnError: true,
///   ),
/// );
/// ```
///
/// ### 3 — Headless (no built-in UI)
/// ```dart
/// controller.stateStream.listen((state) {
///   switch (state) {
///     case CardReaderScanningState(): /* show your own UI */ break;
///     case CardReaderSuccessState(:final data): /* use data */ break;
///     default: break;
///   }
/// });
/// await controller.startOcrScan();
/// ```
class CardScannerOverlay extends StatefulWidget {
  final ICardReaderController controller;
  final CardScannerOverlayTheme theme;

  const CardScannerOverlay._({
    required this.controller,
    required this.theme,
  });

  /// Push a full-screen camera scan overlay and return the scanned [CardData],
  /// or `null` if the user dismissed before a card was detected.
  ///
  /// Pass a [theme] to customise labels, colours, and behaviour.
  static Future<CardData?> show(
    BuildContext context, {
    required ICardReaderController controller,
    CardScannerOverlayTheme theme = const CardScannerOverlayTheme(),
  }) {
    return Navigator.of(context, rootNavigator: true).push<CardData>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => CardScannerOverlay._(
          controller: controller,
          theme: theme,
        ),
      ),
    );
  }

  @override
  State<CardScannerOverlay> createState() => _CardScannerOverlayState();
}

class _CardScannerOverlayState extends State<CardScannerOverlay> {
  StreamSubscription<CardReaderState>? _sub;
  CameraController? _camera;
  CardScannerOverlayStatus _status = CardScannerOverlayStatus.scanning;
  // String _message = '';
  bool _torchOn = false;

  CardScannerOverlayTheme get _theme => widget.theme;

  @override
  void initState() {
    super.initState();
    // _message = _theme.initialMessage;
    _sub = widget.controller.stateStream.listen(_onState);
    widget.controller.startOcrScan();
  }

  @override
  void dispose() {
    _sub?.cancel();
    // Always release the camera when the overlay is removed from the tree —
    // this covers the back-button case, not just the explicit cancel tap.
    widget.controller.stopOcrScan();
    super.dispose();
  }

  // ── State listener ────────────────────────────────────────────────────────

  void _onState(CardReaderState state) {
    switch (state) {
      case CardReaderScanningState(:final message):
        // The scanner has initialised the camera — borrow its CameraController
        // so we can display a preview without opening a second camera stream.
        final ctrl = widget.controller;
        if (ctrl is CardReaderController && _camera == null) {
          if (mounted) {
            setState(() {
              _camera = ctrl.ocrScanner.cameraController;
              // _message = message ?? _message;
            });
          }
        } else if (mounted) {
          // setState(() => _message = message ?? _message);
        }

      case CardReaderSuccessState(:final data):
        if (mounted) {
          setState(() {
            _status = CardScannerOverlayStatus.success;
            // _message = _theme.successMessage;
          });
          Future.delayed(_theme.successDismissDelay, () {
            if (mounted) Navigator.of(context).pop(data);
          });
        }

      case CardReaderErrorState(:final exception):
        if (mounted) {
          setState(() {
            _status = CardScannerOverlayStatus.error;
            // _message = exception.message;
          });
        }

      default:
        break;
    }
  }

  // ── Actions ───────────────────────────────────────────────────────────────

  Future<void> _cancel() async {
    await widget.controller.stopOcrScan();
    if (mounted) Navigator.of(context).pop();
  }

  void _retry() {
    setState(() {
      _status = CardScannerOverlayStatus.scanning;
      // _message = _theme.initialMessage;
      _camera = null;
      _torchOn = false;
    });
    widget.controller.startOcrScan();
  }

  Future<void> _toggleTorch() async {
    if (_camera == null || !_camera!.value.isInitialized) return;
    final next = _torchOn ? FlashMode.off : FlashMode.torch;
    await _camera!.setFlashMode(next);
    if (mounted) setState(() => _torchOn = !_torchOn);
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // ── Camera preview or loading spinner ────────────────────────────
          if (_camera != null && _camera!.value.isInitialized)
            CameraPreview(_camera!)
          else
            const Center(
              child: CircularProgressIndicator(color: Colors.white),
            ),

          // ── Card-frame cutout + corner accents ───────────────────────────
          CustomPaint(
            painter: _FramePainter(
              success: _status == CardScannerOverlayStatus.success,
              error: _status == CardScannerOverlayStatus.error,
            ),
          ),

          // ── Top bar: title + subtitle ─────────────────────────────────
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _theme.title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.2,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _theme.subtitle,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 14,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ── Bottom controls: torch + close ────────────────────────────────
          Align(
            alignment: Alignment.bottomCenter,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 40),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Torch / flashlight toggle
                    _TorchButton(
                      isOn: _torchOn,
                      onTap: _toggleTorch,
                    ),
                    const SizedBox(height: 16),
                    // Close button
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white),
                      iconSize: 28,
                      onPressed: _cancel,
                    ),
                    if (_status == CardScannerOverlayStatus.error &&
                        _theme.showRetryOnError) ...[
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        onPressed: _retry,
                        icon: const Icon(Icons.refresh),
                        label: Text(_theme.retryLabel),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

}

// ─────────────────────────────────────────────────────────────────────────────
// Torch Button
// ─────────────────────────────────────────────────────────────────────────────

class _TorchButton extends StatelessWidget {
  final bool isOn;
  final VoidCallback onTap;

  const _TorchButton({required this.isOn, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: isOn ? Colors.white : Colors.white24,
        ),
        child: Icon(
          isOn ? Icons.flash_on_rounded : Icons.flash_off_rounded,
          color: isOn ? Colors.black87 : Colors.white,
          size: 26,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Card Frame Painter
// ─────────────────────────────────────────────────────────────────────────────

class _FramePainter extends CustomPainter {
  final bool success;
  final bool error;

  const _FramePainter({this.success = false, this.error = false});

  @override
  void paint(Canvas canvas, Size size) {
    // Semi-transparent overlay outside the card frame.
    final cardW = size.width * 0.88;
    final cardH = cardW / 1.586; // ISO 7810 ID-1 aspect ratio
    final left = (size.width - cardW) / 2;
    final top = (size.height - cardH) / 2;

    final rect = RRect.fromRectAndRadius(
      Rect.fromLTWH(left, top, cardW, cardH),
      const Radius.circular(14),
    );

    canvas.drawPath(
      Path.combine(
        PathOperation.difference,
        Path()..addRect(Rect.fromLTWH(0, 0, size.width, size.height)),
        Path()..addRRect(rect),
      ),
      Paint()..color = Colors.black54,
    );

    // Corner accent colour changes with scan phase.
    final cornerColor = success
        ? Colors.green.shade400
        : error
            ? Colors.red.shade400
            : Colors.white;

    const cornerLen = 24.0;
    const r = 14.0;
    final borderPaint = Paint()
      ..color = cornerColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;

    void corner(double x, double y, double dx, double dy) {
      canvas.drawLine(
        Offset(x, y + dy * r),
        Offset(x, y + dy * (r + cornerLen)),
        borderPaint,
      );
      canvas.drawLine(
        Offset(x + dx * r, y),
        Offset(x + dx * (r + cornerLen), y),
        borderPaint,
      );
      canvas.drawArc(
        Rect.fromLTWH(
          x - (dx < 0 ? r * 2 : 0),
          y - (dy < 0 ? r * 2 : 0),
          r * 2,
          r * 2,
        ),
        _cornerAngle(dx, dy),
        _kHalfPi,
        false,
        borderPaint,
      );
    }

    corner(left, top, 1, 1);
    corner(left + cardW, top, -1, 1);
    corner(left, top + cardH, 1, -1);
    corner(left + cardW, top + cardH, -1, -1);
  }

  static const _kHalfPi = 3.14159265358979 / 2;

  double _cornerAngle(double dx, double dy) {
    if (dx > 0 && dy > 0) return 3.14159265358979;
    if (dx < 0 && dy > 0) return 3.14159265358979 * 1.5;
    if (dx > 0 && dy < 0) return 3.14159265358979 / 2;
    return 0;
  }

  @override
  bool shouldRepaint(_FramePainter other) =>
      other.success != success || other.error != error;
}
