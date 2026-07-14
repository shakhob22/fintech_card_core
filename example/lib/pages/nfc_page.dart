import 'dart:async';

import 'package:fintech_card_core/fintech_card_core.dart';
import 'package:flutter/material.dart';

import '../shared/result_card.dart';
import '../shared/widgets.dart';

// ─────────────────────────────────────────────────────────────────────────────
// NFC Page — demonstrates all three usage modes
// ─────────────────────────────────────────────────────────────────────────────

enum _NfcMode { defaultDialog, customDialog, headless }

class NfcPage extends StatefulWidget {
  final ICardReaderController controller;
  const NfcPage({super.key, required this.controller});

  @override
  State<NfcPage> createState() => _NfcPageState();
}

class _NfcPageState extends State<NfcPage> {
  _NfcMode _mode = _NfcMode.defaultDialog;

  CardReaderState _headlessState = const CardReaderIdleState();
  StreamSubscription<CardReaderState>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = widget.controller.stateStream.listen((s) {
      if (mounted) setState(() => _headlessState = s);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 16),
          const SectionHeader(
            icon: Icons.nfc,
            title: 'NFC Card Read',
            subtitle: 'Choose a usage mode below',
          ),
          const SizedBox(height: 20),

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
              "Use NfcScanDialog.show() to launch the plugin's built-in "
              'bottom-sheet. No extra setup needed.',
          codeSnippet: 'final card = await NfcScanDialog.show(\n'
              '  context,\n'
              '  controller: controller,\n'
              ');',
        ),
        const SizedBox(height: 20),
        if (_result != null) ...[
          ResultCard(card: _result!),
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
    successMessage: "Karta muvaffaqiyatli o'qildi!",
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
          codeSnippet: 'final card = await NfcScanDialog.show(\n'
              '  context,\n'
              '  controller: controller,\n'
              '  theme: const NfcScanDialogTheme(\n'
              "    titleScanning:    'Skanerlashga tayyor',\n"
              "    cancelLabel:      'Bekor qilish',\n"
              '    showRetryOnError: true,\n'
              '  ),\n'
              ');',
        ),
        const SizedBox(height: 8),
        _ThemePreviewChips(),
        const SizedBox(height: 16),
        if (_result != null) ...[
          ResultCard(card: _result!),
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

class _ThemePreviewChips extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    const chips = [
      'Uzbek labels',
      'Teal success colour',
      'Retry on error button',
      '1 s dismiss delay',
    ];
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: chips
          .map(
            (label) => Chip(
              label: Text(label, style: Theme.of(context).textTheme.labelSmall),
              padding: EdgeInsets.zero,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          )
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
          codeSnippet: 'controller.stateStream.listen((state) {\n'
              '  switch (state) {\n'
              '    case CardReaderScanningState(:final message):\n'
              '      // update your own UI\n'
              '    case CardReaderSuccessState(:final data):\n'
              '      // use data.pan, data.expiryDate, …\n'
              '    case CardReaderErrorState(:final exception):\n'
              '      // show error\n'
              '  }\n'
              '});\n'
              'await controller.startNfcScan();',
        ),
        const SizedBox(height: 20),

        AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          child: switch (state) {
            CardReaderSuccessState(:final data) => ResultCard(card: data),
            CardReaderErrorState(:final exception) =>
              ErrorBanner(exception.message),
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
                style:
                    t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
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
