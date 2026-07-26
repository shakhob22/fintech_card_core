import 'package:fintech_card_core/fintech_card_core.dart';
import 'package:flutter/material.dart';

class ResultCard extends StatelessWidget {
  final CardData card;
  const ResultCard({super.key, required this.card});

  static const _networkIcons = {
    CardType.visa: '💳',
    CardType.mastercard: '🔴',
    CardType.amex: '🟦',
    CardType.discover: '🟠',
    CardType.unionPay: '🔵',
    CardType.jcb: '🟢',
    CardType.humo: '🟩',
    CardType.uzcard: '🔷',
    CardType.unknown: '❓',
  };

  static const _modeLabels = {
    CardReadMode.nfc: 'NFC',
    CardReadMode.ocr: 'OCR',
    CardReadMode.manual: 'Manual',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Card(
      color: cs.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  _networkIcons[card.cardType] ?? '💳',
                  style: const TextStyle(fontSize: 28),
                ),
                const SizedBox(width: 10),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      card.cardType.name.toUpperCase(),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: cs.onPrimaryContainer,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.2,
                      ),
                    ),
                    Text(
                      'via ${_modeLabels[card.readMode]}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: cs.onPrimaryContainer.withAlpha(180),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 16),
            _Row('PAN', card.formattedPan, monospace: true),
            _Row('Masked', card.maskedPan),
            _Row('Expiry', card.expiryDate ?? '—'),
            if (card.cvv != null) _Row('CVV', '•' * card.cvv!.length),
            if (card.cardholderName != null)
              _Row('Name', card.cardholderName!),
            _Row(
              'At',
              TimeOfDay.fromDateTime(card.timestamp.toLocal()).format(context),
            ),
          ],
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  final String label;
  final String value;
  final bool monospace;
  const _Row(this.label, this.value, {this.monospace = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 64,
            child: Text(
              label,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onPrimaryContainer.withAlpha(170),
              ),
            ),
          ),
          Text(
            value,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontFamily: monospace ? 'monospace' : null,
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onPrimaryContainer,
            ),
          ),
        ],
      ),
    );
  }
}
