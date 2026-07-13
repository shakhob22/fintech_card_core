import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/card_reader_controller.dart';
import '../core/models/card_data.dart';
import '../core/models/card_enums.dart';
import '../core/models/card_reader_state.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Style / theming
// ─────────────────────────────────────────────────────────────────────────────

/// Visual and textual customization for [SmartCardInput].
///
/// All properties are optional. Omit a property to keep the built-in default.
///
/// **Shortcut properties** (e.g. [panLabel], [panPrefixIcon]) are applied to
/// the widget's own default [InputDecoration] for that field.
///
/// **Full override decorations** ([panDecoration], [expiryDecoration], etc.)
/// replace the entire default [InputDecoration] when provided. The widget
/// always injects its compound suffix (network badge + NFC button) into
/// [panDecoration.suffixIcon] even when a full override is given.
///
/// ```dart
/// // Uzbek localisation + custom colours
/// SmartCardInput(
///   controller: controller,
///   scheme: CardInputScheme.humoAndUzcard,
///   style: const SmartCardInputStyle(
///     panLabel: 'Karta raqami',
///     expiryLabel: 'Amal qilish muddati',
///     nameLabel: 'Karta egasi (ixtiyoriy)',
///     submitLabel: 'Tasdiqlash',
///     submitLoadingLabel: 'Tekshirilmoqda…',
///   ),
/// )
/// ```
class SmartCardInputStyle {
  // ── Label / hint text ──────────────────────────────────────────────────────

  /// Label for the card-number field (default: `'Card number'`).
  final String panLabel;

  /// Override for the PAN placeholder (default: auto-generated from grouping,
  /// e.g. `'0000 0000 0000 0000'` or `'0000 000000 00000'` for AmEx).
  final String? panHintOverride;

  /// Label for the expiry field (default: `'Expiry'`).
  final String expiryLabel;

  /// Hint inside the expiry field (default: `'MM/YY'`).
  final String expiryHint;

  /// Override the CVC field label. When `null` the widget uses `'CVV'` for
  /// standard cards and `'CID'` for American Express.
  final String? cvcLabelOverride;

  /// Label for the cardholder-name field (default: `'Cardholder name (optional)'`).
  final String nameLabel;

  /// Hint inside the cardholder-name field (default: `'JOHN DOE'`).
  final String nameHint;

  /// Submit button text when idle (default: `'Confirm card'`).
  final String submitLabel;

  /// Submit button text while the request is in-flight (default: `'Verifying…'`).
  final String submitLoadingLabel;

  // ── Prefix icons ───────────────────────────────────────────────────────────

  /// Prefix icon for the card-number field (default: [Icons.credit_card]).
  final Widget? panPrefixIcon;

  /// Prefix icon for the expiry field (default: [Icons.date_range]).
  final Widget? expiryPrefixIcon;

  /// Prefix icon for the CVC field (default: [Icons.lock_outline]).
  final Widget? cvcPrefixIcon;

  /// Prefix icon for the cardholder-name field (default: [Icons.person_outline]).
  final Widget? namePrefixIcon;

  // ── NFC ────────────────────────────────────────────────────────────────────

  /// Icon shown inside the NFC scan button (default: [Icons.nfc]).
  final Widget? nfcIcon;

  /// Widget shown while an NFC scan is active (default: small
  /// [CircularProgressIndicator] with strokeWidth 2).
  final Widget? nfcScanningWidget;

  // ── Submit button ──────────────────────────────────────────────────────────

  /// Leading icon for the submit button when idle (default: [Icons.check]).
  final Widget? submitIcon;

  /// [ButtonStyle] applied to the submit [FilledButton].
  final ButtonStyle? submitButtonStyle;

  // ── Input text style ───────────────────────────────────────────────────────

  /// [TextStyle] applied uniformly to the text inside every field.
  final TextStyle? inputStyle;

  // ── Full per-field decoration overrides ───────────────────────────────────

  /// When set, replaces the entire [InputDecoration] for the card-number field.
  /// The widget still injects its suffix (network badge / NFC button) into
  /// [InputDecoration.suffixIcon].
  final InputDecoration? panDecoration;

