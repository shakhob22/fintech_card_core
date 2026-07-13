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
    CardType.humo: '🟩',
    CardType.uzcard: '🔷',
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
// Tab 1 — NFC  (demonstrates all three usage modes)
// ─────────────────────────────────────────────────────────────────────────────

/// Which NFC usage mode the user has selected in the demo.
enum _NfcMode { defaultDialog, customDialog, headless }

class _NfcTab extends StatefulWidget {
  final ICardReaderController controller;
  const _NfcTab({required this.controller});

  @override
  State<_NfcTab> createState() => _NfcTabState();
}

class _NfcTabState extends State<_NfcTab> {
  _NfcMode _mode = _NfcMode.defaultDialog;

  // State used only by headless mode
  CardReaderState _headlessState = const CardReaderIdleState();

  @override
  void initState() {
    super.initState();
    // For headless mode we listen to the controller stream directly
    widget.controller.stateStream.listen((s) {
      if (mounted) setState(() => _headlessState = s);
    });
  }

  // ── Mode selector ──────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 16),
          _SectionHeader(
            icon: Icons.nfc,
            title: 'NFC Card Read',
            subtitle: 'Choose a usage mode below',
          ),
          const SizedBox(height: 20),

          // ── Mode toggle ────────────────────────────────────────────────────
          SegmentedButton<_NfcMode>(
            segments: const [
              ButtonSegment(
                value: _NfcMode.defaultDialog,
                label: Text('Default'),
                icon: Icon(Icons.widgets_outlined),
              ),
              ButtonSegment(
                value: _NfcMode.customDialog,
                label: Text('Custom'),
                icon: Icon(Icons.palette_outlined),
              ),
              ButtonSegment(
                value: _NfcMode.headless,
                label: Text('Headless'),
                icon: Icon(Icons.code),
              ),
            ],
            selected: {_mode},
            onSelectionChanged: (s) {
              widget.controller.reset();
              setState(() {
                _mode = s.first;
                _headlessState = const CardReaderIdleState();
              });
            },
          ),

          const SizedBox(height: 28),

          switch (_mode) {
            _NfcMode.defaultDialog => _DefaultDialogSection(
                controller: widget.controller,
              ),
            _NfcMode.customDialog => _CustomDialogSection(
                controller: widget.controller,
              ),
            _NfcMode.headless => _HeadlessSection(
                controller: widget.controller,
                state: _headlessState,
                onReset: () {
                  widget.controller.reset();
                  setState(() => _headlessState = const CardReaderIdleState());
                },
              ),
          },
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Mode 1 — Default built-in dialog
// ─────────────────────────────────────────────────────────────────────────────

class _DefaultDialogSection extends StatefulWidget {
  final ICardReaderController controller;
  const _DefaultDialogSection({required this.controller});

  @override
  State<_DefaultDialogSection> createState() => _DefaultDialogSectionState();
}

class _DefaultDialogSectionState extends State<_DefaultDialogSection> {
  CardData? _result;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ModeDescription(
          icon: Icons.widgets_outlined,
          title: 'Default Dialog',
          description:
              'Use NfcScanDialog.show() to launch the plugin\'s built-in '
              'bottom-sheet. No extra setup needed.',
          codeSnippet: "final card = await NfcScanDialog.show(\n"
              "  context,\n"
              "  controller: controller,\n"
              ");",
        ),
        const SizedBox(height: 20),
        if (_result != null) ...[
          _ResultCard(card: _result!),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: () => setState(() => _result = null),
            child: const Text('Scan another'),
          ),
        ] else
          FilledButton.icon(
            onPressed: () async {
              final card = await NfcScanDialog.show(
                context,
                controller: widget.controller,
              );
              if (card != null && mounted) setState(() => _result = card);
            },
            icon: const Icon(Icons.nfc),
            label: const Text('Start NFC Scan'),
          ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Mode 2 — Custom-themed dialog
// ─────────────────────────────────────────────────────────────────────────────

class _CustomDialogSection extends StatefulWidget {
  final ICardReaderController controller;
  const _CustomDialogSection({required this.controller});

  @override
  State<_CustomDialogSection> createState() => _CustomDialogSectionState();
}

class _CustomDialogSectionState extends State<_CustomDialogSection> {
  CardData? _result;

  static const _customTheme = NfcScanDialogTheme(
    titleScanning: 'Skanerlashga tayyor',
    titleSuccess: 'Karta aniqlandi',
    titleError: 'Xatolik yuz berdi',
    initialMessage: 'Kartangizni qurilma yoniga tuting…',
    successMessage: 'Karta muvaffaqiyatli o\'qildi!',
    cancelLabel: 'Bekor qilish',
    retryLabel: 'Qayta urinish',
    showRetryOnError: true,
    successIconColor: Colors.teal,
    successIconBackgroundColor: Color(0xFFE0F2F1),
    scanningIconColor: Colors.indigo,
    successDismissDelay: Duration(seconds: 1),
  );

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ModeDescription(
          icon: Icons.palette_outlined,
          title: 'Custom-Themed Dialog',
          description:
              'Pass a NfcScanDialogTheme to customise labels (great for '
              'localisation), colours, icons, and retry behaviour.',
          codeSnippet: "final card = await NfcScanDialog.show(\n"
              "  context,\n"
              "  controller: controller,\n"
              "  theme: const NfcScanDialogTheme(\n"
              "    titleScanning:  'Skanerlashga tayyor',\n"
              "    cancelLabel:    'Bekor qilish',\n"
              "    showRetryOnError: true,\n"
              "  ),\n"
              ");",
        ),
        const SizedBox(height: 8),
        _ThemePreviewChips(),
        const SizedBox(height: 16),
        if (_result != null) ...[
          _ResultCard(card: _result!),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: () => setState(() => _result = null),
            child: const Text('Scan another'),
          ),
        ] else
          FilledButton.icon(
            onPressed: () async {
              final card = await NfcScanDialog.show(
                context,
                controller: widget.controller,
                theme: _customTheme,
              );
              if (card != null && mounted) setState(() => _result = card);
            },
            icon: const Icon(Icons.nfc),
            label: const Text('Start with custom theme'),
          ),
      ],
    );
  }
}

