import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../core/card_reader_controller.dart';
import '../core/models/card_data.dart';
import '../core/models/card_reader_state.dart';
import '../ocr/ocr_roi.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Status enum
// ─────────────────────────────────────────────────────────────────────────────

/// The current visual phase of [CardScannerOverlay].
enum CardScannerOverlayStatus { scanning, success, error }

// ─────────────────────────────────────────────────────────────────────────────
// Theme — corner / frame styling only
// ─────────────────────────────────────────────────────────────────────────────

/// Corner-frame visual styling for [CardScannerOverlay].
///
/// Only controls the appearance of the card-frame corner accents. Content
/// widgets (title, subtitle, cancel button, etc.) are passed directly to
/// [CardScannerOverlay.show].
///
/// ### Example
/// ```dart
/// const CardScannerOverlayTheme(
///   cornerColor: Colors.cyanAccent,
///   cornerStrokeWidth: 4,
///   cornerRadius: 20,
///   cornerLength: 32,
///   cornerGap: 6,
/// )
/// ```
class CardScannerOverlayTheme {
  /// Overrides the state-driven corner colour.
  ///
  /// By default corners are white during scanning, green on success, and red
  /// on error. Setting this fixes the colour regardless of scan state.
  final Color? cornerColor;

  /// Stroke width of the corner accent lines and arc. Defaults to `3.0`.
  final double cornerStrokeWidth;

  /// Radius of the corner arc, matching the card frame's rounded corners.
  /// Defaults to `14.0`.
  final double cornerRadius;

  /// Length of each straight segment in a corner accent. Defaults to `24.0`.
  final double cornerLength;

  /// Gap (in logical pixels) between the arc endpoint and the start of the
  /// adjacent straight line. `0.0` (default) produces connected corners.
  final double cornerGap;