  /// When set, replaces the entire [InputDecoration] for the expiry field.
  final InputDecoration? expiryDecoration;

  /// When set, replaces the entire [InputDecoration] for the CVC/CID field.
  final InputDecoration? cvcDecoration;

  /// When set, replaces the entire [InputDecoration] for the cardholder-name
  /// field.
  final InputDecoration? nameDecoration;

  const SmartCardInputStyle({
    this.panLabel = 'Card number',
    this.panHintOverride,
    this.expiryLabel = 'Expiry',
    this.expiryHint = 'MM/YY',
    this.cvcLabelOverride,
    this.nameLabel = 'Cardholder name (optional)',
    this.nameHint = 'JOHN DOE',
    this.submitLabel = 'Confirm card',
    this.submitLoadingLabel = 'Verifying…',
    this.panPrefixIcon,
    this.expiryPrefixIcon,
    this.cvcPrefixIcon,
    this.namePrefixIcon,
    this.nfcIcon,
    this.nfcScanningWidget,
    this.submitIcon,
    this.submitButtonStyle,
    this.inputStyle,
    this.panDecoration,
    this.expiryDecoration,
    this.cvcDecoration,
    this.nameDecoration,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// Widget
// ─────────────────────────────────────────────────────────────────────────────

/// An optional pre-built manual-entry form for payment card data.
///
/// Supports all major card networks including Uzbek local cards (Humo, Uzcard)
/// through the [scheme] parameter. When set to [CardInputScheme.autoDetect]
/// (the default) the form adapts the card-number length, grouping, and CVC
/// requirements in real-time as the user types the BIN prefix.
///
/// Optionally displays an NFC scan button inside the card-number field
/// ([showNfcButton]). On a successful NFC read the form fields are
/// auto-populated with the card data.
///
/// All visual aspects can be customised via [style].
///
/// ```dart
/// SmartCardInput(
///   controller: myController,
///   scheme: CardInputScheme.autoDetect,
///   showNfcButton: true,
///   style: SmartCardInputStyle(
///     panLabel: 'Karta raqami',
///     submitLabel: 'Tasdiqlash',
///   ),
///   onSuccess: (card) => print(card.maskedPan),
///   onError:   (err)  => showSnackBar(err.toString()),
/// )
/// ```
class SmartCardInput extends StatefulWidget {
  final ICardReaderController controller;

  /// Controls which card networks are accepted and how PAN / CVC fields are
  /// configured. Defaults to [CardInputScheme.autoDetect].
  final CardInputScheme scheme;

  /// When `true`, an NFC scan button (IconButton) is rendered inside the
  /// card-number field's suffix. Tapping it calls [ICardReaderController.startNfcScan];
  /// on success the form fields are auto-filled. Defaults to `false`.
  final bool showNfcButton;

  /// Visual and textual customization. All properties have sensible defaults.
  final SmartCardInputStyle? style;

  /// Called after [ICardReaderController.submitManualInput] succeeds **or**
  /// after a successful NFC auto-fill (unless [onNfcSuccess] is also provided).
  final void Function(CardData card)? onSuccess;

  /// Called when any operation (manual submit or NFC scan) fails.
  final void Function(Object error)? onError;

  /// Called specifically when an NFC scan succeeds and the form is auto-filled.
  /// If provided, [onSuccess] is **not** called for the NFC event; if omitted,
  /// [onSuccess] is called instead.
  final void Function(CardData card)? onNfcSuccess;

  const SmartCardInput({
    super.key,
    required this.controller,
    this.scheme = CardInputScheme.autoDetect,
    this.showNfcButton = false,
    this.style,
    this.onSuccess,
    this.onError,
    this.onNfcSuccess,
  });

  @override
  State<SmartCardInput> createState() => _SmartCardInputState();
}

// ─────────────────────────────────────────────────────────────────────────────
// State
// ─────────────────────────────────────────────────────────────────────────────

class _SmartCardInputState extends State<SmartCardInput> {
  final _formKey = GlobalKey<FormState>();
  final _panCtrl = TextEditingController();
  final _expiryCtrl = TextEditingController();
  final _cvvCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();

  late _SchemeConfig _config;
  bool _submitting = false;
  bool _nfcScanning = false;
  StreamSubscription<CardReaderState>? _nfcSub;

  @override
  void initState() {
    super.initState();
    _config = _SchemeConfig.forScheme(widget.scheme);
    _subscribeNfc();
  }

  @override
  void didUpdateWidget(SmartCardInput oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.scheme != widget.scheme) {
      final digits = _panCtrl.text.replaceAll(' ', '');
      setState(() {
        _config = widget.scheme == CardInputScheme.autoDetect
            ? _SchemeConfig.detect(digits)
            : _SchemeConfig.forScheme(widget.scheme);
      });
    }

    if (oldWidget.showNfcButton != widget.showNfcButton) {
      widget.showNfcButton ? _subscribeNfc() : _unsubscribeNfc();
    }
  }

  @override
  void dispose() {
    _unsubscribeNfc();
    _panCtrl.dispose();
    _expiryCtrl.dispose();
    _cvvCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  // ── NFC ────────────────────────────────────────────────────────────────────

  void _subscribeNfc() {
    if (!widget.showNfcButton || _nfcSub != null) return;
    _nfcSub = widget.controller.stateStream.listen(_onControllerState);
  }

  void _unsubscribeNfc() {
    _nfcSub?.cancel();
    _nfcSub = null;
  }

  void _onControllerState(CardReaderState state) {
    if (!_nfcScanning || !mounted) return;
    switch (state) {
      case CardReaderSuccessState(:final data):
        _fillFromCard(data);
        setState(() => _nfcScanning = false);
        if (widget.onNfcSuccess != null) {
          widget.onNfcSuccess!(data);
        } else {
          widget.onSuccess?.call(data);
        }
      case CardReaderErrorState(:final exception):
        setState(() => _nfcScanning = false);
        widget.onError?.call(exception);
      case CardReaderIdleState():
        setState(() => _nfcScanning = false);
      case CardReaderScanningState():
        break;
    }
  }

  Future<void> _startNfcScan() async {
    if (_nfcScanning) return;
    setState(() => _nfcScanning = true);
    try {
      await widget.controller.startNfcScan();
    } catch (e) {
      if (mounted) setState(() => _nfcScanning = false);
      widget.onError?.call(e);
    }
  }

  /// Populates all form fields from a [CardData] received via NFC.
  ///
  /// Groups the PAN according to the detected (or configured) scheme.
  /// NFC does not expose the CVV — the field is cleared so the user
  /// knows they must enter it manually (only relevant for international cards).
  void _fillFromCard(CardData card) {
    final newConfig = widget.scheme == CardInputScheme.autoDetect
        ? _SchemeConfig.detect(card.pan)
        : _SchemeConfig.forScheme(widget.scheme);

    final formattedPan = _applyGroups(card.pan, newConfig.panGroups);

    // Batch all field updates in a single frame so the form rebuilds once.
    setState(() => _config = newConfig);

    _panCtrl.value = TextEditingValue(
      text: formattedPan,
      selection: TextSelection.collapsed(offset: formattedPan.length),
    );
    _expiryCtrl.value = TextEditingValue(
      text: card.expiryDate,
      selection: TextSelection.collapsed(offset: card.expiryDate.length),
    );
    if (card.cardholderName != null && card.cardholderName!.isNotEmpty) {
      final name = card.cardholderName!;
      _nameCtrl.value = TextEditingValue(
        text: name,
        selection: TextSelection.collapsed(offset: name.length),
      );
    }
    _cvvCtrl.clear();
  }

  // ── PAN auto-detect ────────────────────────────────────────────────────────

  void _onPanChanged(String value) {
    if (widget.scheme != CardInputScheme.autoDetect) return;
    final digits = value.replaceAll(' ', '');
    final next = _SchemeConfig.detect(digits);
    if (next == _config) return;

    // Check whether the group structure changed (e.g. standard → AmEx 4-6-5).
    final groupsChanged = next.panGroups.length != _config.panGroups.length ||
        next.panGroups.asMap().entries.any((e) => _config.panGroups[e.key] != e.value);

    setState(() => _config = next);

    // Reformat existing text when the grouping changes (rare — happens only
    // when the user has already typed ≥ 4 digits and the detection switches).
    if (groupsChanged && digits.isNotEmpty) {
      final reformatted = _applyGroups(digits, next.panGroups);
      if (reformatted != _panCtrl.text) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _panCtrl.value = TextEditingValue(
            text: reformatted,
            selection: TextSelection.collapsed(offset: reformatted.length),
          );
        });
      }
    }
  }

