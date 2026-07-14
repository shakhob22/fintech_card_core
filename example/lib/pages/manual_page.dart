import 'package:fintech_card_core/fintech_card_core.dart';
import 'package:flutter/material.dart';

import '../shared/result_card.dart';
import '../shared/widgets.dart';

class ManualPage extends StatefulWidget {
  final ICardReaderController controller;
  const ManualPage({super.key, required this.controller});

  @override
  State<ManualPage> createState() => _ManualPageState();
}

class _ManualPageState extends State<ManualPage> {
  CardData? _result;
  String? _error;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 8),
          const SectionHeader(
            icon: Icons.keyboard,
            title: 'Manual Entry',
            subtitle: 'Enter card details by hand (Luhn-validated)',
          ),
          const SizedBox(height: 24),

          if (_result != null) ...[
            ResultCard(card: _result!),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: () => setState(() {
                _result = null;
                _error = null;
              }),
              child: const Text('Enter another card'),
            ),
          ] else ...[
            if (_error != null) ErrorBanner(_error!),
            Builder(
              builder: (ctx) {
                final cs = Theme.of(ctx).colorScheme;

                OutlineInputBorder outlined(double w) => OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(
                        color: w > 1 ? cs.primary : cs.outline,
                        width: w,
                      ),
                    );

                InputDecoration field(String label, IconData icon) =>
                    InputDecoration(
                      labelText: label,
                      prefixIcon: Icon(icon),
                      border: outlined(1),
                      enabledBorder: outlined(1),
                      focusedBorder: outlined(2),
                      counterText: '',
                    );

                return SmartCardInput(
                  controller: widget.controller,
                  showNfcButton: true,
                  scheme: CardInputScheme.autoDetect,
                  style: SmartCardInputStyle(
                    panDecoration: field('Card number', Icons.credit_card),
                    expiryDecoration: field('Expiry', Icons.date_range),
                    nameDecoration: field(
                      'Cardholder name (optional)',
                      Icons.person_outline,
                    ),
                  ),
                  onSuccess: (card) => setState(() {
                    _result = card;
                    _error = null;
                  }),
                  onError: (e) => setState(() {
                    _error = e.toString();
                    _result = null;
                  }),
                );
              },
            ),
          ],
        ],
      ),
    );
  }
}
