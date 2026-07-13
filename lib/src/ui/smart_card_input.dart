import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/card_reader_controller.dart';
import '../core/models/card_data.dart';
import '../core/models/card_enums.dart';

/// An optional pre-built manual-entry form for payment card data.
///
/// Supports international cards (Visa, Mastercard, AmEx) and Uzbek local
/// networks (Humo, Uzcard) through the [scheme] parameter.
///
/// ```dart
/// // Auto-detects card type from BIN prefix as the user types:
/// SmartCardInput(
///   controller: myController,
///   onSuccess: (card) => print(card.maskedPan),
/// )
///
/// // Lock to Uzbek local cards (no CVC field, 16-digit 4-4-4-4):
/// SmartCardInput(
///   controller: myController,
///   scheme: CardInputScheme.humoAndUzcard,
///   onSuccess: (card) => print(card.maskedPan),
/// )
///
/// // Lock to American Express (15-digit 4-6-5, 4-digit CID):
/// SmartCardInput(
///   controller: myController,
///   scheme: CardInputScheme.americanExpress,
///   onSuccess: (card) => print(card.maskedPan),
/// )
/// ```
class SmartCardInput extends StatefulWidget {
  final ICardReaderController controller;

  /// Controls accepted networks and how PAN / CVC fields are configured.
  ///
  /// Defaults to [CardInputScheme.autoDetect], which reads the BIN prefix as
  /// the user types and adjusts field constraints in real-time.
  final CardInputScheme scheme;

  final void Function(CardData card)? onSuccess;
  final void Function(Object error)? onError;

  const SmartCardInput({
    super.key,
    required this.controller,
    this.scheme = CardInputScheme.autoDetect,
    this.onSuccess,
    this.onError,
  });

  @override
  State<SmartCardInput> createState() => _SmartCardInputState();
}

// ─────────────────────────────────────────────────────────────────────────────
// Internal configuration derived from scheme + live BIN detection
// ─────────────────────────────────────────────────────────────────────────────

class _SchemeConfig {
  final int panLength;
  final List<int> panGroups;
  final bool showCvc;
  final bool cvcRequired;
  final int cvcLength;
  final String cvcLabel;

  /// The card network we've positively identified (null = still unknown).
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

  /// Total character count of a fully-typed PAN including spaces.
  int get formattedPanLength => panLength + panGroups.length - 1;

  /// Placeholder text for the PAN field (e.g. `"0000 000000 00000"`).
  String get panHint {
    final buf = StringBuffer();
    for (int g = 0; g < panGroups.length; g++) {
      if (g > 0) buf.write(' ');
      buf.write('0' * panGroups[g]);
    }
    return buf.toString();
  }

  // ── Named presets ──────────────────────────────────────────────────────────

  static const _SchemeConfig _standard = _SchemeConfig(
    panLength: 16,
    panGroups: [4, 4, 4, 4],
    showCvc: true,
    cvcRequired: false, // unknown network — don't force until detected
    cvcLength: 3,
    cvcLabel: 'CVV',
  );

  static const _SchemeConfig _standardKnown = _SchemeConfig(
    panLength: 16,
    panGroups: [4, 4, 4, 4],
    showCvc: true,
    cvcRequired: true,
    cvcLength: 3,
    cvcLabel: 'CVV',
  );

  static const _SchemeConfig _local = _SchemeConfig(
    panLength: 16,
    panGroups: [4, 4, 4, 4],
    showCvc: false,
    cvcRequired: false,
    cvcLength: 3,
    cvcLabel: 'CVV',
  );

  // ── Factory: fixed scheme (no auto-detect) ─────────────────────────────────

  static _SchemeConfig forScheme(CardInputScheme scheme) => switch (scheme) {
        CardInputScheme.americanExpress =>
          const _SchemeConfig(
            panLength: 15,
            panGroups: [4, 6, 5],
            showCvc: true,
            cvcRequired: true,
            cvcLength: 4,
            cvcLabel: 'CID',
            detectedType: CardType.amex,
          ),
        CardInputScheme.humoAndUzcard => _local,
        CardInputScheme.visaAndMastercard =>
          const _SchemeConfig(
            panLength: 16,
            panGroups: [4, 4, 4, 4],
            showCvc: true,
            cvcRequired: true,
            cvcLength: 3,
            cvcLabel: 'CVV',
          ),
        CardInputScheme.autoDetect => _standard,
      };

  // ── Factory: auto-detect from BIN digits ──────────────────────────────────

