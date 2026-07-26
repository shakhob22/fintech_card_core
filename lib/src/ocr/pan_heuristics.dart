import '../core/luhn.dart';

/// Phase 4 — Heuristics & auto-correction engine.
///
/// Repairs a PAN candidate that OCR mangled, in three ordered steps:
///
/// 1. **Character substitution** — embossed card fonts confuse OCR into
///    letters ('6'→'b', '8'→'B', '0'→'O' …). [normalize] maps them back with
///    [substitutions]; anything unmappable becomes `?` (ambiguous).
/// 2. **BIN auto-completion** — Uzbek + international scheme prefixes fill
///    ambiguous positions in the first four digits (HUMO `9860`,
///    UzCard `8600`, Visa `4`, Mastercard `5`/`2`).
/// 3. **Luhn brute-force** — with exactly one remaining `?`, the mod-10
///    checksum pins the digit uniquely (each of 0-9 shifts the sum to a
///    distinct residue, so exactly one candidate validates). With zero `?`
///    but a failing checksum and a known low-confidence position, that
///    position is re-solved the same way.
abstract final class PanHeuristics {
  /// OCR letter → digit substitution map for embossed / OCR-B card fonts.
  ///
  /// Includes the classic emboss confusions requested for this engine:
  /// lowercase 'b' is a broken-loop '6', uppercase 'B' a filled '8'.
  static const Map<String, String> substitutions = {
    'b': '6', 'B': '8',
    'O': '0', 'o': '0', 'D': '0', 'Q': '0',
    'I': '1', 'l': '1', 'i': '1', '|': '1', '!': '1',
    'S': '5', 's': '5',
    'Z': '2', 'z': '2',
    'G': '6', 'g': '9', 'q': '9',
    'T': '7',
    'A': '4',
    'e': '2',
  };

  /// Maps raw OCR output to a `[0-9?]` string.
  ///
  /// Separators (spaces / hyphens) are stripped; digits pass through;
  /// letters go through [substitutions]; anything else becomes `?` so the
  /// position still *exists* for positional voting and Luhn repair.
  static String normalize(String raw) {
    final out = StringBuffer();
    for (final rune in raw.runes) {
      final ch = String.fromCharCode(rune);
      if (ch == ' ' || ch == '-' || ch == '.') continue;
      if (RegExp(r'\d').hasMatch(ch)) {
        out.write(ch);
      } else {
        out.write(substitutions[ch] ?? '?');
      }
    }
    return out.toString();
  }

  /// BIN prefix table: anchor digit → full 4-digit BIN to complete towards.
  ///
  /// Only prefixes that determine the full BIN from the first digit are
  /// completed (HUMO / UzCard). Visa/Mastercard first digits are validated
  /// but digits 2-4 vary per issuer, so they are left to the Luhn stage.
  static const Map<String, String> _uzBinCompletion = {
    '9': '9860', // HUMO
    '8': '8600', // UzCard
  };

  /// First digits accepted as plausible scheme anchors when repairing.
  static const Set<String> _schemeAnchors = {'9', '8', '4', '5', '2', '3', '6'};

  /// Fills ambiguous (`?`) positions among digits 1-4 using local BIN
  /// knowledge. Never overwrites a confidently read digit — a HUMO card whose
  /// first four digits were all read cleanly is left untouched even if they
  /// aren't `9860`.
  ///
  /// Also recovers a missing first digit when digits 2-4 already match a
  /// known local pattern (`x860` → HUMO `9860`, `x600` → UzCard `8600`).
  static String applyBinCompletion(String candidate) {
    if (candidate.length < 4) return candidate;
    final chars = candidate.split('');
    final d234 = '${chars[1]}${chars[2]}${chars[3]}';

    // Pattern-led: digits 2–4 look like HUMO / UzCard even if digit 1 is lost.
    if (_looselyMatches(d234, '860') &&
        (chars[0] == '?' || chars[0] == '9')) {
      _fillBin(chars, '9860');
      return chars.join();
    }
    if (_looselyMatches(d234, '600') &&
        (chars[0] == '?' || chars[0] == '8')) {
      _fillBin(chars, '8600');
      return chars.join();
    }

    final first = chars[0];
    if (first == '?') return candidate;

    final bin = _uzBinCompletion[first];
    if (bin == null) return candidate;

    _fillBin(chars, bin);
    return chars.join();
  }