  /// Inserts spaces at group boundaries. Static so [_CardNumberFormatter]
  /// can delegate to it without a state reference.
  static String _applyGroups(String digits, List<int> groups) {
    final total = groups.fold(0, (s, g) => s + g);
    final clipped = digits.length > total ? digits.substring(0, total) : digits;
    final buf = StringBuffer();
    int pos = 0;
    for (int g = 0; g < groups.length; g++) {
      if (pos >= clipped.length) break;
      if (g > 0) buf.write(' ');
      buf.write(clipped.substring(pos, (pos + groups[g]).clamp(0, clipped.length)));
      pos += groups[g];
    }
    return buf.toString();
  }

  // ── Submit ─────────────────────────────────────────────────────────────────

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _submitting = true);
    try {
      final card = await widget.controller.submitManualInput(
        pan: _panCtrl.text.replaceAll(' ', ''),
        expiryDate: _expiryCtrl.text,
        cvv: _cvvCtrl.text.isEmpty ? null : _cvvCtrl.text,
        cardholderName: _nameCtrl.text.trim().isEmpty ? null : _nameCtrl.text.trim(),
      );
      widget.onSuccess?.call(card);
    } catch (e) {
      widget.onError?.call(e);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  // ── Decoration builders ────────────────────────────────────────────────────

  /// Builds the compound suffix for the PAN field:
  /// [network badge] [NFC button or spinner].
  Widget _panSuffix(_SchemeConfig config) {
    final s = widget.style;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _NetworkBadge(type: config.detectedType),
        if (widget.showNfcButton) ...[
          const SizedBox(width: 2),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: _nfcScanning
                ? Padding(
                    key: const ValueKey('nfc_loading'),
                    padding: const EdgeInsets.all(10),
                    child: SizedBox.square(
                      dimension: 20,
                      child: s?.nfcScanningWidget ??
                          const CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : IconButton(
                    key: const ValueKey('nfc_idle'),
                    icon: s?.nfcIcon ?? const Icon(Icons.nfc),
                    tooltip: 'Scan with NFC',
                    onPressed: _startNfcScan,
                  ),
          ),
        ],
      ],
    );
  }

  InputDecoration _panDecoration(_SchemeConfig config) {
    final s = widget.style;
    final suffix = _panSuffix(config);
    final override = s?.panDecoration;
    if (override != null) {
      // Respect user's decoration but always inject our functional suffix.
      return override.copyWith(suffixIcon: suffix);
    }
    return InputDecoration(
      labelText: s?.panLabel ?? 'Card number',
      hintText: s?.panHintOverride ?? config.panHint,
      prefixIcon: s?.panPrefixIcon ?? const Icon(Icons.credit_card),
      suffixIcon: suffix,
      counterText: '',
    );
  }

  InputDecoration _expiryDecoration() {
    final s = widget.style;
    final override = s?.expiryDecoration;
    if (override != null) return override;
    return InputDecoration(
      labelText: s?.expiryLabel ?? 'Expiry',
      hintText: s?.expiryHint ?? 'MM/YY',
      prefixIcon: s?.expiryPrefixIcon ?? const Icon(Icons.date_range),
      counterText: '',
    );
  }

  InputDecoration _cvcDecoration(_SchemeConfig config) {
    final s = widget.style;
    final override = s?.cvcDecoration;
    if (override != null) return override;
    final label = s?.cvcLabelOverride ?? config.cvcLabel;
    return InputDecoration(
      labelText: label,
      hintText: '•' * config.cvcLength,
      prefixIcon: s?.cvcPrefixIcon ?? const Icon(Icons.lock_outline),
      counterText: '',
    );
  }

  InputDecoration _nameDecoration() {
    final s = widget.style;
    final override = s?.nameDecoration;
    if (override != null) return override;
    return InputDecoration(
      labelText: s?.nameLabel ?? 'Cardholder name (optional)',
      hintText: s?.nameHint ?? 'JOHN DOE',
      prefixIcon: s?.namePrefixIcon ?? const Icon(Icons.person_outline),
      counterText: '',
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final config = _config;
    final s = widget.style;

    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Card number ───────────────────────────────────────────────────
          TextFormField(
            controller: _panCtrl,
            style: s?.inputStyle,
            decoration: _panDecoration(config),
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              _CardNumberFormatter(config.panGroups),
            ],
            maxLength: config.formattedPanLength,
            onChanged: _onPanChanged,
            validator: (v) {
              if (v == null || v.isEmpty) return 'Required';
              if (v.replaceAll(' ', '').length < config.panLength) {
                return 'Enter ${config.panLength} digits';
              }
              return null;
            },
          ),

          const SizedBox(height: 12),

          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Expiry ───────────────────────────────────────────────────
              Expanded(
                child: TextFormField(
                  controller: _expiryCtrl,
                  style: s?.inputStyle,
                  decoration: _expiryDecoration(),
                  keyboardType: TextInputType.number,
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[\d/]')),
                    _ExpiryFormatter(),
                  ],
                  maxLength: 5,
                  validator: (v) {
                    if (v == null || v.isEmpty) return 'Required';
                    if (!RegExp(r'^(0[1-9]|1[0-2])\/\d{2}$').hasMatch(v)) {
                      return 'MM/YY';
                    }
                    return null;
                  },
                ),
              ),

              // ── CVC (conditional) ─────────────────────────────────────
              if (config.showCvc) ...[
                const SizedBox(width: 12),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    child: _CvcField(
                      key: ValueKey('${config.cvcLength}-${config.cvcLabel}'),
                      controller: _cvvCtrl,
                      length: config.cvcLength,
                      required: config.cvcRequired,
                      decoration: _cvcDecoration(config),
                      inputStyle: s?.inputStyle,
                    ),
                  ),
                ),
              ],
            ],
          ),

          const SizedBox(height: 12),

          // ── Cardholder name ───────────────────────────────────────────────
          TextFormField(
            controller: _nameCtrl,
            style: s?.inputStyle,
            decoration: _nameDecoration(),
            textCapitalization: TextCapitalization.characters,
            maxLength: 26,
          ),

          const SizedBox(height: 20),

          // ── Submit ────────────────────────────────────────────────────────
          FilledButton.icon(
            onPressed: _submitting ? null : _submit,
            style: s?.submitButtonStyle,
            icon: _submitting
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : (s?.submitIcon ?? const Icon(Icons.check)),
            label: Text(
              _submitting
                  ? (s?.submitLoadingLabel ?? 'Verifying…')
                  : (s?.submitLabel ?? 'Confirm card'),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// CVC field
// ─────────────────────────────────────────────────────────────────────────────

/// Extracted so that [AnimatedSwitcher] can key on CVV↔CID transitions.
class _CvcField extends StatelessWidget {
  final TextEditingController controller;
  final int length;
  final bool required;
  final InputDecoration decoration;
  final TextStyle? inputStyle;

  const _CvcField({
    super.key,
    required this.controller,
    required this.length,
    required this.required,
    required this.decoration,
    this.inputStyle,
  });

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      style: inputStyle,
      decoration: decoration,
      keyboardType: TextInputType.number,
      inputFormatters: [
        FilteringTextInputFormatter.digitsOnly,
        LengthLimitingTextInputFormatter(length),
      ],
      obscureText: true,
      validator: required
          ? (v) {
              if (v == null || v.isEmpty) return 'Required';
              if (v.length < length) return '$length digits';
              return null;
            }
          : null,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Network badge
// ─────────────────────────────────────────────────────────────────────────────

class _NetworkBadge extends StatelessWidget {
  final CardType? type;
  const _NetworkBadge({this.type});

  @override
  Widget build(BuildContext context) {
    final label = _label(type);
    if (label == null) {
      return const Icon(Icons.credit_card, color: Colors.black38);
    }
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      child: Padding(
        key: ValueKey(type),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          decoration: BoxDecoration(
            color: _color(type),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
              height: 1,
            ),
          ),
        ),
      ),
    );
  }

  static String? _label(CardType? t) => switch (t) {
        CardType.visa => 'VISA',
        CardType.mastercard => 'MC',
        CardType.amex => 'AMEX',
        CardType.humo => 'HUMO',
        CardType.uzcard => 'UZCARD',
        CardType.discover => 'DISC',
        CardType.unionPay => 'UP',
        CardType.jcb => 'JCB',
        _ => null,
      };

  static Color _color(CardType? t) => switch (t) {
        CardType.visa => const Color(0xFF1A1F71),
        CardType.mastercard => const Color(0xFFEB001B),
        CardType.amex => const Color(0xFF007BC1),
        CardType.humo => const Color(0xFF00A651),
        CardType.uzcard => const Color(0xFF003399),
        CardType.discover => const Color(0xFFFF6600),
        CardType.unionPay => const Color(0xFFEE1C25),
        CardType.jcb => const Color(0xFF003087),
        _ => Colors.grey,
      };
}

