import 'dart:math' as math;

import '../core/luhn.dart';

/// One OCR text box from Paddle (or any general OCR engine).
class OcrTextBox {
  final String text;
  final double confidence;

  /// Axis-aligned box in image coordinates (optional for unit tests).
  final double cx;
  final double cy;
  final double x0;
  final double y0;
  final double x1;
  final double y1;

  const OcrTextBox({
    required this.text,
    required this.confidence,
    this.cx = 0,
    this.cy = 0,
    this.x0 = 0,
    this.y0 = 0,
    this.x1 = 0,
    this.y1 = 0,
  });

  factory OcrTextBox.fromPoints({
    required String text,
    required double confidence,
    required List<List<double>> points,
  }) {
    var minX = double.infinity;
    var minY = double.infinity;
    var maxX = -double.infinity;
    var maxY = -double.infinity;
    for (final p in points) {
      if (p.length < 2) continue;
      minX = math.min(minX, p[0]);
      minY = math.min(minY, p[1]);
      maxX = math.max(maxX, p[0]);
      maxY = math.max(maxY, p[1]);
    }
    if (!minX.isFinite) {
      return OcrTextBox(text: text, confidence: confidence);
    }
    return OcrTextBox(
      text: text,
      confidence: confidence,
      cx: (minX + maxX) / 2,
      cy: (minY + maxY) / 2,
      x0: minX,
      y0: minY,
      x1: maxX,
      y1: maxY,
    );
  }
}

/// Structured card fields extracted from general OCR lines.
class CardFields {
  final String? pan;
  final double panConfidence;
  final bool luhnPass;
  final String? expiryDate;
  final String? cardholderName;
  final List<OcrTextBox> texts;

  const CardFields({
    this.pan,
    this.panConfidence = 0,
    this.luhnPass = false,
    this.expiryDate,
    this.cardholderName,
    this.texts = const [],
  });
}

class _PanCandidate {
  final String pan;
  final double confidence;
  final String source; // groups4 | line16 | prefix9 | window

  const _PanCandidate(this.pan, this.confidence, this.source);
}

/// Ports the Python `test_paddle.py` card post-process to Dart.
///
/// Handles fragmented PANs, BIN echoes, HUMO leading-`9` drops, and expiry.
abstract final class CardFieldExtractor {
  static final _expiryRe = RegExp(r'(?<!\d)(0[1-9]|1[0-2])\s*[/\-]\s*(\d{2})(?!\d)');
  static final _skipLabelRe = RegExp(
    r'VALID|THRU|MONTH|YEAR|BANK|CARD|HOLDER|NAME|HUMO|UZCARD|VISA|MASTER|CONTACTLESS',
    caseSensitive: false,
  );

  static String digitsOnly(String s) => s.replaceAll(RegExp(r'\D'), '');

  static CardFields extract(List<OcrTextBox> items) {
    final candidates = _cardCandidates(items);
    final best = _pickBest(candidates);
    final expiry = _extractExpiry(items);
    final name = _extractName(items, pan: best?.pan, expiry: expiry);

    return CardFields(
      pan: best?.pan,
      panConfidence: best?.confidence ?? 0,
      luhnPass: best != null && Luhn.validate(best.pan),
      expiryDate: expiry,
      cardholderName: name,
      texts: items,
    );
  }