  /// True when [observed] matches [expected] on every non-`?` position and
  /// at least two digits are confidently resolved (avoids over-eager fills).
  static bool _looselyMatches(String observed, String expected) {
    if (observed.length != expected.length) return false;
    var resolved = 0;
    for (var i = 0; i < observed.length; i++) {
      final ch = observed[i];
      if (ch == '?') continue;
      if (ch != expected[i]) return false;
      resolved++;
    }
    return resolved >= 2;
  }

  static void _fillBin(List<String> chars, String bin) {
    for (var i = 0; i < 4 && i < chars.length; i++) {
      if (chars[i] == '?') chars[i] = bin[i];
    }
  }

  /// Brute-forces the single ambiguous position [index] through `0`–`9`
  /// until [Luhn.validate] passes. Returns the repaired PAN or `null`.
  ///
  /// Mathematically at most one digit can validate: changing one digit moves
  /// the Luhn sum by a distinct amount mod 10 for each candidate value.
  static String? bruteForceLuhn(String pan, int index) {
    if (index < 0 || index >= pan.length) return null;
    final chars = pan.split('');
    for (var digit = 0; digit <= 9; digit++) {
      chars[index] = '$digit';
      final attempt = chars.join();
      if (!attempt.contains('?') && Luhn.validate(attempt)) return attempt;
    }
    return null;
  }

  /// Stroke-loss confusions of embossed / worn digits: key = the true glyph,
  /// values = what OCR collapses it into when strokes are lost or unlit.
  ///
  /// Emboss OCR practically never *adds* strokes — a `1` does not become a
  /// `7` — so when two readings disagree, the complex digit whose degraded
  /// form matches the rival is the likelier truth.
  static const Map<String, Set<String>> strokeLossConfusions = {
    '7': {'1'}, // top bar unlit → vertical stroke only
    '4': {'1'}, // open top lost → vertical stroke only
    '6': {'5'}, // lower loop gap → 5-like hook
    '9': {'5', '4'}, // upper loop gap
    '8': {'3', '6', '0'}, // one of the loops broken / merged
    '2': {'7'}, // bottom stroke lost
  };

  /// Arbitrates between conflicting same-length readings of one card.
  ///
  /// Both may pass Luhn (≈10 % collision chance per wrong string), so the
  /// checksum cannot decide. Instead, at every disagreeing position a
  /// candidate earns a point when a rival's digit looks like a stroke-lost
  /// copy of its own (see [strokeLossConfusions]). The strictly best scorer
  /// wins; returns `null` on a tie or when nothing explains the conflict
  /// (caller should wait for more frames instead of guessing).
  static String? chooseUndegraded(List<String> candidates) {
    final distinct = <String>[];
    for (final c in candidates) {
      if (!distinct.contains(c)) distinct.add(c);
    }
    if (distinct.isEmpty) return null;
    if (distinct.length == 1) return distinct.first;

    final len = distinct.first.length;
    if (distinct.any((c) => c.length != len)) return null;

    final scores = List<int>.filled(distinct.length, 0);
    for (var pos = 0; pos < len; pos++) {
      for (var i = 0; i < distinct.length; i++) {
        final mine = distinct[i][pos];
        final degradedForms = strokeLossConfusions[mine];
        if (degradedForms == null) continue;
        final rivalLooksDegraded = distinct.any(
          (other) => other[pos] != mine && degradedForms.contains(other[pos]),
        );
        if (rivalLooksDegraded) scores[i]++;
      }
    }

    var bestIdx = 0;
    var tied = false;
    for (var i = 1; i < distinct.length; i++) {
      if (scores[i] > scores[bestIdx]) {
        bestIdx = i;
        tied = false;
      } else if (scores[i] == scores[bestIdx]) {
        tied = true;
      }
    }
    if (tied || scores[bestIdx] == 0) return null;
    return distinct[bestIdx];
  }