// ─────────────────────────────────────────────────────────────────────────────
// Internal scheme config
// ─────────────────────────────────────────────────────────────────────────────

class _SchemeConfig {
  final int panLength;
  final List<int> panGroups;
  final bool showCvc;
  final bool cvcRequired;
  final int cvcLength;
  final String cvcLabel;

  /// The network we have positively identified from the BIN (null = unknown).
  final CardType? detectedType;

  const _SchemeConfig({
    required this.panLength,
    required this.panGroups,
    required this.showCvc,
    required this.cvcRequired,
    required this.cvcLength,
    required this.cvcLabel,
    this.detectedType,
  });

  /// Total character count of a fully-typed PAN including inter-group spaces.
  int get formattedPanLength => panLength + panGroups.length - 1;

  /// Auto-generated placeholder matching the group layout.
  String get panHint {
    final buf = StringBuffer();
    for (int g = 0; g < panGroups.length; g++) {
      if (g > 0) buf.write(' ');
      buf.write('0' * panGroups[g]);
    }
    return buf.toString();
  }

  // ── Named presets ──────────────────────────────────────────────────────────

  /// 16-digit standard layout, CVC present but not required (unknown network).
  static const _SchemeConfig _unknown = _SchemeConfig(
    panLength: 16,
    panGroups: [4, 4, 4, 4],
    showCvc: true,
    cvcRequired: false,
    cvcLength: 3,
    cvcLabel: 'CVV',
  );

