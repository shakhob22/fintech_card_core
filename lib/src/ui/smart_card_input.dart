import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/card_reader_controller.dart';
import '../core/models/card_data.dart';

/// An optional pre-built manual-entry form for payment card data.
///
/// This widget is a convenience helper — applications are free to build their
/// own UI and call [ICardReaderController.submitManualInput] directly.
///
/// Usage:
/// ```dart
/// SmartCardInput(
///   controller: myController,
///   onSuccess: (card) => print(card.maskedPan),
///   onError: (ex) => showSnackBar(ex.message),
/// )
/// ```
class SmartCardInput extends StatefulWidget {
  final ICardReaderController controller;
  final void Function(CardData card)? onSuccess;
  final void Function(Object error)? onError;

  const SmartCardInput({
    super.key,
    required this.controller,
    this.onSuccess,
    this.onError,
  });

  @override
  State<SmartCardInput> createState() => _SmartCardInputState();
}

class _SmartCardInputState extends State<SmartCardInput> {
  final _formKey = GlobalKey<FormState>();
  final _panCtrl = TextEditingController();
  final _expiryCtrl = TextEditingController();
  final _cvvCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();

  bool _submitting = false;

  @override
  void dispose() {
    _panCtrl.dispose();
    _expiryCtrl.dispose();
    _cvvCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _submitting = true);

    try {
      final card = await widget.controller.submitManualInput(
        pan: _panCtrl.text,
        expiryDate: _expiryCtrl.text,
        cvv: _cvvCtrl.text.isEmpty ? null : _cvvCtrl.text,
        cardholderName: _nameCtrl.text.isEmpty ? null : _nameCtrl.text.trim(),
      );
      widget.onSuccess?.call(card);
    } catch (e) {
      widget.onError?.call(e);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── PAN ──────────────────────────────────────────────────────────
          TextFormField(
            controller: _panCtrl,
            decoration: const InputDecoration(
              labelText: 'Card number',
              prefixIcon: Icon(Icons.credit_card),
              hintText: '0000 0000 0000 0000',
            ),
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              _CardNumberFormatter(),
            ],
            maxLength: 23, // 19 digits + 4 spaces
            validator: (v) {
              if (v == null || v.isEmpty) return 'Required';
              final digits = v.replaceAll(' ', '');
              if (digits.length < 13) return 'Too short';
              return null;
            },
          ),

          const SizedBox(height: 12),

          Row(children: [
            // ── Expiry ───────────────────────────────────────────────────
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

            const SizedBox(width: 12),

            // ── CVV ──────────────────────────────────────────────────────
            Expanded(
              child: TextFormField(
                controller: _cvvCtrl,
                decoration: const InputDecoration(
                  labelText: 'CVV',
                  prefixIcon: Icon(Icons.lock_outline),
                  hintText: '•••',
                ),
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                maxLength: 4,
                obscureText: true,
              ),
            ),
          ]),

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
// Input Formatters
// ─────────────────────────────────────────────────────────────────────────────

class _CardNumberFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final digits = newValue.text.replaceAll(' ', '');
    final buffer = StringBuffer();
    for (int i = 0; i < digits.length; i++) {
      if (i > 0 && i % 4 == 0) buffer.write(' ');
      buffer.write(digits[i]);
    }
    final formatted = buffer.toString();
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

    final buffer = StringBuffer(digits.substring(0, digits.length.clamp(0, 2)));
    if (digits.length > 2) {
      buffer.write('/');
      buffer.write(digits.substring(2, digits.length.clamp(2, 4)));
    }
    final formatted = buffer.toString();
    return newValue.copyWith(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }
}
