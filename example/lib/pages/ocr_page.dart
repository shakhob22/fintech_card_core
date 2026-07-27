import 'package:fintech_card_core/fintech_card_core.dart';
import 'package:flutter/material.dart';

import '../shared/result_card.dart';
import '../shared/widgets.dart';

class OcrPage extends StatefulWidget {
  final ICardReaderController controller;

  const OcrPage({super.key, required this.controller});

  @override
  State<OcrPage> createState() => _OcrPageState();
}

class _OcrPageState extends State<OcrPage> {
  CardData? _result;

  Future<void> _scan({
    Widget? title,
    Widget? subtitle,
    CardScannerOverlayTheme theme = const CardScannerOverlayTheme(),
    bool enableCoachingHints = true,
    String? sideLightHint,
    String? torchHint,
  }) async {
    final card = await CardScannerOverlay.show(
      context,
      controller: widget.controller,
      title: title,
      subtitle: subtitle,
      theme: theme,
      enableCoachingHints: enableCoachingHints,
      sideLightHint: sideLightHint,
      torchHint: torchHint,
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
            icon: Icons.camera_alt_outlined,
            title: 'Camera',
            subtitle: 'Scan card digits with the on-device OCR engine',
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
              icon: const Icon(Icons.camera_alt),
              label: const Text('Scan with camera'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => _scan(
                title: const Text(
                  'Scan your card',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                subtitle: const Text(
                  'Position the card inside the frame',
                  style: TextStyle(color: Colors.white70, fontSize: 14),
                ),
                theme: const CardScannerOverlayTheme(
                  cornerColor: Colors.cyanAccent,
                  cornerStrokeWidth: 4,
                  cornerRadius: 28,
                  cornerLength: 36,
                ),
                sideLightHint: 'Try side lighting for embossed digits',
                torchHint: 'Too bright? Back up and turn on the torch',
              ),
              icon: const Icon(Icons.palette_outlined),
              label: const Text('Scan with custom overlay'),
            ),
          ],
        ],
      ),
    );
  }
}
