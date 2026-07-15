import 'package:fintech_card_core/fintech_card_core.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key});

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  final CardReaderController _controller = CardReaderController();
  CardData? _lastCard;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _showResult(CardData card) {
    setState(() => _lastCard = card);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('✓ ${card.maskedPan}  ${card.expiryDate}'),
        backgroundColor: Colors.green.shade700,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('fintech_card_core demo')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── SmartCardInput with both NFC & Camera buttons ──────────────
            SmartCardInput(
              controller: _controller,
              onSuccess: _showResult,
              showCameraButton: true,

            ),

            const SizedBox(height: 24),
            const Divider(),
            const SizedBox(height: 8),

            // ── NFC scan dialog ────────────────────────────────────────────
            ElevatedButton.icon(
              icon: const Icon(Icons.nfc),
              label: const Text('NFC Scan'),
              onPressed: () async {
                final card = await NfcScanDialog.show(
                  context,
                  controller: _controller,
                );
                if (card != null) _showResult(card);
              },
            ),

            const SizedBox(height: 12),

            // ── Camera scan overlay ────────────────────────────────────────
            ElevatedButton.icon(
              icon: const Icon(Icons.camera_alt),
              label: const Text('Camera Scan'),
              onPressed: () async {
                final card = await CardScannerOverlay.show(
                  context,
                  controller: _controller,
                  theme: CardScannerOverlayTheme(
                    title: 'Kartani skanerlash',
                    subtitle: 'qwdqwd',

                    retryLabel: 'Qayta urinish',
                    initialMessage: 'Kamerani kartangizga yo\'naltiring…',
                    cancelLabel: 'Bekor qilish',
                  )
                  // theme: const CardScannerOverlayTheme(
                  //   title: 'Kartani skanerlash',
                  //   initialMessage: 'Kamerani kartangizga yo\'naltiring…',
                  //   successMessage: 'Karta muvaffaqiyatli o\'qildi!',
                  //   cancelLabel: 'Bekor qilish',
                  //   showRetryOnError: true,
                  //   retryLabel: 'Qayta urinish',
                  // ),
                );
                if (card != null) _showResult(card);
              },
            ),

            const SizedBox(height: 12),

            // ── NFC scan (custom themed) ───────────────────────────────────
            ElevatedButton.icon(
              icon: const Icon(Icons.nfc_rounded),
              label: const Text('NFC Scan (custom theme)'),
              onPressed: () async {
                final card = await NfcScanDialog.show(
                  context,
                  controller: _controller,
                  theme: const NfcScanDialogTheme(
                    titleScanning: 'Skanerlashga tayyor',
                    titleSuccess: 'Karta aniqlandi',
                    titleError: 'Xatolik yuz berdi',
                    initialMessage: 'Kartangizni qurilma yoniga tuting…',
                    successMessage: 'Karta muvaffaqiyatli o\'qildi!',
                    cancelLabel: 'Bekor qilish',
                    showRetryOnError: true,
                  ),
                );
                if (card != null) _showResult(card);
              },
            ),

            // ── Last scanned card result ───────────────────────────────────
            if (_lastCard != null) ...[
              const SizedBox(height: 24),
              const Divider(),
              const SizedBox(height: 8),
              _CardResultTile(card: _lastCard!),
            ],
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Result display widget
// ─────────────────────────────────────────────────────────────────────────────

class _CardResultTile extends StatelessWidget {
  final CardData card;
  const _CardResultTile({required this.card});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.credit_card, color: t.colorScheme.primary),
                const SizedBox(width: 8),
                Text(
                  'Last scanned card',
                  style: t.textTheme.titleSmall,
                ),
                const Spacer(),
                _ModeChip(mode: card.readMode),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              card.formattedPan,
              style: t.textTheme.headlineSmall?.copyWith(
                fontFamily: 'monospace',
                letterSpacing: 2,
              ),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Text('Expires: ${card.expiryDate}',
                    style: t.textTheme.bodyMedium),
                const Spacer(),
                Text(
                  card.cardType.name.toUpperCase(),
                  style: t.textTheme.labelSmall?.copyWith(
                    color: t.colorScheme.primary,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ModeChip extends StatelessWidget {
  final CardReadMode mode;
  const _ModeChip({required this.mode});

  @override
  Widget build(BuildContext context) {
    final (label, icon) = switch (mode) {
      CardReadMode.nfc    => ('NFC', Icons.nfc),
      CardReadMode.ocr    => ('Camera', Icons.camera_alt),
      CardReadMode.manual => ('Manual', Icons.keyboard),
      CardReadMode.mock   => ('Mock', Icons.science),
    };
    return Chip(
      avatar: Icon(icon, size: 14),
      label: Text(label),
      labelStyle: Theme.of(context).textTheme.labelSmall,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
    );
  }
}
