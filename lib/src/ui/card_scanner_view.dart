import 'dart:async';
import 'dart:io' show Platform;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../core/luhn.dart';
import '../ocr/ocr_result_accumulator.dart';
import '../ocr/ocr_roi.dart';
import '../services/paddle_card_ocr_engine.dart';

/// Live camera card scanner powered by [PaddleCardOcrEngine] (on-device PaddleOCR).
///
/// Renders a camera preview with an ISO-7810 card-frame overlay, streams
/// frames through Paddle Lite OCR, and invokes [onCardScanned] once a
/// Luhn-valid 16-digit PAN is detected. Resources are
/// released automatically after a successful scan or when the widget is
/// disposed.
///
/// ### Usage
/// ```dart
/// CardScannerView(
///   onCardScanned: (pan) {
///     Navigator.pop(context, pan);
///   },
/// )
/// ```
class CardScannerView extends StatefulWidget {
  /// Called exactly once with a Luhn-valid card number.
  final ValueChanged<String> onCardScanned;

  /// Optional corner / frame styling.
  final CardScannerViewTheme theme;

  /// Title shown above the card frame (defaults to a short hint).
  final Widget? title;

  /// Subtitle under [title].
  final Widget? subtitle;

  /// Throttle between OCR attempts. Defaults to ~2.5 fps (Paddle is heavier).
  final Duration throttleInterval;

  const CardScannerView({
    super.key,
    required this.onCardScanned,
    this.theme = const CardScannerViewTheme(),
    this.title,
    this.subtitle,
    this.throttleInterval = const Duration(milliseconds: 400),
  });

  @override
  State<CardScannerView> createState() => _CardScannerViewState();
}

/// Visual styling for the card-frame overlay in [CardScannerView].
class CardScannerViewTheme {
  final Color? cornerColor;
  final double cornerStrokeWidth;
  final double cornerRadius;
  final double cornerLength;
  final double cornerGap;
  final Color scrimColor;

  const CardScannerViewTheme({
    this.cornerColor,
    this.cornerStrokeWidth = 3.0,
    this.cornerRadius = 14.0,
    this.cornerLength = 24.0,
    this.cornerGap = 0.0,
    this.scrimColor = const Color(0x8A000000),
  });
}

