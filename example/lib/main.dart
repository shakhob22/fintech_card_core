import 'package:fintech_card_core/fintech_card_core.dart';
import 'package:flutter/material.dart';

void main() => runApp(const ExampleApp());

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'fintech_card_core demo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Home — tab navigator
// ─────────────────────────────────────────────────────────────────────────────

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  // Single controller shared across all tabs
  final _controller = CardReaderController();
  int _selectedTab = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tabs = [
      _NfcTab(controller: _controller),
      _ManualTab(controller: _controller),
      _MockTab(controller: _controller),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('fintech_card_core'),
        centerTitle: true,
      ),
      body: tabs[_selectedTab],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedTab,
        onDestinationSelected: (i) => setState(() => _selectedTab = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.nfc_outlined),
            selectedIcon: Icon(Icons.nfc),
            label: 'NFC',
          ),
          NavigationDestination(
            icon: Icon(Icons.keyboard_outlined),
            selectedIcon: Icon(Icons.keyboard),
            label: 'Manual',
          ),
          NavigationDestination(
            icon: Icon(Icons.science_outlined),
            selectedIcon: Icon(Icons.science),
            label: 'Mock',
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared result card widget
// ─────────────────────────────────────────────────────────────────────────────

class _ResultCard extends StatelessWidget {
  final CardData card;
  const _ResultCard({required this.card});

  static const _networkIcons = {
    CardType.visa: '💳',
    CardType.mastercard: '🔴',
    CardType.amex: '🟦',
    CardType.discover: '🟠',
    CardType.unionPay: '🔵',
    CardType.jcb: '🟢',
    CardType.unknown: '❓',
  };

  static const _modeLabels = {
    CardReadMode.nfc: 'NFC',
    CardReadMode.ocr: 'OCR',
    CardReadMode.manual: 'Manual',
    CardReadMode.mock: 'Mock',
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
            _Row('Expiry', card.expiryDate),
            if (card.cvv != null) _Row('CVV', '•' * card.cvv!.length),
            if (card.cardholderName != null)
              _Row('Name', card.cardholderName!),
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

// ─────────────────────────────────────────────────────────────────────────────
// Tab 1 — NFC
// ─────────────────────────────────────────────────────────────────────────────

class _NfcTab extends StatefulWidget {
  final ICardReaderController controller;
  const _NfcTab({required this.controller});

  @override
  State<_NfcTab> createState() => _NfcTabState();
}

class _NfcTabState extends State<_NfcTab> {
  CardReaderState _state = const CardReaderIdleState();

  @override
  void initState() {
    super.initState();
    widget.controller.stateStream.listen((s) {
      if (mounted) setState(() => _state = s);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scanning = _state is CardReaderScanningState;

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 16),
          _SectionHeader(
            icon: Icons.nfc,
            title: 'NFC Card Read',
            subtitle: 'Tap your physical EMV card to read it',
          ),
          const SizedBox(height: 24),

          if (_state is CardReaderSuccessState)
            _ResultCard(card: (_state as CardReaderSuccessState).data)
          else if (_state is CardReaderErrorState)
            _ErrorBanner((_state as CardReaderErrorState).exception.message)
          else if (_state is CardReaderScanningState)
            _ScanningIndicator(
              message: (_state as CardReaderScanningState).message
                  ?? 'Scanning…',
            ),

          const Spacer(),

          FilledButton.icon(
            onPressed: scanning
                ? () => widget.controller.stopNfcScan()
                : () => NfcScanDialog.show(
                    context,
                    controller: widget.controller,
                  ),
            icon: Icon(scanning ? Icons.stop : Icons.nfc),
            label: Text(scanning ? 'Stop' : 'Start NFC Scan'),
            style: scanning
                ? FilledButton.styleFrom(
                    backgroundColor: Colors.red.shade400,
                  )
                : null,
          ),
          const SizedBox(height: 12),
          if (_state is! CardReaderIdleState)
            OutlinedButton(
              onPressed: () {
                widget.controller.reset();
                setState(() => _state = const CardReaderIdleState());
              },
              child: const Text('Reset'),
            ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tab 2 — Manual Input
// ─────────────────────────────────────────────────────────────────────────────

class _ManualTab extends StatefulWidget {
  final ICardReaderController controller;
  const _ManualTab({required this.controller});

  @override
  State<_ManualTab> createState() => _ManualTabState();
}

class _ManualTabState extends State<_ManualTab> {
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
          _SectionHeader(
            icon: Icons.keyboard,
            title: 'Manual Entry',
            subtitle: 'Enter card details by hand (Luhn-validated)',
          ),
          const SizedBox(height: 24),

          if (_result != null) ...[
            _ResultCard(card: _result!),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: () => setState(() { _result = null; _error = null; }),
              child: const Text('Enter another card'),
            ),
          ] else ...[
            if (_error != null) _ErrorBanner(_error!),
            SmartCardInput(
              controller: widget.controller,
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

// ─────────────────────────────────────────────────────────────────────────────
// Tab 3 — Mock / Developer Mode
// ─────────────────────────────────────────────────────────────────────────────

class _MockTab extends StatefulWidget {
  final ICardReaderController controller;
  const _MockTab({required this.controller});

  @override
  State<_MockTab> createState() => _MockTabState();
}

class _MockTabState extends State<_MockTab> {
  MockCardPreset _preset = MockCardPreset.visa;
  Duration _delay = const Duration(seconds: 1);
  bool _simulateError = false;
  CardData? _result;
  String? _error;
  bool _loading = false;

  static const _presets = [
    (MockCardPreset.visa,       'Visa',       Colors.blue),
    (MockCardPreset.mastercard, 'Mastercard', Colors.red),
    (MockCardPreset.amex,       'Amex',       Colors.green),
    (MockCardPreset.discover,   'Discover',   Colors.orange),
    (MockCardPreset.declined,   'Declined',   Colors.red),
    (MockCardPreset.expired,    'Expired',    Colors.grey),
  ];

  Future<void> _run() async {
    setState(() { _loading = true; _result = null; _error = null; });
    try {
      final card = await widget.controller.loadMockCard(
        preset: _preset,
        simulatedDelay: _delay,
        simulateError: _simulateError,
      );
      if (mounted) setState(() { _result = card; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
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
          _SectionHeader(
            icon: Icons.science,
            title: 'Developer Mode',
            subtitle: 'Simulate card reads without real hardware',
          ),
          const SizedBox(height: 20),

          // ── Preset picker ─────────────────────────────────────────────
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

          // ── Delay slider ──────────────────────────────────────────────
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

          // ── Simulate error toggle ─────────────────────────────────────
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Simulate error (declined)'),
            value: _simulateError,
            onChanged: (v) => setState(() => _simulateError = v),
          ),

          const SizedBox(height: 16),

          // ── Result / error ────────────────────────────────────────────
          if (_loading)
            _ScanningIndicator(
              message: 'Loading mock card (${_delay.inMilliseconds}ms)…',
            )
          else if (_result != null)
            _ResultCard(card: _result!)
          else if (_error != null)
            _ErrorBanner(_error!),

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

// ─────────────────────────────────────────────────────────────────────────────
// Small shared widgets
// ─────────────────────────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  const _SectionHeader({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: theme.colorScheme.secondaryContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: theme.colorScheme.onSecondaryContainer),
        ),
        const SizedBox(width: 14),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.titleMedium),
            Text(
              subtitle,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _ScanningIndicator extends StatelessWidget {
  final String message;
  const _ScanningIndicator({required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(message, style: Theme.of(context).textTheme.bodyMedium),
          ),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  final String message;
  const _ErrorBanner(this.message);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.red.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.red.shade200),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: Colors.red.shade700, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: Colors.red.shade800, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