  static List<_PanCandidate> _cardCandidates(List<OcrTextBox> items) {
    final out = <_PanCandidate>[];

    for (final it in items) {
      if (_expiryRe.hasMatch(it.text)) continue;
      final d = digitsOnly(it.text);
      if (d.length >= 16) {
        out.add(_PanCandidate(d.substring(0, 16), it.confidence, 'line16'));
        for (var i = 1; i <= d.length - 16; i++) {
          out.add(_PanCandidate(d.substring(i, i + 16), it.confidence * 0.9, 'window'));
        }
      } else if (d.length == 15 && d.startsWith('860')) {
        out.add(_PanCandidate('9$d', it.confidence * 0.95, 'prefix9'));
      }
    }

    final digitItems = <({OcrTextBox box, String digits})>[];
    for (final it in items) {
      if (_expiryRe.hasMatch(it.text) && digitsOnly(it.text).length <= 4) {
        continue;
      }
      if (_skipLabelRe.hasMatch(it.text) && digitsOnly(it.text).length < 4) {
        continue;
      }
      final d = digitsOnly(it.text);
      if (d.length >= 2) {
        digitItems.add((box: it, digits: d));
      }
    }
    if (digitItems.isEmpty) return out;

    digitItems.sort((a, b) => (a.box.cx + a.box.cy * 0.35)
        .compareTo(b.box.cx + b.box.cy * 0.35));

    final filtered = <({OcrTextBox box, String digits})>[];
    for (final item in digitItems) {
      var isBinEcho = false;
      for (final prev in filtered) {
        final samePrefix = prev.digits.length >= 4 &&
            item.digits.length >= 4 &&
            prev.digits.substring(0, 4) == item.digits.substring(0, 4) &&
            (item.digits.length == 4 || item.digits.length == 6);
        final nearX = (item.box.cx - prev.box.cx).abs() < 220;
        final below = item.box.cy > prev.box.cy + 8;
        final dupQuartet = item.digits.length == 4 &&
            prev.digits.length >= 4 &&
            item.digits == prev.digits.substring(0, 4) &&
            nearX &&
            (item.box.cy - prev.box.cy).abs() < 120;
        if (samePrefix && nearX && (below || dupQuartet)) {
          isBinEcho = true;
          break;
        }
      }
      if (!isBinEcho) filtered.add(item);
    }

    final joined = filtered.map((e) => e.digits).join();
    final confAvg = filtered.isEmpty
        ? 0.0
        : filtered.map((e) => e.box.confidence).reduce((a, b) => a + b) /
            filtered.length;

    if (joined.length >= 16) {
      out.add(_PanCandidate(joined.substring(0, 16), confAvg, 'line16'));
      for (var i = 1; i <= joined.length - 16; i++) {
        out.add(
          _PanCandidate(joined.substring(i, i + 16), confAvg * 0.85, 'window'),
        );
      }
    } else if (joined.length == 15 && joined.startsWith('860')) {
      out.add(_PanCandidate('9$joined', confAvg * 0.95, 'prefix9'));
    }

    void addFourGroups(List<({OcrTextBox box, String digits})> fours) {
      if (fours.length < 4) return;
      fours = [...fours]..sort((a, b) => (a.box.cx + a.box.cy * 0.35)
          .compareTo(b.box.cx + b.box.cy * 0.35));
      for (var start = 0; start <= fours.length - 4; start++) {
        final group = fours.sublist(start, start + 4);
        final xs = group.map((e) => e.box.cx).toList();
        final ys = group.map((e) => e.box.cy).toList();
        var mono = true;
        for (var i = 0; i < 3; i++) {
          if (xs[i] >= xs[i + 1]) {
            mono = false;
            break;
          }
        }
        if (!mono) continue;
        final ySpan = ys.reduce(math.max) - ys.reduce(math.min);
        if (ySpan > 260) continue;
        final pan = group.map((e) => e.digits).join();
        final conf =
            group.map((e) => e.box.confidence).reduce((a, b) => a + b) / 4;
        out.add(_PanCandidate(pan, conf, 'groups4'));
      }
    }

    addFourGroups([
      for (final e in filtered)
        if (e.digits.length == 4) e,
    ]);

    // Expand "9860-1234" style tokens into synthetic quartets.
    final expanded = <({OcrTextBox box, String digits})>[];
    for (final e in filtered) {
      final parts = RegExp(r'\d{4}').allMatches(e.box.text).map((m) => m.group(0)!).toList();
      if (parts.length >= 2 && parts.join() == e.digits) {
        final width = math.max(e.box.x1 - e.box.x0, 1.0);
        for (var i = 0; i < parts.length; i++) {
          final frac = (i + 0.5) / parts.length;
          expanded.add((
            box: OcrTextBox(
              text: parts[i],
              confidence: e.box.confidence,
              cx: e.box.x0 + width * frac,
              cy: e.box.cy,
              x0: e.box.x0,
              y0: e.box.y0,
              x1: e.box.x1,
              y1: e.box.y1,
            ),
            digits: parts[i],
          ));
        }
      } else {
        expanded.add(e);
      }
    }
    addFourGroups([
      for (final e in expanded)
        if (e.digits.length == 4) e,
    ]);

    return out;
  }