/// Small chips that preview which custom properties are set.
class _ThemePreviewChips extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final chips = [
      'Uzbek labels',
      'Teal success colour',
      'Retry on error button',
      '1 s dismiss delay',
    ];
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: chips
          .map((label) => Chip(
                label: Text(label,
                    style: Theme.of(context).textTheme.labelSmall),
                padding: EdgeInsets.zero,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ))
          .toList(),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Mode 3 — Headless (no built-in UI)
// ─────────────────────────────────────────────────────────────────────────────

class _HeadlessSection extends StatelessWidget {
  final ICardReaderController controller;
  final CardReaderState state;
  final VoidCallback onReset;

  const _HeadlessSection({
    required this.controller,
    required this.state,
    required this.onReset,
  });

  @override
  Widget build(BuildContext context) {
    final scanning = state is CardReaderScanningState;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ModeDescription(
          icon: Icons.code,
          title: 'Headless Mode',
          description:
              'Call controller.startNfcScan() directly and listen to '
              'stateStream. Build any UI you want — the plugin only '
              'provides the NFC + EMV logic.',
          codeSnippet: "controller.stateStream.listen((state) {\n"
              "  switch (state) {\n"
              "    case CardReaderScanningState(:final message):\n"
              "      // update your own UI\n"
              "    case CardReaderSuccessState(:final data):\n"
              "      // use data.pan, data.expiryDate, …\n"
              "    case CardReaderErrorState(:final exception):\n"
              "      // show error\n"
              "  }\n"
              "});\n"
              "await controller.startNfcScan();",
        ),
        const SizedBox(height: 20),

        // ── Live state display (your own custom UI) ────────────────────────
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          child: switch (state) {
            CardReaderSuccessState(:final data) => _ResultCard(card: data),
            CardReaderErrorState(:final exception) =>
              _ErrorBanner(exception.message),
            CardReaderScanningState(:final message) => _HeadlessScanningCard(
                message: message ?? 'Scanning…',
              ),
            _ => const SizedBox.shrink(),
          },
        ),

        const SizedBox(height: 20),

        FilledButton.icon(
          onPressed: scanning
              ? () => controller.stopNfcScan()
              : () => controller.startNfcScan(),
          icon: Icon(scanning ? Icons.stop : Icons.nfc),
          label: Text(scanning ? 'Stop Scan' : 'Start Headless Scan'),
          style: scanning
              ? FilledButton.styleFrom(
                  backgroundColor: Colors.red.shade400,
                )
              : null,
        ),
        const SizedBox(height: 12),
        if (state is! CardReaderIdleState)
          OutlinedButton(onPressed: onReset, child: const Text('Reset')),
      ],
    );
  }
}

/// Example of a completely custom scanning card widget.
class _HeadlessScanningCard extends StatelessWidget {
  final String message;
  const _HeadlessScanningCard({required this.message});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: cs.secondaryContainer,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.secondary.withAlpha(80)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              color: cs.secondary,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: cs.onSecondaryContainer,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared helper — collapsible mode description + code snippet
// ─────────────────────────────────────────────────────────────────────────────

class _ModeDescription extends StatefulWidget {
  final IconData icon;
  final String title;
  final String description;
  final String codeSnippet;

  const _ModeDescription({
    required this.icon,
    required this.title,
    required this.description,
    required this.codeSnippet,
  });

  @override
  State<_ModeDescription> createState() => _ModeDescriptionState();
}

class _ModeDescriptionState extends State<_ModeDescription> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(widget.icon, size: 20, color: cs.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      widget.title,
                      style: t.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),
                  ),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    color: cs.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text(
                widget.description,
                style: t.textTheme.bodySmall
                    ?.copyWith(color: cs.onSurfaceVariant),
              ),
            ),
            Container(
              margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: cs.surface,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: cs.outlineVariant),
              ),
              child: Text(
                widget.codeSnippet,
                style: t.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  color: cs.onSurface,
                ),
              ),
            ),
          ],
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
            Builder(builder: (ctx) {
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
                onNfcSuccess: (card) {
                  print(card.cardType);
                  print(card.cardholderName);
                  print(card.cvv);
                  print(card.expiryDate);
                  print(card.formattedPan);
                  print(card.maskedPan);
                  print(card.pan);
                  print(card.readMode);
                  print(card.props);
                },
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
            }),
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
