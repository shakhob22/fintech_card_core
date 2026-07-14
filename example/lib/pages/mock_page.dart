import 'package:fintech_card_core/fintech_card_core.dart';
import 'package:flutter/material.dart';

import '../shared/result_card.dart';
import '../shared/widgets.dart';

class MockPage extends StatefulWidget {
  final ICardReaderController controller;
  const MockPage({super.key, required this.controller});

  @override
  State<MockPage> createState() => _MockPageState();
}

class _MockPageState extends State<MockPage> {
  MockCardPreset _preset = MockCardPreset.visa;
  Duration _delay = const Duration(seconds: 1);
  bool _simulateError = false;
  CardData? _result;
  String? _error;
  bool _loading = false;

  static const _presets = [
    (MockCardPreset.visa, 'Visa', Colors.blue),
    (MockCardPreset.mastercard, 'Mastercard', Colors.red),
    (MockCardPreset.amex, 'Amex', Colors.green),
    (MockCardPreset.discover, 'Discover', Colors.orange),
    (MockCardPreset.declined, 'Declined', Colors.red),
    (MockCardPreset.expired, 'Expired', Colors.grey),
  ];

  Future<void> _run() async {
    setState(() {
      _loading = true;
      _result = null;
      _error = null;
    });
    try {
      final card = await widget.controller.loadMockCard(
        preset: _preset,
        simulatedDelay: _delay,
        simulateError: _simulateError,
      );
      if (mounted) {
        setState(() {
          _result = card;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 8),
          const SectionHeader(
            icon: Icons.science,
            title: 'Developer Mode',
            subtitle: 'Simulate card reads without real hardware',
          ),
          const SizedBox(height: 20),

          // ── Preset picker ───────────────────────────────────────────────────
          Text('Card preset', style: theme.textTheme.labelMedium),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _presets.map((p) {
              final (preset, label, color) = p;
              final selected = _preset == preset;
              return FilterChip(
                label: Text(label),
                selected: selected,
                selectedColor: color.withAlpha(40),
                checkmarkColor: color,
                onSelected: (_) => setState(() => _preset = preset),
              );
            }).toList(),
          ),

          const SizedBox(height: 20),

          // ── Delay slider ────────────────────────────────────────────────────
          Row(
            children: [
              Text('Simulated delay', style: theme.textTheme.labelMedium),
              const Spacer(),
              Text(
                '${_delay.inMilliseconds}ms',
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          Slider(
            value: _delay.inMilliseconds.toDouble(),
            min: 0,
            max: 5000,
            divisions: 20,
            label: '${_delay.inMilliseconds}ms',
            onChanged: (v) =>
                setState(() => _delay = Duration(milliseconds: v.toInt())),
          ),

          const SizedBox(height: 4),

          // ── Simulate error toggle ───────────────────────────────────────────
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Simulate error (declined)'),
            value: _simulateError,
            onChanged: (v) => setState(() => _simulateError = v),
          ),

          const SizedBox(height: 16),

          // ── Result / error ──────────────────────────────────────────────────
          if (_loading)
            ScanningIndicator(
              message: 'Loading mock card (${_delay.inMilliseconds}ms)…',
            )
          else if (_result != null)
            ResultCard(card: _result!)
          else if (_error != null)
            ErrorBanner(_error!),

          const SizedBox(height: 20),

          FilledButton.icon(
            onPressed: _loading ? null : _run,
            icon: _loading
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.play_arrow),
            label: Text(_loading ? 'Loading…' : 'Run mock'),
          ),
        ],
      ),
    );
  }
}