  /// 16-digit standard layout, CVC required (Visa / Mastercard confirmed).
  static const _SchemeConfig _standard = _SchemeConfig(
    panLength: 16,
    panGroups: [4, 4, 4, 4],
    showCvc: true,
    cvcRequired: true,
    cvcLength: 3,
    cvcLabel: 'CVV',
  );

  /// 16-digit local layout, CVC hidden (Humo / Uzcard).
  static const _SchemeConfig _local = _SchemeConfig(
    panLength: 16,
    panGroups: [4, 4, 4, 4],
    showCvc: false,
    cvcRequired: false,
    cvcLength: 3,
    cvcLabel: 'CVV',
  );

  // ── Factory: fixed scheme ──────────────────────────────────────────────────

  static _SchemeConfig forScheme(CardInputScheme scheme) => switch (scheme) {
        CardInputScheme.americanExpress => const _SchemeConfig(
            panLength: 15,
            panGroups: [4, 6, 5],
            showCvc: true,
            cvcRequired: true,
            cvcLength: 4,
            cvcLabel: 'CID',
            detectedType: CardType.amex,
          ),
        CardInputScheme.humoAndUzcard => _local,
        CardInputScheme.visaAndMastercard => _standard,
        CardInputScheme.autoDetect => _unknown,
      };