class _CardScannerViewState extends State<CardScannerView>
    with WidgetsBindingObserver {
  final PaddleCardOcrEngine _engine = PaddleCardOcrEngine();
  final OcrResultAccumulator _accumulator =
      OcrResultAccumulator(minFrames: 2, windowSize: 4);

  CameraController? _camera;
  CameraDescription? _description;

  bool _initializing = true;
  bool _scanning = false;
  bool _completed = false;
  bool _processing = false;
  String? _error;

  DateTime _lastOcrAt = DateTime.fromMillisecondsSinceEpoch(0);
  Size? _overlaySize;
  Rect? _scanRoi;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_bootstrap());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scanning = false;
    unawaited(_teardown());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final camera = _camera;
    if (camera == null || !camera.value.isInitialized) return;

    if (state == AppLifecycleState.inactive) {
      unawaited(_stopStream());
    } else if (state == AppLifecycleState.resumed && _scanning && !_completed) {
      unawaited(_startStream());
    }
  }

  Future<void> _bootstrap() async {
    try {
      await _engine.load();

      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        if (mounted) {
          setState(() {
            _initializing = false;
            _error = 'No cameras found on this device.';
          });
        }
        return;
      }

      _description = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      final format = Platform.isAndroid
          ? ImageFormatGroup.yuv420
          : ImageFormatGroup.bgra8888;

      final controller = CameraController(
        _description!,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: format,
      );

      await controller.initialize();
      try {
        await controller.setFocusMode(FocusMode.auto);
      } catch (_) {}
      try {
        await controller.setExposureMode(ExposureMode.auto);
      } catch (_) {}

      if (!mounted) {
        await controller.dispose();
        return;
      }

      setState(() {
        _camera = controller;
        _initializing = false;
        _scanning = true;
      });

      await _startStream();
    } catch (e) {
      if (mounted) {
        setState(() {
          _initializing = false;
          _error = 'Failed to start scanner: $e';
        });
      }
    }
  }

  Future<void> _startStream() async {
    final camera = _camera;
    if (camera == null || !camera.value.isInitialized) return;
    if (camera.value.isStreamingImages) return;
    await camera.startImageStream(_onCameraImage);
  }

  Future<void> _stopStream() async {
    final camera = _camera;
    if (camera == null) return;
    if (camera.value.isStreamingImages) {
      try {
        await camera.stopImageStream();
      } catch (_) {}
    }
  }

  bool _tornDown = false;

  Future<void> _teardown() async {
    if (_tornDown) return;
    _tornDown = true;
    await _stopStream();
    final camera = _camera;
    _camera = null;
    await camera?.dispose();
    await _engine.dispose();
  }

  void _onCameraImage(CameraImage image) {
    if (!_scanning || _completed || _processing || !_engine.isReady) return;

    final now = DateTime.now();
    if (now.difference(_lastOcrAt) < widget.throttleInterval) return;
    _lastOcrAt = now;
    _processing = true;

    unawaited(() async {
      try {
        final fields = await _engine.recognizeCameraImage(
          image,
          normalizedRoi: _scanRoi,
          rotationDegrees: _description?.sensorOrientation ?? 0,
        );
        final pan = fields?.pan;
        if (pan == null || _completed || !_scanning) return;

        _accumulator.add(pan);
        final consensus = _accumulator.accumulateVotes();
        if (consensus == null) return;
        if (consensus.length != 16) return;
        if (!Luhn.validate(consensus)) return;

        await _onSuccess(consensus);
      } catch (_) {
        // Ignore single-frame failures — keep streaming.
      } finally {
        _processing = false;
      }
    }());
  }

  Future<void> _onSuccess(String pan) async {
    if (_completed || !mounted) return;
    _completed = true;
    _scanning = false;
    await _stopStream();
    if (!mounted) return;
    widget.onCardScanned(pan);
    // Release camera / interpreter after the callback returns.
    unawaited(_teardown());
  }

  void _updateScanRoi() {
    final camera = _camera;
    final size = _overlaySize;
    if (camera == null || size == null || !camera.value.isInitialized) return;

    final cardRoi = OcrRoi.normalizedFromOverlay(
      overlaySize: size,
      cameraValue: camera.value,
      isLandscape: MediaQuery.orientationOf(context) == Orientation.landscape,
    );
    // Full card frame for Paddle (PAN + expiry + name), not digit-strip only.
    _scanRoi = cardRoi;
  }

  Widget _buildCameraPreview(CameraController camera) {
    final previewAspect = camera.value.aspectRatio;
    final isLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
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

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return ColoredBox(
        color: Colors.black,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              _error!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 14),
            ),
          ),
        ),
      );
    }

    final camera = _camera;
    final ready = camera != null && camera.value.isInitialized;

    return ColoredBox(
      color: Colors.black,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final nextSize = Size(constraints.maxWidth, constraints.maxHeight);
          if (_overlaySize != nextSize) {
            _overlaySize = nextSize;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _updateScanRoi();
            });
          }

          return Stack(
            fit: StackFit.expand,
            children: [
              if (ready)
                Positioned.fill(child: _buildCameraPreview(camera))
              else
                const Center(
                  child: CircularProgressIndicator(color: Colors.white),
                ),
              CustomPaint(
                painter: _CardFramePainter(theme: widget.theme),
              ),
              _buildTopHints(),
              if (_initializing)
                const Center(
                  child: CircularProgressIndicator(color: Colors.white),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildTopHints() {
    final title = widget.title ??
        const Text(
          'Scan your card',
          style: TextStyle(
            color: Colors.white,
            fontSize: 22,
            fontWeight: FontWeight.w600,
          ),
        );
    final subtitle = widget.subtitle ??
        const Text(
          'Align the card inside the frame',
          style: TextStyle(color: Colors.white70, fontSize: 14),
        );

    return Align(
      alignment: Alignment.topCenter,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              title,
              const SizedBox(height: 6),
              subtitle,
            ],
          ),
        ),
      ),
    );
  }
}

class _CardFramePainter extends CustomPainter {
  final CardScannerViewTheme theme;

  const _CardFramePainter({required this.theme});

  @override
  void paint(Canvas canvas, Size size) {
    final cardW = size.width * OcrRoi.frameWidthFraction;
    final cardH = cardW / OcrRoi.cardAspect;
    final left = (size.width - cardW) / 2;
    final top = (size.height - cardH) / 2;
    final r = theme.cornerRadius;

    final rect = RRect.fromRectAndRadius(
      Rect.fromLTWH(left, top, cardW, cardH),
      Radius.circular(r),
    );

    canvas.drawPath(
      Path.combine(
        PathOperation.difference,
        Path()..addRect(Rect.fromLTWH(0, 0, size.width, size.height)),
        Path()..addRRect(rect),
      ),
      Paint()..color = theme.scrimColor,
    );

    final color = theme.cornerColor ?? Colors.white;
    final borderPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = theme.cornerStrokeWidth
      ..strokeCap = StrokeCap.round;

    void drawCorner(double x, double y, double dx, double dy) {
      canvas.drawLine(
        Offset(x, y + dy * (r + theme.cornerGap)),
        Offset(x, y + dy * (r + theme.cornerGap + theme.cornerLength)),
        borderPaint,
      );
      canvas.drawLine(
        Offset(x + dx * (r + theme.cornerGap), y),
        Offset(x + dx * (r + theme.cornerGap + theme.cornerLength), y),
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
  bool shouldRepaint(_CardFramePainter other) => other.theme != theme;
}
