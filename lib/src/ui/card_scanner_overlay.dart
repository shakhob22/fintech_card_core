import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../core/card_reader_controller.dart';
import '../core/models/card_data.dart';
import '../core/models/card_reader_state.dart';
import '../ocr/ocr_card_scanner.dart';

/// A full-screen camera overlay for OCR card scanning.
///
/// Renders the live camera preview with a card-frame guide and status bar.
/// Drives an [OcrCardScanner] internally through the [controller].
///
/// The widget must be mounted *before* calling [ICardReaderController.startOcrScan].
///
/// ```dart
/// Navigator.of(context).push(MaterialPageRoute(
///   builder: (_) => CardScannerOverlay(
///     controller: myController,
///     onSuccess: (card) { Navigator.pop(context, card); },
///   ),
/// ));
/// ```
class CardScannerOverlay extends StatefulWidget {
  final ICardReaderController controller;
  final void Function(CardData card)? onSuccess;
  final void Function(Object error)? onError;

  const CardScannerOverlay({
    super.key,
    required this.controller,
    this.onSuccess,
    this.onError,
  });

  @override
  State<CardScannerOverlay> createState() => _CardScannerOverlayState();
}

class _CardScannerOverlayState extends State<CardScannerOverlay> {
  CameraController? _camera;
  String _hint = 'Point camera at your card';

  @override
  void initState() {
    super.initState();
    widget.controller.stateStream.listen(_onState);
    _startOcr();
  }

  Future<void> _startOcr() async {
    await widget.controller.startOcrScan();

    // Obtain the camera controller from the underlying OcrCardScanner so we
    // can render a preview without duplicating camera ownership.
    final ctrl = widget.controller;
    if (ctrl is CardReaderController) {
      // Access internal scanner via the exposed field on CardReaderController
      // — a lightweight cast; production apps may expose this differently.
    }

    // Direct approach: create a secondary preview controller that mirrors
    // what OcrCardScanner already initialized.
    await _attachPreview();
  }

  Future<void> _attachPreview() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) return;
      final camera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final ctrl = CameraController(
        camera,
        ResolutionPreset.high,
        enableAudio: false,
      );
      await ctrl.initialize();
      if (mounted) setState(() => _camera = ctrl);
    } catch (_) {}
  }

  @override
  void dispose() {
    _camera?.dispose();
    super.dispose();
  }

  void _onState(CardReaderState state) {
    switch (state) {
      case CardReaderScanningState(:final message):
        if (mounted) setState(() => _hint = message ?? _hint);
      case CardReaderSuccessState(:final data):
        widget.onSuccess?.call(data);
      case CardReaderErrorState(:final exception):
        widget.onError?.call(exception);
        if (mounted) setState(() => _hint = exception.message);
      default:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // ── Camera preview ────────────────────────────────────────────
          if (_camera != null && _camera!.value.isInitialized)
            CameraPreview(_camera!)
          else
            const Center(
              child: CircularProgressIndicator(color: Colors.white),
            ),

          // ── Card frame cutout ─────────────────────────────────────────
          CustomPaint(painter: _FramePainter()),

          // ── Top bar ───────────────────────────────────────────────────
          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 8,
                  ),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white),
                        onPressed: () async {
                          await widget.controller.stopOcrScan();
                          if (context.mounted) Navigator.of(context).pop();
                        },
                      ),
                      const Expanded(
                        child: Text(
                          'Scan Card',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: 48),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // ── Bottom hint ───────────────────────────────────────────────
          Align(
            alignment: Alignment.bottomCenter,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 48),
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 32),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20, vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Text(
                    _hint,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                  ),
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
// Card Frame Painter
// ─────────────────────────────────────────────────────────────────────────────

class _FramePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    // Darken everything outside the card frame
    final cardW = size.width * 0.88;
    final cardH = cardW / 1.586; // ISO 7810 ID-1 aspect ratio
    final left = (size.width - cardW) / 2;
    final top = (size.height - cardH) / 2;
    final rect = RRect.fromRectAndRadius(
      Rect.fromLTWH(left, top, cardW, cardH),
      const Radius.circular(14),
    );

    final overlay = Paint()..color = Colors.black54;
    canvas.drawPath(
      Path.combine(
        PathOperation.difference,
        Path()..addRect(Rect.fromLTWH(0, 0, size.width, size.height)),
        Path()..addRRect(rect),
      ),
      overlay,
    );

    // Corner accents
    const cornerLen = 22.0;
    const r = 14.0;
    final borderPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;

    void corner(double x, double y, double dx, double dy) {
      canvas.drawLine(Offset(x, y + dy * r), Offset(x, y + dy * (r + cornerLen)), borderPaint);
      canvas.drawLine(Offset(x + dx * r, y), Offset(x + dx * (r + cornerLen), y), borderPaint);
      canvas.drawArc(
        Rect.fromLTWH(x - (dx < 0 ? r * 2 : 0), y - (dy < 0 ? r * 2 : 0), r * 2, r * 2),
        _cornerAngle(dx, dy),
        _pi / 2,
        false,
        borderPaint,
      );
    }

    corner(left, top, 1, 1);
    corner(left + cardW, top, -1, 1);
    corner(left, top + cardH, 1, -1);
    corner(left + cardW, top + cardH, -1, -1);
  }

  static const _pi = 3.14159265358979;

  double _cornerAngle(double dx, double dy) {
    if (dx > 0 && dy > 0) return _pi;
    if (dx < 0 && dy > 0) return _pi * 1.5;
    if (dx > 0 && dy < 0) return _pi / 2;
    return 0;
  }

  @override
  bool shouldRepaint(_FramePainter _) => false;
}