  const CardScannerOverlayTheme({
    this.cornerColor,
    this.cornerStrokeWidth = 3.0,
    this.cornerRadius = 14.0,
    this.cornerLength = 24.0,
    this.cornerGap = 0.0,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// Widget
// ─────────────────────────────────────────────────────────────────────────────

/// A full-screen camera overlay for OCR card scanning.
///
/// Renders the live camera preview with an ISO-7810 card-frame guide and
/// corner accents. Drives [ICardReaderController.startOcrScan] automatically
/// and returns the scanned [CardData] to the caller via [show].
///
/// ## Usage
///
/// ### Default look
/// ```dart
/// final card = await CardScannerOverlay.show(
///   context,
///   controller: controller,
/// );
/// ```
///
/// ### Custom title + subtitle
/// ```dart
/// final card = await CardScannerOverlay.show(
///   context,
///   controller: controller,
///   title: Text('Kartani skanerlash',
///       style: TextStyle(color: Colors.white, fontSize: 24,
///           fontWeight: FontWeight.bold)),
///   subtitle: Text('Kamerani kartangizga yo\'naltiring…',
///       style: TextStyle(color: Colors.white70, fontSize: 14)),
///   theme: CardScannerOverlayTheme(cornerColor: Colors.cyanAccent),
/// );
/// ```
///
/// ### Full custom top and bottom areas
/// ```dart
/// final card = await CardScannerOverlay.show(
///   context,
///   controller: controller,
///   topChild: MyBrandedHeader(),
///   bottomChild: MyActionButtons(),
/// );
/// ```
///
/// ### Custom cancel button and torch icon
/// ```dart
/// final card = await CardScannerOverlay.show(
///   context,
///   controller: controller,
///   cancelButton: TextButton(
///     onPressed: () {},               // tap is intercepted by the overlay
///     child: Text('Bekor qilish',
///         style: TextStyle(color: Colors.white)),
///   ),
///   torchIcon: Icon(Icons.lightbulb_outline, color: Colors.white),
/// );
/// ```
///
/// **Mutual-exclusivity rules (enforced via assertions):**
/// - [topChild] and ([title] / [subtitle]) cannot be set together.
/// - [bottomChild] and ([cancelButton] / [torchIcon]) cannot be set together.
class CardScannerOverlay extends StatefulWidget {
  final ICardReaderController controller;
  final CardScannerOverlayTheme theme;

  // ── Top area ───────────────────────────────────────────────────────────────

  /// Large title widget shown at the top of the screen.
  ///
  /// Cannot be set together with [topChild].
  final Widget? title;

  /// Smaller subtitle widget shown directly below [title].
  ///
  /// Cannot be set together with [topChild].
  final Widget? subtitle;

  /// Replaces the **entire** top section of the overlay.
  ///
  /// When set, [title] and [subtitle] must be `null`.
  final Widget? topChild;

  // ── Bottom area ────────────────────────────────────────────────────────────

  /// A widget that replaces the default close `IconButton`.
  ///
  /// The overlay still calls its internal cancel handler when this widget is
  /// tapped — it is wrapped in a [GestureDetector] automatically.
  ///
  /// Cannot be set together with [bottomChild].
  final Widget? cancelButton;

  /// A widget used as the icon inside the animated torch/flashlight button.
  ///
  /// Replaces the default flash icons; the animated circle container is kept.
  ///
  /// Cannot be set together with [bottomChild].
  final Widget? torchIcon;

  /// Replaces the **entire** bottom section of the overlay.
  ///
  /// When set, [cancelButton] and [torchIcon] must be `null`.
  final Widget? bottomChild;

  // ── Timing ─────────────────────────────────────────────────────────────────

  /// How long the success state is shown before the overlay auto-dismisses.
  /// Defaults to `Duration(milliseconds: 800)`.
  final Duration successDismissDelay;

  const CardScannerOverlay._({
    required this.controller,
    this.theme = const CardScannerOverlayTheme(),
    this.title,
    this.subtitle,
    this.topChild,
    this.cancelButton,
    this.torchIcon,
    this.bottomChild,
    this.successDismissDelay = const Duration(milliseconds: 800),
  })  : assert(
          topChild == null || (title == null && subtitle == null),
          'topChild is set — title and subtitle must be null.',
        ),
        assert(
          bottomChild == null || (cancelButton == null && torchIcon == null),
          'bottomChild is set — cancelButton and torchIcon must be null.',
        );

  /// Push a full-screen camera scan overlay and return the scanned [CardData],
  /// or `null` if the user dismissed before a card was detected.
  ///
  /// See the class-level doc for full usage examples.
  static Future<CardData?> show(
    BuildContext context, {
    required ICardReaderController controller,
    CardScannerOverlayTheme theme = const CardScannerOverlayTheme(),
    Widget? title,
    Widget? subtitle,
    Widget? topChild,
    Widget? cancelButton,
    Widget? torchIcon,
    Widget? bottomChild,
    Duration successDismissDelay = const Duration(milliseconds: 800),
  }) {
    return Navigator.of(context, rootNavigator: true).push<CardData>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => CardScannerOverlay._(
          controller: controller,
          theme: theme,
          title: title,
          subtitle: subtitle,
          topChild: topChild,
          cancelButton: cancelButton,
          torchIcon: torchIcon,
          bottomChild: bottomChild,
          successDismissDelay: successDismissDelay,
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
  bool _torchOn = false;
  bool _showHint = false;
  int _hintPhase = 0;
  Timer? _hintTimer;
  Size? _overlaySize;

  /// Side-light tip first (emboss / low-contrast), then torch suggestion.
  static const _sideLightHintDelay = Duration(seconds: 3);
  static const _torchHintDelay = Duration(seconds: 6);

  static const _sideLightHint = 'Yon yorug‘likda tuting';
  static const _torchHint = 'Yaltiroq yorug‘likdan uzoqroq tuting — chiroqni yoqing';

  @override
  void initState() {
    super.initState();
    _sub = widget.controller.stateStream.listen(_onState);
    widget.controller.startOcrScan();
    _hintTimer = Timer(_sideLightHintDelay, () {
      if (!mounted || _status != CardScannerOverlayStatus.scanning) return;
      setState(() {
        _showHint = true;
        _hintPhase = 0;
      });
      _hintTimer = Timer(_torchHintDelay - _sideLightHintDelay, () {
        if (!mounted || _status != CardScannerOverlayStatus.scanning) return;
        setState(() => _hintPhase = 1);
      });
    });
  }

  @override
  void dispose() {
    _hintTimer?.cancel();
    _sub?.cancel();
    widget.controller.stopOcrScan();
    super.dispose();
  }

  // ── State listener ────────────────────────────────────────────────────────

  void _onState(CardReaderState state) {
    switch (state) {
      case CardReaderScanningState():
        final ctrl = widget.controller;
        if (ctrl is CardReaderController && _camera == null) {
          if (mounted) {
            setState(() => _camera = ctrl.ocrScanner.cameraController);
            _updateScanRoi();
          }
        }

      case CardReaderSuccessState(:final data):
        _hintTimer?.cancel();
        if (mounted) {
          setState(() {
            _status = CardScannerOverlayStatus.success;
            _showHint = false;
          });
          Future.delayed(widget.successDismissDelay, () {
            if (mounted) Navigator.of(context).pop(data);
          });
        }

      case CardReaderErrorState():
        if (mounted) {
          setState(() => _status = CardScannerOverlayStatus.error);
        }

      default:
        break;
    }
  }

  void _updateScanRoi() {
    final ctrl = widget.controller;
    if (ctrl is! CardReaderController) return;
    final camera = _camera;
    final size = _overlaySize;
    if (camera == null || size == null || !camera.value.isInitialized) return;

    final cardRoi = OcrRoi.normalizedFromOverlay(
      overlaySize: size,
      cameraValue: camera.value,
      isLandscape: MediaQuery.orientationOf(context) == Orientation.landscape,
    );
    // Full card frame for PaddleOCR (PAN + expiry + name).
    ctrl.ocrScanner.setScanRoi(cardRoi);
  }

  // ── Actions ───────────────────────────────────────────────────────────────

  Future<void> _cancel() async {
    await widget.controller.stopOcrScan();
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _toggleTorch() async {
    if (_camera == null || !_camera!.value.isInitialized) return;
    final next = _torchOn ? FlashMode.off : FlashMode.torch;
    await _camera!.setFlashMode(next);
    if (mounted) setState(() => _torchOn = !_torchOn);
  }

  /// Full-bleed preview without aspect distortion.
  ///
  /// [StackFit.expand] gives children *tight* constraints, which makes
  /// [CameraPreview]'s internal [AspectRatio] fall back to the raw stack size
  /// and squash the image horizontally on portrait phones. [FittedBox] +
  /// [BoxFit.cover] restores the correct ratio and crops the overflow.
  Widget _buildCameraPreview(CameraController camera) {
    final previewAspect = camera.value.aspectRatio;
    // Mirror CameraPreview's portrait/landscape aspect handling.
    final isLandscape = MediaQuery.orientationOf(context) == Orientation.landscape;
    final aspect = isLandscape ? previewAspect : 1 / previewAspect;

    return ClipRect(
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: aspect * 1000,
          height: 1000,
          child: CameraPreview(camera),
        ),
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    return Scaffold(
      backgroundColor: Colors.black,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final nextSize = Size(constraints.maxWidth, constraints.maxHeight);
          if (_overlaySize != nextSize) {
            _overlaySize = nextSize;
            WidgetsBinding.instance.addPostFrameCallback((_) => _updateScanRoi());
          }

          return Stack(
            fit: StackFit.expand,
            children: [
              if (_camera != null && _camera!.value.isInitialized)
                Positioned.fill(child: _buildCameraPreview(_camera!))
              else
                const Center(
                  child: CircularProgressIndicator(color: Colors.white),
                ),

              CustomPaint(
                painter: _FramePainter(
                  success: _status == CardScannerOverlayStatus.success,
                  error: _status == CardScannerOverlayStatus.error,
                  cornerColor: theme.cornerColor,
                  cornerStrokeWidth: theme.cornerStrokeWidth,
                  cornerRadius: theme.cornerRadius,
                  cornerLength: theme.cornerLength,
                  cornerGap: theme.cornerGap,
                ),
              ),

              _buildTopSection(),
              _buildBottomSection(),
            ],
          );
        },
      ),
    );
  }

  Widget _buildTopSection() {
    if (widget.topChild != null) {
      return Align(
        alignment: Alignment.topLeft,
        child: SafeArea(child: widget.topChild!),
      );
    }

    final coachingHint = _showHint
        ? Text(
            _hintPhase == 0 ? _sideLightHint : _torchHint,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70, fontSize: 14),
          )
        : null;

    if (widget.title == null && widget.subtitle == null && coachingHint == null) {
      return const SizedBox.shrink();
    }

    return Align(
      alignment: Alignment.topCenter,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.title != null) widget.title!,
              if (widget.title != null &&
                  (widget.subtitle != null || coachingHint != null))
                const SizedBox(height: 6),
              if (coachingHint != null)
                coachingHint
              else if (widget.subtitle != null)
                widget.subtitle!,
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomSection() {
    if (widget.bottomChild != null) {
      return Align(
        alignment: Alignment.bottomCenter,
        child: SafeArea(child: widget.bottomChild!),
      );
    }

    final cancelWidget = widget.cancelButton != null
        ? GestureDetector(onTap: _cancel, child: widget.cancelButton)
        : IconButton(
            icon: const Icon(Icons.close, color: Colors.white),
            iconSize: 28,
            onPressed: _cancel,
          );

    return Align(
      alignment: Alignment.bottomCenter,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.only(bottom: 40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _TorchButton(
                isOn: _torchOn,
                onTap: _toggleTorch,
                iconWidget: widget.torchIcon,
              ),
              const SizedBox(height: 16),
              cancelWidget,
            ],
          ),
        ),
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

  /// Optional custom icon widget. When `null` the default flash icons are used.
  final Widget? iconWidget;

  const _TorchButton({
    required this.isOn,
    required this.onTap,
    this.iconWidget,
  });

  @override
  Widget build(BuildContext context) {
    final icon = iconWidget ??
        Icon(
          isOn ? Icons.flash_on_rounded : Icons.flash_off_rounded,
          color: isOn ? Colors.black87 : Colors.white,
          size: 26,
        );

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
        child: Center(child: icon),
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
  final Color? cornerColor;
  final double cornerStrokeWidth;
  final double cornerRadius;
  final double cornerLength;
  final double cornerGap;

  const _FramePainter({
    this.success = false,
    this.error = false,
    this.cornerColor,
    this.cornerStrokeWidth = 3.0,
    this.cornerRadius = 14.0,
    this.cornerLength = 24.0,
    this.cornerGap = 0.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final cardW = size.width * OcrRoi.frameWidthFraction;
    final cardH = cardW / OcrRoi.cardAspect; // ISO 7810 ID-1
    final left = (size.width - cardW) / 2;
    final top = (size.height - cardH) / 2;

    final rect = RRect.fromRectAndRadius(
      Rect.fromLTWH(left, top, cardW, cardH),
      Radius.circular(cornerRadius),
    );

    // Semi-transparent overlay outside the card frame.
    canvas.drawPath(
      Path.combine(
        PathOperation.difference,
        Path()..addRect(Rect.fromLTWH(0, 0, size.width, size.height)),
        Path()..addRRect(rect),
      ),
      Paint()..color = Colors.black54,
    );

    // Corner accent colour changes with scan phase unless overridden.
    final resolvedColor = cornerColor ??
        (success
            ? Colors.green.shade400
            : error
                ? Colors.red.shade400
                : Colors.white);

    final r = cornerRadius;
    final borderPaint = Paint()
      ..color = resolvedColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = cornerStrokeWidth
      ..strokeCap = StrokeCap.round;

    void drawCorner(double x, double y, double dx, double dy) {
      canvas.drawLine(
        Offset(x, y + dy * (r + cornerGap)),
        Offset(x, y + dy * (r + cornerGap + cornerLength)),
        borderPaint,
      );
      canvas.drawLine(
        Offset(x + dx * (r + cornerGap), y),
        Offset(x + dx * (r + cornerGap + cornerLength), y),
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

    drawCorner(left, top, 1, 1);
    drawCorner(left + cardW, top, -1, 1);
    drawCorner(left, top + cardH, 1, -1);
    drawCorner(left + cardW, top + cardH, -1, -1);
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
      other.success != success ||
      other.error != error ||
      other.cornerColor != cornerColor ||
      other.cornerStrokeWidth != cornerStrokeWidth ||
      other.cornerRadius != cornerRadius ||
      other.cornerLength != cornerLength ||
      other.cornerGap != cornerGap;
}
