import '../core/luhn.dart';
import '../core/models/card_data.dart';
import 'pan_heuristics.dart';

/// Partial fields extracted from a single OCR frame.
///
/// Either field may be null — glare often obscures PAN or expiry in isolation.
/// [OcrCardScanner] accumulates these across frames before emitting success.
class PartialOcrResult {
  final String? pan;
  final String? expiryDate;

  const PartialOcrResult({this.pan, this.expiryDate});

  bool get isEmpty => pan == null && expiryDate == null;
}

/// Extracts payment card fields from raw OCR text output.
///
/// Regex design notes:
///   - PAN   : matches 16-digit Visa/MC/Discover and 15-digit Amex formats,
///             allowing optional spaces or hyphens every 4 digits. Candidates
///             that fail the Luhn check are skipped.
///   - Expiry: matches MM/YY or MM-YY, MM YY patterns within a valid range.
abstract final class OcrParser {
  static final _panRegex = RegExp(
    r'(?:^|[^\dA-Za-z])('
    r'\d{4}[\s\-]?\d{4}[\s\-]?\d{4}[\s\-]?\d{4}' // 16-digit
    r'|\d{4}[\s\-]?\d{6}[\s\-]?\d{5}' // 15-digit Amex
    // Shifted read: faded leading digit(s) shrink the first group to 2–3
    // digits (HUMO `9860 3501…` scanned as `860 3501…`).
    r'|\d{2,3}[\s\-]?\d{4}[\s\-]?\d{4}[\s\-]?\d{4}'
    r'|\d{13,19}' // contiguous digit run
    r')(?:[^\dA-Za-z]|$)',
  );

  /// Looser pattern for OCR text with letter/digit confusions (O/0, b/6, B/8…).
  /// Character class mirrors [PanHeuristics.substitutions] keys + digits.
  static final _messyPanRegex = RegExp(
    r'(?:^|[^\w])('
    r'[0-9OoDdQqIiLlSsZzBbGgAaeTt|!]{4}[\s\-]?'
    r'[0-9OoDdQqIiLlSsZzBbGgAaeTt|!]{4}[\s\-]?'
    r'[0-9OoDdQqIiLlSsZzBbGgAaeTt|!]{4}[\s\-]?'
    r'[0-9OoDdQqIiLlSsZzBbGgAaeTt|!]{4}'
    // Shifted read variant (2–3 char head group, see _panRegex).
    r'|[0-9OoDdQqIiLlSsZzBbGgAaeTt|!]{2,3}[\s\-]?'
    r'[0-9OoDdQqIiLlSsZzBbGgAaeTt|!]{4}[\s\-]?'
    r'[0-9OoDdQqIiLlSsZzBbGgAaeTt|!]{4}[\s\-]?'
    r'[0-9OoDdQqIiLlSsZzBbGgAaeTt|!]{4}'
    r'|[0-9OoDdQqIiLlSsZzBbGgAaeTt|!]{13,19}'
    r')(?:[^\w]|$)',
  );

  static final _expiryRegex = RegExp(
    r'\b(0[1-9]|1[0-2])[\/\-\s]([2-9]\d)\b',
  );

  /// Parse [ocrText] and return a [CardData] if a Luhn-valid PAN is found.
  ///
  /// Expiry is attached when present in the same text; PAN-only results are
  /// valid (matches live scanner PAN-first completion).
  static CardData? parse(String ocrText) {
    final partial = extract(ocrText);
    if (partial.pan == null) return null;
    return CardData.fromOcr(pan: partial.pan!, expiryDate: partial.expiryDate);
  }

  /// Extract whatever card fields are present in [ocrText].
  ///
  /// Unlike [parse], this does not require both fields in the same frame.
  /// PAN candidates must pass [Luhn.validate].
  static PartialOcrResult extract(String ocrText) {
    final normalised = ocrText.replaceAll('\n', ' ');
    return PartialOcrResult(
      pan: _extractPan(normalised),
      expiryDate: _extractExpiry(normalised),
    );
  }

  /// Letter→digit via [PanHeuristics] (`b`→`6`, `B`→`8`, `O`→`0`, …).
  /// Unresolved glyphs become `?` and are stripped for Luhn checks.
  static String _toDigits(String raw) {
    return PanHeuristics.normalize(raw).replaceAll('?', '');
  }

  static String? _extractPan(String text) {
    for (final match in _panRegex.allMatches(text)) {
      final pan = _acceptPan(_toDigits(match.group(1) ?? ''));
      if (pan != null) return pan;
    }
    for (final match in _messyPanRegex.allMatches(text)) {
      final pan = _acceptPan(_toDigits(match.group(1) ?? ''));
      if (pan != null) return pan;
    }
    return null;
  }

