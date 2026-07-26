import 'package:fintech_card_core/fintech_card_core.dart';
import 'package:flutter/material.dart';

import '../shared/result_card.dart';
import '../shared/widgets.dart';

class NfcPage extends StatefulWidget {
  final ICardReaderController controller;

  const NfcPage({super.key, required this.controller});

  @override
  State<NfcPage> createState() => _NfcPageState();
}

class _NfcPageState extends State<NfcPage> {
  CardData? _result;

  Future<void> _scan({NfcScanDialogTheme theme = const NfcScanDialogTheme()}) async {
    final card = await NfcScanDialog.show(
      context,
      controller: widget.controller,
      theme: theme,
    );
    if (card != null && mounted) setState(() => _result = card);
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionHeader(
            icon: Icons.nfc,
            title: 'NFC',
            subtitle: 'Read a payment card over NFC / EMV',
          ),
          const SizedBox(height: 28),
          if (_result != null) ...[
            ResultCard(card: _result!),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: () => setState(() => _result = null),
              child: const Text('Scan another card'),
            ),
          ] else ...[
            FilledButton.icon(
              onPressed: () => _scan(),
              icon: const Icon(Icons.nfc),
              label: const Text('Scan with NFC'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => _scan(
                theme: const NfcScanDialogTheme(
                  titleScanning: 'Ready to scan',
                  titleSuccess: 'Card detected',
                  titleError: 'Scan failed',
                  initialMessage: 'Hold your card near the device…',
                  successMessage: 'Card read successfully.',
                  cancelLabel: 'Cancel',
                  retryLabel: 'Try again',
                  showRetryOnError: true,
                  scanningIconColor: Colors.indigo,
                  successIconColor: Colors.teal,
                  successIconBackgroundColor: Color(0xFFE0F2F1),
                ),
              ),
              icon: const Icon(Icons.palette_outlined),
              label: const Text('Scan with custom theme'),
            ),
          ],
        ],
      ),
    );
  }
}