  // ── Factory: BIN auto-detect ───────────────────────────────────────────────

  /// Derives a config from raw [digits] (no spaces).
  ///
  /// Detection thresholds are chosen so that format divergence happens before
  /// the first space is emitted (≤ 4 digits), keeping the text-field reformat
  /// transparent to the user.
  static _SchemeConfig detect(String digits) {
    // American Express: 34xx / 37xx — 2 digits sufficient
    if (digits.length >= 2 && RegExp(r'^3[47]').hasMatch(digits)) {
      return const _SchemeConfig(
        panLength: 15,
        panGroups: [4, 6, 5],
        showCvc: true,
        cvcRequired: true,
        cvcLength: 4,
        cvcLabel: 'CID',
        detectedType: CardType.amex,
      );
    }

    // Humo: 9860xxxx — 4 digits sufficient
    if (digits.length >= 4 && digits.startsWith('9860')) {
      return const _SchemeConfig(
        panLength: 16,
        panGroups: [4, 4, 4, 4],
        showCvc: false,
        cvcRequired: false,
        cvcLength: 3,
        cvcLabel: 'CVV',
        detectedType: CardType.humo,
      );
    }

    // Uzcard: 8600xxxx — 4 digits sufficient
    if (digits.length >= 4 && digits.startsWith('8600')) {
      return const _SchemeConfig(
        panLength: 16,
        panGroups: [4, 4, 4, 4],
        showCvc: false,
        cvcRequired: false,
        cvcLength: 3,
        cvcLabel: 'CVV',
        detectedType: CardType.uzcard,
      );
    }

    // Visa: 4x — 1 digit sufficient
    if (digits.isNotEmpty && digits.startsWith('4')) {
      return _standard.copyWith(detectedType: CardType.visa);
    }

    // Mastercard: 51-55 (2 digits) or 2221-2720 (4 digits)
    if (digits.length >= 2 && RegExp(r'^5[1-5]').hasMatch(digits)) {
      return _standard.copyWith(detectedType: CardType.mastercard);
    }
    if (digits.length >= 4 &&
        RegExp(r'^2(2[2-9][1-9]|2[3-9]\d|[3-6]\d{2}|7[01]\d|720)').hasMatch(digits)) {
      return _standard.copyWith(detectedType: CardType.mastercard);
    }

    return _unknown;
  }