  /// Restores 1–2 leading digits that a faded emboss made OCR drop entirely.
  ///
  /// A worn HUMO card whose first `9` is unreadable is OCR'd as
  /// `860 3501 …` — every digit shifts one position left. When the head of
  /// the short reading matches the *tail* of a known local BIN
  /// (`9860` → `860`/`60`, `8600` → `600`/`00`), the missing prefix is
  /// prepended so the string realigns to the full 16 positions.
  ///
  /// [candidate] is a 14- or 15-char `[0-9?]` string. Returns the realigned
  /// 16-char string (still unvalidated — run [repair] afterwards) or `null`
  /// when no BIN tail matches.
  static String? realignDroppedPrefix(String candidate) {
    for (final bin in const ['9860', '8600']) {
      for (var missing = 1; missing <= 2; missing++) {
        if (candidate.length != 16 - missing) continue;
        final binTail = bin.substring(missing);
        if (_looselyMatches(candidate.substring(0, binTail.length), binTail)) {
          return bin.substring(0, missing) + candidate;
        }
      }
    }
    return null;
  }

  /// Full repair pipeline. [candidate] is a `[0-9?]` string (typically the
  /// consensus output of `FrameConsensusBuffer`).
  ///
  /// [lowConfidenceIndex] optionally marks a fully-read but doubtful position
  /// (e.g. flagged by the OCR engine) to re-solve when the checksum fails.
  ///
  /// Returns a Luhn-valid PAN, or `null` when the candidate is beyond repair
  /// (more than one ambiguity after BIN completion — guessing two digits has
  /// a 10× false-accept risk, so we wait for more frames instead).
  static String? repair(String candidate, {int? lowConfidenceIndex}) {
    final direct =
        _repairAligned(candidate, lowConfidenceIndex: lowConfidenceIndex);
    if (direct != null) return direct;

    // Dropped leading digit(s): a faded first digit shifts the whole read
    // left (HUMO `9860…` scanned as `860…`).
    if (candidate.length == 14 || candidate.length == 15) {
      final realigned = realignDroppedPrefix(candidate);
      if (realigned != null) return _repairAligned(realigned);
    }

    // 16 chars but shifted: the head digit was lost AND a stray trailing
    // glyph (next word / artwork) padded the read back to 16. Drop the tail,
    // restore the BIN head.
    if (candidate.length == 16) {
      final realigned = realignDroppedPrefix(candidate.substring(0, 15));
      if (realigned != null) return _repairAligned(realigned);
    }

    return null;
  }

  static String? _repairAligned(String candidate, {int? lowConfidenceIndex}) {
    if (candidate.length < 13 || candidate.length > 19) return null;

    var pan = applyBinCompletion(candidate);

    // Sanity: the scheme anchor digit must be plausible.
    if (pan[0] != '?' && !_schemeAnchors.contains(pan[0])) return null;

    // Local-scheme plausibility: in this market every `98…` card is HUMO
    // (`9860`) and every `86…` card is UzCard (`8600`). A fully-resolved head
    // like `8603` is almost certainly a *shifted* read (dropped leading 9),
    // so reject it here and let the realign fallback in [repair] fix it.
    final head = pan.length >= 4 ? pan.substring(0, 4) : '';
    if (head.length == 4 && !head.contains('?')) {
      if (head.startsWith('98') && head != '9860') return null;
      if (head.startsWith('86') && head != '8600') return null;
    }

    final unknowns = <int>[];
    for (var i = 0; i < pan.length; i++) {
      if (pan[i] == '?') unknowns.add(i);
    }

    switch (unknowns.length) {
      case 0:
        if (Luhn.validate(pan)) return pan;
        // Checksum failed on a "complete" read — retry the one position the
        // caller distrusts, if any.
        if (lowConfidenceIndex != null) {
          return bruteForceLuhn(pan, lowConfidenceIndex);
        }
        return null;
      case 1:
        return bruteForceLuhn(pan, unknowns.first);
      default:
        return null; // ≥2 unknowns → ambiguous, wait for more frames
    }
  }
}
