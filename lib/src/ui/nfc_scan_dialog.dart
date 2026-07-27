import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../core/card_reader_controller.dart';
import '../core/models/card_data.dart';
import '../core/models/card_reader_state.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Status enum
// ─────────────────────────────────────────────────────────────────────────────

/// The current visual state of [NfcScanDialog].
///
/// Passed to [NfcScanDialogTheme.iconBuilder] so you can render a completely
/// custom icon for each phase.
enum NfcScanDialogStatus { scanning, success, error }

// ─────────────────────────────────────────────────────────────────────────────
// Theme / customisation
// ─────────────────────────────────────────────────────────────────────────────

/// Visual and textual customisation for [NfcScanDialog].
///
/// All properties are optional — omit any to keep the built-in default.
///
/// ### Minimal Uzbek localisation example
/// ```dart
/// const NfcScanDialogTheme(
///   titleScanning: 'Skanerlashga tayyor',
///   titleSuccess:  'Karta aniqlandi',
///   titleError:    'Xatolik yuz berdi',
///   initialMessage: 'Kartangizni qurilma yoniga tuting…',
///   successMessage: 'Karta muvaffaqiyatli o\'qildi!',
///   cancelLabel:   'Bekor qilish',
/// )
/// ```
///
/// ### Custom colours
/// ```dart
/// NfcScanDialogTheme(
///   scanningIconColor:           Colors.teal,
///   scanningIconBackgroundColor: Colors.teal.shade100,
///   successIconColor:            Colors.green,
///   successIconBackgroundColor:  Colors.green.shade50,
///   errorIconColor:              Colors.red,
///   errorIconBackgroundColor:    Colors.red.shade50,
/// )
/// ```
///
/// ### Fully custom icon widget
/// ```dart
/// NfcScanDialogTheme(
///   iconBuilder: (status, pulse) {
///     return AnimatedBuilder(
///       animation: pulse,
///       builder: (_, child) => Opacity(
///         opacity: status == NfcScanDialogStatus.scanning
///             ? 0.5 + pulse.value * 0.5
///             : 1.0,
///         child: child,
///       ),
///       child: Image.asset('assets/nfc_icon.png', width: 80, height: 80),
///     );
///   },
/// )
/// ```
class NfcScanDialogTheme {
  // ── Text labels ─────────────────────────────────────────────────────────────

  /// Title shown while waiting for a card (default: `'Ready to Scan'`).
  final String titleScanning;

  /// Title shown after a successful read (default: `'Card Detected'`).
  final String titleSuccess;

  /// Title shown after an error (default: `'Scan Failed'`).
  final String titleError;

  /// Body message shown as soon as the dialog opens
  /// (default: `'Hold your card near the device…'`).
  final String initialMessage;

  /// Body message shown after a successful read
  /// (default: `'Card read successfully!'`).
  final String successMessage;

  /// Label for the cancel / dismiss button (default: `'Cancel'`).
  final String cancelLabel;

  /// Label for the retry button that appears on error when
  /// [showRetryOnError] is `true` (default: `'Try Again'`).
  final String retryLabel;

  // ── Icons ────────────────────────────────────────────────────────────────────

  /// Icon shown while scanning (default: [Icons.nfc_rounded]).
  final IconData scanningIcon;

  /// Icon shown on success (default: [Icons.check_circle_rounded]).
  final IconData successIcon;

  /// Icon shown on error (default: [Icons.error_rounded]).
  final IconData errorIcon;

  // ── Colours ──────────────────────────────────────────────────────────────────

  /// Foreground colour of the scanning icon.
  /// Defaults to `theme.colorScheme.primary`.
  final Color? scanningIconColor;

  /// Background colour of the scanning icon circle.
  /// Defaults to `theme.colorScheme.primaryContainer`.
  final Color? scanningIconBackgroundColor;

  /// Foreground colour of the success icon.
  /// Defaults to `Colors.green.shade700`.
  final Color? successIconColor;

  /// Background colour of the success icon circle.
  /// Defaults to `Colors.green.shade100`.
  final Color? successIconBackgroundColor;

  /// Foreground colour of the error icon.
  /// Defaults to `Colors.red.shade700`.
  final Color? errorIconColor;

  /// Background colour of the error icon circle.
  /// Defaults to `Colors.red.shade100`.
  final Color? errorIconBackgroundColor;

  // ── Behaviour ────────────────────────────────────────────────────────────────

  /// How long the success state is shown before the dialog auto-dismisses.
  /// Defaults to `Duration(milliseconds: 600)`.
  final Duration successDismissDelay;

  /// When `true` a **Try Again** button is shown on error next to Cancel,
  /// allowing the user to restart the scan without re-opening the dialog.
  /// Defaults to `false`.
  final bool showRetryOnError;

  // ── Custom icon builder ───────────────────────────────────────────────────────

