import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/card_reader_controller.dart';
import '../core/models/card_data.dart';
import '../core/models/card_reader_state.dart';

/// A pre-built bottom-sheet dialog that drives an NFC card scan.
///
/// Shows an animated NFC icon and live status messages while the
/// [ICardReaderController] scans. Dismisses automatically on success.
///
/// ```dart
/// final card = await NfcScanDialog.show(context, controller: controller);
/// ```
class NfcScanDialog extends StatefulWidget {
  final ICardReaderController controller;

  const NfcScanDialog._({required this.controller});

  /// Show the NFC scan dialog and return the scanned [CardData], or `null`
  /// if the user dismissed it before a card was detected.
  static Future<CardData?> show(
    BuildContext context, {
    required ICardReaderController controller,
  }) {
    return showModalBottomSheet<CardData>(
      context: context,
      isDismissible: true,
      useRootNavigator: true,
      backgroundColor: Colors.transparent,
      builder: (_) => NfcScanDialog._(controller: controller),
    );
  }

  @override
  State<NfcScanDialog> createState() => _NfcScanDialogState();
}

class _NfcScanDialogState extends State<NfcScanDialog>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;
  StreamSubscription<CardReaderState>? _sub;
  String _message = 'Hold your card near the device…';
  bool _success = false;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);

    _sub = widget.controller.stateStream.listen(_onState);
    widget.controller.startNfcScan();
  }

  @override
  void dispose() {
    _pulse.dispose();
    _sub?.cancel();
    super.dispose();
  }

  void _onState(CardReaderState state) {
    switch (state) {
      case CardReaderScanningState(:final message):
        if (mounted) setState(() => _message = message ?? _message);
      case CardReaderSuccessState(:final data):
        setState(() {
          _success = true;
          _message = 'Card read successfully!';
        });
        _pulse.stop();
        Future.delayed(const Duration(milliseconds: 600), () {
          if (mounted) Navigator.of(context).pop(data);
        });
      case CardReaderErrorState(:final exception):
        setState(() {
          _error = true;
          _message = exception.message;
        });
        _pulse.stop();
      default:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      margin: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(24),
      ),
      padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Drag handle ──────────────────────────────────────────────
          Container(
            width: 40, height: 4,
            margin: const EdgeInsets.only(bottom: 28),
            decoration: BoxDecoration(
              color: theme.colorScheme.outlineVariant,
              borderRadius: BorderRadius.circular(2),
            ),
          ),

          // ── Animated NFC icon ────────────────────────────────────────
          AnimatedBuilder(
            animation: _pulse,
            builder: (_, child) {
              final scale = _success
                  ? 1.0
                  : 1.0 + (_pulse.value * 0.15);
              return Transform.scale(
                scale: scale,
                child: child,
              );
            },
            child: Container(
              width: 100, height: 100,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _success
                    ? Colors.green.shade100
                    : _error
                        ? Colors.red.shade100
                        : theme.colorScheme.primaryContainer,
              ),
              child: Icon(
                _success
                    ? Icons.check_circle_rounded
                    : _error
                        ? Icons.error_rounded
                        : Icons.nfc_rounded,
                size: 52,
                color: _success
                    ? Colors.green.shade700
                    : _error
                        ? Colors.red.shade700
                        : theme.colorScheme.primary,
              ),
            ),
          ),

          const SizedBox(height: 24),

          Text(
            _success
                ? 'Card Detected'
                : _error
                    ? 'Scan Failed'
                    : 'Ready to Scan',
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),

          const SizedBox(height: 8),

          Text(
            _message,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),

          const SizedBox(height: 28),

          // ── Waves (decorative) ────────────────────────────────────────
          if (!_success && !_error)
            AnimatedBuilder(
              animation: _pulse,
              builder: (context, child) => CustomPaint(
                size: const Size(120, 24),
                painter: _NfcWavesPainter(
                  progress: _pulse.value,
                  color: theme.colorScheme.primary,
                ),
              ),
            ),

          const SizedBox(height: 20),

          OutlinedButton(
            onPressed: () {
              widget.controller.stopNfcScan();
              Navigator.of(context).pop();
            },
            child: const Text('Cancel'),
          ),

          SizedBox(height: MediaQuery.of(context).viewInsets.bottom),
        ],
      ),
    );
  }
}

// ── Decorative NFC arcs ───────────────────────────────────────────────────────

class _NfcWavesPainter extends CustomPainter {
  final double progress;
  final Color color;

  const _NfcWavesPainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;

    for (int i = 0; i < 3; i++) {
      final alpha = ((progress - i * 0.25).clamp(0.0, 1.0) * 255).toInt();
      paint.color = color.withAlpha(alpha);
      final radius = 12.0 + i * 14;
      canvas.drawArc(
        Rect.fromCenter(
          center: Offset(size.width / 2, size.height),
          width: radius * 2,
          height: radius * 2,
        ),
        math.pi,
        math.pi,
        false,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_NfcWavesPainter other) =>
      other.progress != progress || other.color != color;
}