  _SchemeConfig copyWith({CardType? detectedType}) => _SchemeConfig(
        panLength: panLength,
        panGroups: panGroups,
        showCvc: showCvc,
        cvcRequired: cvcRequired,
        cvcLength: cvcLength,
        cvcLabel: cvcLabel,
        detectedType: detectedType ?? this.detectedType,
      );

  @override
  bool operator ==(Object other) =>
      other is _SchemeConfig &&
      other.panLength == panLength &&
      other.panGroups.length == panGroups.length &&
      other.showCvc == showCvc &&
      other.cvcRequired == cvcRequired &&
      other.cvcLength == cvcLength &&
      other.detectedType == detectedType;

  @override
  int get hashCode => Object.hash(
        panLength,
        panGroups.length,
        showCvc,
        cvcRequired,
        cvcLength,
        detectedType,
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Input Formatters
// ─────────────────────────────────────────────────────────────────────────────

/// Formats PAN digits into groups separated by spaces.
///
/// The [groups] list defines the digit count per group:
/// - `[4, 4, 4, 4]` → `0000 0000 0000 0000` (standard 16-digit)
/// - `[4, 6, 5]`    → `0000 000000 00000`   (American Express 15-digit)
class _CardNumberFormatter extends TextInputFormatter {
  final List<int> groups;
  const _CardNumberFormatter(this.groups);

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final digits = newValue.text.replaceAll(' ', '');
    final formatted = _SmartCardInputState._applyGroups(digits, groups);
    return newValue.copyWith(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }
}

class _ExpiryFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final digits = newValue.text.replaceAll('/', '');
    if (digits.isEmpty) return newValue.copyWith(text: '');
    final buf = StringBuffer(digits.substring(0, digits.length.clamp(0, 2)));
    if (digits.length > 2) {
      buf.write('/');
      buf.write(digits.substring(2, digits.length.clamp(2, 4)));
    }
    final formatted = buf.toString();
    return newValue.copyWith(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }
}