  /// All distinct Luhn-valid PANs found in [ocrText].
  ///
  /// The native layer joins the output of several preprocessing passes with
  /// `" ; "` — a pass with a *systematic* emboss misread (7→1, 6→5, 4→1) can
  /// produce a wrong-but-Luhn-valid string alongside the correct one. The
  /// caller must arbitrate (e.g. `PanHeuristics.chooseUndegraded`) instead
  /// of trusting whichever happens to appear first.
  static List<String> extractAllPans(String ocrText) {
    final text = ocrText.replaceAll('\n', ' ');
    final out = <String>[];
    void consider(String? group) {
      final pan = _acceptPan(_toDigits(group ?? ''));
      if (pan != null && !out.contains(pan)) out.add(pan);
    }

    for (final match in _panRegex.allMatches(text)) {
      consider(match.group(1));
    }
    for (final match in _messyPanRegex.allMatches(text)) {
      consider(match.group(1));
    }
    return out;
  }

  /// Validates a digit run as a PAN, realigning shifted local-scheme reads.
  ///
  /// A faded leading digit makes OCR drop it entirely — a HUMO `9860 …` card
  /// is read as the 15-digit `860 …`. When a 14/15-digit run starts with the
  /// tail of a known local BIN, the missing head is restored via
  /// [PanHeuristics.realignDroppedPrefix] and the *full* PAN is Luhn-checked.
  static String? _acceptPan(String digits) {
    if (digits.length < 13 || digits.length > 19) return null;

    if (digits.length == 14 || digits.length == 15) {
      final realigned = PanHeuristics.realignDroppedPrefix(digits);
      if (realigned != null) {
        // Looks like a shifted HUMO/UzCard read — accept only the realigned
        // form. The raw short run must NOT be accepted even if it happens to
        // pass Luhn (no real scheme issues 15-digit 860…/600… PANs).
        return Luhn.validate(realigned) ? realigned : null;
      }
    }

    return Luhn.validate(digits) ? digits : null;
  }

  /// Extracts the best *unvalidated* PAN reading for positional voting.
  ///
  /// Unlike [_extractPan] this does **not** require the Luhn check to pass —
  /// a frame where glare corrupted one digit still carries 15 correct digits
  /// of information. The match is normalised via [PanHeuristics.normalize]
  /// (letter→digit substitutions, unknown chars become `?`) so it can be fed
  /// straight into a `FrameConsensusBuffer` of matching [expectedLength].
  ///
  /// Returns `null` when the text contains no plausible PAN-shaped run.
  static String? extractRawCandidate(String ocrText, {int expectedLength = 16}) {
    final all = extractRawCandidates(ocrText, expectedLength: expectedLength);
    if (all.isEmpty) return null;
    var best = all.first;
    var bestDigits = -1;
    for (final candidate in all) {
      final digits = candidate.replaceAll('?', '').length;
      if (digits > bestDigits) {
        bestDigits = digits;
        best = candidate;
      }
    }
    return best;
  }

  /// All distinct plausible `[0-9?]` readings of [expectedLength] in the
  /// text — one per PAN-shaped run (native multi-pass output may contain
  /// several conflicting readings separated by `;`). Each reading should be
  /// fed to the consensus buffer so passes vote against each other.
  static List<String> extractRawCandidates(
    String ocrText, {
    int expectedLength = 16,
  }) {
    final text = ocrText.replaceAll('\n', ' ');
    final out = <String>[];

    void addIfPlausible(String normalized) {
      if (normalized.length != expectedLength) return;
      final digitCount = normalized.replaceAll('?', '').length;
      if (digitCount < expectedLength - 3) return;
      if (!out.contains(normalized)) out.add(normalized);
    }

    void consider(String raw) {
      final normalized = PanHeuristics.normalize(raw);
      if (normalized.length == expectedLength) {
        addIfPlausible(normalized);
        return;
      }
      if (normalized.length < expectedLength) return;
      // Sliding window when OCR glued neighbouring words onto the PAN —
      // keep only the best window per run to avoid polluting the votes.
      String? best;
      var bestDigits = -1;
      for (var i = 0; i <= normalized.length - expectedLength; i++) {
        final window = normalized.substring(i, i + expectedLength);
        final digits = window.replaceAll('?', '').length;
        if (digits > bestDigits) {
          bestDigits = digits;
          best = window;
        }
      }
      if (best != null) addIfPlausible(best);
    }

    for (final match in _panRegex.allMatches(text)) {
      consider(match.group(1) ?? '');
    }
    for (final match in _messyPanRegex.allMatches(text)) {
      consider(match.group(1) ?? '');
    }
    for (final match in _rawTokenRegex.allMatches(text)) {
      consider(match.group(0) ?? '');
    }
    return out;
  }

  /// Digit-led alnum/separator runs — may include trailing OCR junk (windowed).
  static final _rawTokenRegex = RegExp(r'\d[\dA-Za-z\s\-]{12,40}');

  static String? _extractExpiry(String text) {
    final match = _expiryRegex.firstMatch(text);
    if (match == null) return null;
    return '${match.group(1)}/${match.group(2)}';
  }
}
