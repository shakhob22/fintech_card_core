import 'package:flutter/widgets.dart';

/// Developer-defined brand mark shown in [SmartCardInput] when the typed PAN
/// starts with [prefix].
///
/// Use this to support local / private-label networks the plugin does not
/// know about, or to replace a built-in logo with your own asset.
///
/// [prefix] is 1–8 digits (non-digits are stripped), e.g. `'1'`, `'12'`,
/// `'088'`, `'1212'`. When several entries match, the **longest** prefix wins,
/// so `'1212'` beats `'12'` beats `'1'`.
///
/// A matching custom badge always takes priority over the built-in Visa /
/// Mastercard / … logos.
///
/// ```dart
/// SmartCardInput(
///   controller: controller,
///   customBrandBadges: [
///     CardBrandBadge(
///       prefix: '1212',
///       badge: Image.asset('assets/my_bank.png', height: 24),
///     ),
///     CardBrandBadge(
///       prefix: '088',
///       badge: SvgPicture.asset('assets/partner.svg', height: 24),
///     ),
///     CardBrandBadge(
///       prefix: '99',
///       badge: const Text('MY', style: TextStyle(fontWeight: FontWeight.bold)),
///     ),
///   ],
/// )
/// ```
class CardBrandBadge {
  /// Digit prefix that must match the start of the PAN (spaces ignored).
  ///
  /// May contain spaces or dashes — they are stripped before matching.
  /// Empty / non-digit-only values are ignored by [match].
  final String prefix;

  /// Any widget shown in the card-number field suffix (PNG [Image], SVG,
  /// icon, text chip, …). Keep it roughly 24 px tall to match built-in logos.
  final Widget badge;

  const CardBrandBadge({
    required this.prefix,
    required this.badge,
  });

  /// Digits-only form of [prefix] used for matching and identity.
  String get normalizedPrefix => prefix.replaceAll(RegExp(r'\D'), '');

  /// Returns the best-matching entry for [digits], or `null` if none match.
  ///
  /// [digits] may include spaces; matching uses longest-prefix wins.
  static CardBrandBadge? match(List<CardBrandBadge> badges, String digits) {
    if (badges.isEmpty) return null;
    final pan = digits.replaceAll(RegExp(r'\D'), '');
    if (pan.isEmpty) return null;

    CardBrandBadge? best;
    var bestLen = 0;
    for (final entry in badges) {
      final p = entry.normalizedPrefix;
      if (p.isEmpty || p.length > 8) continue;
      if (pan.startsWith(p) && p.length > bestLen) {
        best = entry;
        bestLen = p.length;
      }
    }
    return best;
  }
}