  /// Fully replace the built-in icon with your own widget.
  ///
  /// When provided, [scanningIcon], [successIcon], [errorIcon], and all
  /// `*IconColor` / `*IconBackgroundColor` properties are ignored.
  ///
  /// The [pulse] animation controller runs between 0 and 1 (repeating) while
  /// the dialog is in the [NfcScanDialogStatus.scanning] phase.
  final Widget Function(
    NfcScanDialogStatus status,
    Animation<double> pulse,
  )? iconBuilder;

  const NfcScanDialogTheme({
    this.titleScanning = 'Ready to Scan',
    this.titleSuccess = 'Card Detected',
    this.titleError = 'Scan Failed',
    this.initialMessage = 'Hold your card near the device…',
    this.successMessage = 'Card read successfully!',
    this.cancelLabel = 'Cancel',
    this.retryLabel = 'Try Again',
    this.scanningIcon = CupertinoIcons.creditcard,
    this.successIcon = CupertinoIcons.check_mark,
    this.errorIcon = CupertinoIcons.xmark_circle,
    this.scanningIconColor,
    this.scanningIconBackgroundColor,
    this.successIconColor,
    this.successIconBackgroundColor,
    this.errorIconColor,
    this.errorIconBackgroundColor,
    this.successDismissDelay = const Duration(milliseconds: 600),
    this.showRetryOnError = false,
    this.iconBuilder,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// Dialog widget
// ─────────────────────────────────────────────────────────────────────────────

/// A pre-built bottom-sheet dialog that drives an NFC card scan.
///
/// Shows an animated NFC icon and live status messages while the
/// [ICardReaderController] scans. Dismisses automatically on success.
///
/// ## Usage
///
/// ### 1 — Built-in dialog (default look)
/// ```dart
/// final card = await NfcScanDialog.show(context, controller: controller);
/// ```
///
/// ### 2 — Custom-themed dialog
/// ```dart
/// final card = await NfcScanDialog.show(
///   context,
///   controller: controller,
///   theme: const NfcScanDialogTheme(
///     titleScanning: 'Skanerlashga tayyor',
///     cancelLabel:   'Bekor qilish',
///     showRetryOnError: true,
///   ),
/// );
/// ```
///
/// ### 3 — Headless (no built-in UI at all)
/// ```dart
/// controller.stateStream.listen((state) {
///   switch (state) {
///     case CardReaderScanningState(:final message): /* show your own UI */ break;
///     case CardReaderSuccessState(:final data):     /* use data */         break;
///     case CardReaderErrorState(:final exception):  /* handle error */     break;
///     default: break;
///   }
/// });
/// await controller.startNfcScan();
/// ```
class NfcScanDialog extends StatefulWidget {
  final ICardReaderController controller;
  final NfcScanDialogTheme theme;

  /// Optional fully-custom replacement for the entire dialog UI.
  ///
  /// When non-null, the built-in icon/title/message/buttons layout is
  /// discarded and this widget is rendered instead. The NFC scan is still
  /// started automatically — only the visual layer is replaced.
  ///
  /// When null the default dialog UI is shown as usual.
  final Widget? child;

  const NfcScanDialog._({
    required this.controller,
    required this.theme,
    this.child,
  });

  /// Show the NFC scan bottom-sheet and return the scanned [CardData],
  /// or `null` if the user dismissed before a card was detected.
  ///
  /// Pass a [theme] to customise labels, colours, icons, or provide a
  /// completely custom [NfcScanDialogTheme.iconBuilder].
  ///
  /// Pass a [child] to replace the entire dialog UI with your own widget.
  /// The NFC scan still starts automatically; [theme] is ignored when
  /// [child] is provided.
  static Future<CardData?> show(
    BuildContext context, {
    required ICardReaderController controller,
    NfcScanDialogTheme theme = const NfcScanDialogTheme(),
    Widget? child,
  }) {
    return showModalBottomSheet<CardData>(
      context: context,
      isDismissible: true,
      useRootNavigator: true,
      backgroundColor: Colors.transparent,
      builder: (_) => NfcScanDialog._(
        controller: controller,
        theme: theme,
        child: child,
      ),
    );
  }

  @override
  State<NfcScanDialog> createState() => _NfcScanDialogState();
}

class _NfcScanDialogState extends State<NfcScanDialog>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;
  StreamSubscription<CardReaderState>? _sub;

  NfcScanDialogStatus _status = NfcScanDialogStatus.scanning;
  String _message = '';

  NfcScanDialogTheme get _theme => widget.theme;

  @override
  void initState() {
    super.initState();
    _message = _theme.initialMessage;

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
        if (mounted) {
          setState(() => _message = message ?? _message);
        }
      case CardReaderSuccessState(:final data):
        _pulse.stop();
        if (mounted) {
          setState(() {
            _status = NfcScanDialogStatus.success;
            _message = _theme.successMessage;
          });
          Future.delayed(_theme.successDismissDelay, () {
            if (mounted) Navigator.of(context).pop(data);
          });
        }
      case CardReaderErrorState(:final exception):
        _pulse.stop();
        if (mounted) {
          setState(() {
            _status = NfcScanDialogStatus.error;
            _message = exception.message;
          });
        }
      default:
        break;
    }
  }

  void _retryNfcScan() {
    setState(() {
      _status = NfcScanDialogStatus.scanning;
      _message = _theme.initialMessage;
    });
    _pulse.repeat(reverse: true);
    widget.controller.startNfcScan();
  }

  // ── Build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (widget.child != null) return widget.child!;

    final materialTheme = Theme.of(context);

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: materialTheme.colorScheme.surface,
        borderRadius: BorderRadius.circular(24),
      ),
      padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        // children: [
        //   _buildHandle(materialTheme),
        //   _buildIcon(materialTheme),
        //   const SizedBox(height: 24),
        //   _buildTitle(materialTheme),
        //   const SizedBox(height: 8),
        //   _buildMessage(materialTheme),
        //   const SizedBox(height: 28),
        //   if (_status == NfcScanDialogStatus.scanning)
        //     _buildWaves(materialTheme),
        //   const SizedBox(height: 20),
        //   _buildButtons(materialTheme),
        //   SizedBox(height: MediaQuery.of(context).viewInsets.bottom),
        // ],
        children: [
          _buildHandle(materialTheme),
          _buildIcon(materialTheme),
          const SizedBox(height: 24),
          _buildTitle(materialTheme),
          const SizedBox(height: 8),
          _buildMessage(materialTheme),
          const SizedBox(height: 28),
          // if (_status == NfcScanDialogStatus.scanning)
          //   _buildWaves(materialTheme),
          const SizedBox(height: 20),
          _buildButtons(materialTheme),
          SizedBox(height: MediaQuery.of(context).viewInsets.bottom),
        ],
      ),
    );
  }

  // ── Sub-builders ─────────────────────────────────────────────────────────────

  Widget _buildHandle(ThemeData t) {
    return Container(
      width: 40,
      height: 4,
      margin: const EdgeInsets.only(bottom: 28),
      decoration: BoxDecoration(
        color: t.colorScheme.outlineVariant,
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }

  Widget _buildIcon(ThemeData t) {
    if (_theme.iconBuilder != null) {
      return _theme.iconBuilder!(_status, _pulse);
    }

    final (bgColor, fgColor, iconData) = switch (_status) {
      NfcScanDialogStatus.success => (
          _theme.successIconBackgroundColor ?? Colors.green.shade100,
          _theme.successIconColor ?? Colors.green.shade700,
          _theme.successIcon,
        ),
      NfcScanDialogStatus.error => (
          _theme.errorIconBackgroundColor ?? Colors.red.shade100,
          _theme.errorIconColor ?? Colors.red.shade700,
          _theme.errorIcon,
        ),
      NfcScanDialogStatus.scanning => (
          _theme.scanningIconBackgroundColor ?? t.colorScheme.primaryContainer,
          _theme.scanningIconColor ?? t.colorScheme.primary,
          _theme.scanningIcon,
        ),
    };

    return AnimatedBuilder(
      animation: _pulse,
      builder: (_, child) {
        final scale = _status == NfcScanDialogStatus.scanning
            ? 1.0 + (_pulse.value * 0.15)
            : 1.0;
        return Transform.scale(scale: scale, child: child);
      },
      child: Container(
        width: 100,
        height: 100,
        decoration: BoxDecoration(shape: BoxShape.circle, color: bgColor),
        child: Icon(iconData, size: 52, color: fgColor),
      ),
    );
  }

  Widget _buildTitle(ThemeData t) {
    final title = switch (_status) {
      NfcScanDialogStatus.success => _theme.titleSuccess,
      NfcScanDialogStatus.error => _theme.titleError,
      NfcScanDialogStatus.scanning => _theme.titleScanning,
    };
    return Text(
      title,
      style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
    );
  }

  Widget _buildMessage(ThemeData t) {
    return Text(
      _message,
      textAlign: TextAlign.center,
      style: t.textTheme.bodyMedium?.copyWith(
        color: t.colorScheme.onSurfaceVariant,
      ),
    );
  }

  Widget _buildButtons(ThemeData t) {
    if (_status == NfcScanDialogStatus.error && _theme.showRetryOnError) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          OutlinedButton(
            onPressed: () {
              widget.controller.stopNfcScan();
              Navigator.of(context).pop();
            },
            child: Text(_theme.cancelLabel),
          ),
          const SizedBox(width: 12),
          FilledButton(
            onPressed: _retryNfcScan,
            child: Text(_theme.retryLabel),
          ),
        ],
      );
    }

    return OutlinedButton(
      onPressed: () {
        widget.controller.stopNfcScan();
        Navigator.of(context).pop();
      },
      child: Text(_theme.cancelLabel),
    );
  }
}