  /// Derives a config by matching [digits] (raw, no spaces) against known BIN
  /// prefixes. Returns [_standard] when fewer digits are available than needed
  /// to identify the network definitively.
  static _SchemeConfig detect(String digits) {
    // American Express: 34xx / 37xx  (2 digits sufficient)
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

    // Humo: 9860xxxx  (4 digits sufficient)
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

    // Uzcard: 8600xxxx  (4 digits sufficient)
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

    // Visa: 4x  (1 digit sufficient)
    if (digits.isNotEmpty && digits.startsWith('4')) {
      return _standardKnown.copyWith(detectedType: CardType.visa);
    }

    // Mastercard: 51-55  (2 digits) or 2221-2720  (4 digits)
    if (digits.length >= 2 && RegExp(r'^5[1-5]').hasMatch(digits)) {
      return _standardKnown.copyWith(detectedType: CardType.mastercard);
    }
    if (digits.length >= 4 &&
        RegExp(r'^2(2[2-9][1-9]|2[3-9]\d|[3-6]\d{2}|7[01]\d|720)').hasMatch(digits)) {
      return _standardKnown.copyWith(detectedType: CardType.mastercard);
    }

    return _standard; // not yet determined
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
  int get hashCode => Object.hash(panLength, panGroups.length, showCvc, cvcRequired, cvcLength, detectedType);
}

// ─────────────────────────────────────────────────────────────────────────────
// Widget state
// ─────────────────────────────────────────────────────────────────────────────

class _SmartCardInputState extends State<SmartCardInput> {
  final _formKey = GlobalKey<FormState>();
  final _panCtrl = TextEditingController();
  final _expiryCtrl = TextEditingController();
  final _cvvCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();

  late _SchemeConfig _config;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _config = _SchemeConfig.forScheme(widget.scheme);
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
  }

  @override
  void dispose() {
    _panCtrl.dispose();
    _expiryCtrl.dispose();
    _cvvCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  // ── PAN change / auto-detect ───────────────────────────────────────────────

  void _onPanChanged(String value) {
    if (widget.scheme != CardInputScheme.autoDetect) return;
    final digits = value.replaceAll(' ', '');
    final next = _SchemeConfig.detect(digits);
    if (next == _config) return;

    final groupsChanged = next.panGroups.length != _config.panGroups.length ||
        next.panGroups.asMap().entries.any((e) => _config.panGroups[e.key] != e.value);

    setState(() => _config = next);

    // If the PAN grouping changed and there is already formatted text, reformat
    // it immediately so the spaces sit in the right positions.
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

  static String _applyGroups(String digits, List<int> groups) {
    final total = groups.fold(0, (s, g) => s + g);
    final clipped = digits.length > total ? digits.substring(0, total) : digits;
    final buf = StringBuffer();
    int pos = 0;
    for (int g = 0; g < groups.length; g++) {
      if (pos >= clipped.length) break;
      if (g > 0) buf.write(' ');
      final end = (pos + groups[g]).clamp(0, clipped.length);
      buf.write(clipped.substring(pos, end));
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

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final config = _config;

    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── PAN ──────────────────────────────────────────────────────────
          TextFormField(
            controller: _panCtrl,
            decoration: InputDecoration(
              labelText: 'Card number',
              prefixIcon: const Icon(Icons.credit_card),
              hintText: config.panHint,
              suffixIcon: _NetworkBadge(type: config.detectedType),
            ),
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              _CardNumberFormatter(config.panGroups),
            ],
            maxLength: config.formattedPanLength,
            onChanged: _onPanChanged,
            validator: (v) {
              if (v == null || v.isEmpty) return 'Required';
              final digits = v.replaceAll(' ', '');
              if (digits.length < config.panLength) {
                return 'Enter ${config.panLength} digits';
              }
              return null;
            },
          ),

          const SizedBox(height: 12),

          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Expiry ─────────────────────────────────────────────────
              Expanded(
                child: TextFormField(
                  controller: _expiryCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Expiry',
                    prefixIcon: Icon(Icons.date_range),
                    hintText: 'MM/YY',
                  ),
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

              // ── CVC (conditional) ──────────────────────────────────────
              if (config.showCvc) ...[
                const SizedBox(width: 12),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    child: _CvcField(
                      key: ValueKey('${config.cvcLength}-${config.cvcLabel}'),
                      controller: _cvvCtrl,
                      length: config.cvcLength,
                      label: config.cvcLabel,
                      required: config.cvcRequired,
                    ),
                  ),
                ),
              ],
            ],
          ),

          const SizedBox(height: 12),

          // ── Cardholder name (optional) ────────────────────────────────
          TextFormField(
            controller: _nameCtrl,
            decoration: const InputDecoration(
              labelText: 'Cardholder name (optional)',
              prefixIcon: Icon(Icons.person_outline),
              hintText: 'JOHN DOE',
            ),
            textCapitalization: TextCapitalization.characters,
            maxLength: 26,
          ),

          const SizedBox(height: 20),

          // ── Submit ────────────────────────────────────────────────────
          FilledButton.icon(
            onPressed: _submitting ? null : _submit,
            icon: _submitting
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.check),
            label: Text(_submitting ? 'Verifying…' : 'Confirm card'),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// CVC field (extracted to its own widget for AnimatedSwitcher keying)
// ─────────────────────────────────────────────────────────────────────────────

class _CvcField extends StatelessWidget {
  final TextEditingController controller;
  final int length;
  final String label;
  final bool required;

  const _CvcField({
    super.key,
    required this.controller,
    required this.length,
    required this.label,
    required this.required,
  });

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: const Icon(Icons.lock_outline),
        hintText: '•' * length,
        counterText: '',
      ),
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
// Network badge shown as suffixIcon on the PAN field
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

  static String? _label(CardType? type) => switch (type) {
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

  static Color _color(CardType? type) => switch (type) {
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
// Input Formatters
// ─────────────────────────────────────────────────────────────────────────────

/// Formats PAN digits into groups separated by spaces.
///
/// [groups] defines the digit count per group, e.g.:
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