  static _PanCandidate? _pickBest(List<_PanCandidate> candidates) {
    if (candidates.isEmpty) return null;

    const rank = {'groups4': 3, 'line16': 2, 'prefix9': 1, 'window': 0};
    final structured = candidates
        .where((c) => c.source == 'groups4' || c.source == 'line16' || c.source == 'prefix9')
        .toList();

    final luhnStruct = structured.where((c) => Luhn.validate(c.pan)).toList();
    final List<_PanCandidate> pool;
    if (luhnStruct.isNotEmpty) {
      pool = luhnStruct;
    } else if (structured.isNotEmpty) {
      pool = structured;
    } else {
      final luhnAny = candidates.where((c) => Luhn.validate(c.pan)).toList();
      pool = luhnAny.isNotEmpty ? luhnAny : candidates;
    }

    _PanCandidate best = pool.first;
    var bestKey = _scoreKey(best, rank);
    for (var i = 1; i < pool.length; i++) {
      final c = pool[i];
      final key = _scoreKey(c, rank);
      if (_compareKeys(key, bestKey) > 0) {
        best = c;
        bestKey = key;
      }
    }
    return best;
  }

  static (int, int, int, int, double) _scoreKey(
    _PanCandidate c,
    Map<String, int> rank,
  ) {
    final g = [for (var i = 0; i < 16; i += 4) c.pan.substring(i, i + 4)];
    return (
      rank[c.source] ?? 0,
      _localBin(c.pan),
      g[0] == g[1] ? 0 : 1,
      g.toSet().length,
      c.confidence,
    );
  }

  static int _compareKeys(
    (int, int, int, int, double) a,
    (int, int, int, int, double) b,
  ) {
    if (a.$1 != b.$1) return a.$1.compareTo(b.$1);
    if (a.$2 != b.$2) return a.$2.compareTo(b.$2);
    if (a.$3 != b.$3) return a.$3.compareTo(b.$3);
    if (a.$4 != b.$4) return a.$4.compareTo(b.$4);
    return a.$5.compareTo(b.$5);
  }

  static int _localBin(String pan) {
    const bins = ['9860', '8600', '5614', '4165', '5440', '4532'];
    for (final b in bins) {
      if (pan.startsWith(b)) return 1;
    }
    return 0;
  }

  static String? _extractExpiry(List<OcrTextBox> items) {
    final dated = <({double score, String expiry})>[];
    for (final it in items) {
      final m = _expiryRe.firstMatch(it.text);
      if (m == null) continue;
      final expiry = '${m.group(1)}/${m.group(2)}';
      var bonus = 0.0;
      for (final other in items) {
        if (_skipLabelRe.hasMatch(other.text)) {
          final dist =
              (other.cx - it.cx).abs() + (other.cy - it.cy).abs();
          if (dist < 250) bonus += 1;
        }
      }
      dated.add((score: it.confidence + bonus, expiry: expiry));
    }
    if (dated.isEmpty) return null;
    dated.sort((a, b) => a.score.compareTo(b.score));
    return dated.last.expiry;
  }

  static String? _extractName(
    List<OcrTextBox> items, {
    String? pan,
    String? expiry,
  }) {
    final nameRe = RegExp(r'^[A-Z][A-Z\s\.\-]{4,40}$');
    for (final it in items) {
      final t = it.text.trim().toUpperCase();
      if (!nameRe.hasMatch(t)) continue;
      if (_skipLabelRe.hasMatch(t)) continue;
      if (pan != null && digitsOnly(t).isNotEmpty) continue;
      if (expiry != null && t.contains(expiry.replaceAll('/', ''))) continue;
      if (it.confidence < 0.7) continue;
      return t;
    }
    return null;
  }
}
