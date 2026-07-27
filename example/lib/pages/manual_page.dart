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
  CardInputScheme _scheme = CardInputScheme.autoDetect;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionHeader(
            icon: Icons.keyboard,
            title: 'Manual',
            subtitle: 'Enter card details — Luhn-validated',
          ),
          const SizedBox(height: 20),
          DropdownMenu<CardInputScheme>(
            initialSelection: _scheme,
            label: const Text('Input scheme'),
            expandedInsets: EdgeInsets.zero,
            onSelected: (v) {
              if (v == null) return;
              setState(() {
                _scheme = v;
                _result = null;
                _error = null;
              });
            },
            dropdownMenuEntries: const [
              DropdownMenuEntry(
                value: CardInputScheme.autoDetect,
                label: 'Auto-detect',
              ),
              DropdownMenuEntry(
                value: CardInputScheme.visaAndMastercard,
                label: 'Visa / Mastercard',
              ),
              DropdownMenuEntry(
                value: CardInputScheme.americanExpress,
                label: 'American Express',
              ),
              DropdownMenuEntry(
                value: CardInputScheme.humoAndUzcard,
                label: 'Humo / Uzcard',
              ),
            ],
          ),
          const SizedBox(height: 20),
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
            if (_error != null) ...[
              ErrorBanner(_error!),
              const SizedBox(height: 12),
            ],
            SmartCardInput(
              key: ValueKey(_scheme),
              controller: widget.controller,
              scheme: _scheme,
              showNfcButton: true,
              showCameraButton: true,
              // Demo: private-label / partner BINs the plugin doesn't know.
              // Try typing 1212…, 088…, or 99… in the card-number field.
              customBrandBadges: [
                CardBrandBadge(
                  prefix: '1212',
                  badge: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1B5E20),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text(
                      'BANK',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.6,
                      ),
                    ),
                  ),
                ),
                CardBrandBadge(
                  prefix: '088',
                  badge: const Icon(Icons.account_balance, size: 22, color: Color(0xFF1565C0)),
                ),
                CardBrandBadge(
                  prefix: '99',
                  badge: const Text(
                    'MY',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 14,
                      color: Color(0xFF6A1B9A),
                    ),
                  ),
                ),
              ],
              onSuccess: (card) => setState(() {
                _result = card;
                _error = null;
              }),
              onError: (e) => setState(() {
                _error = e.toString();
                _result = null;
              }),
            ),
          ],
        ],
      ),
    );
  }
}
