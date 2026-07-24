/// Rolling multi-frame consensus for OCR PAN candidates.
///
/// Keeps the last [windowSize] raw digit strings and builds a 16-digit PAN by
/// majority vote at each position `[0..15]`.
class OcrResultAccumulator {
  /// Frames retained in the rolling buffer (3–5 recommended).
  static const defaultWindowSize = 5;

  /// Minimum frames before [accumulateVotes] may return a consensus.
  static const defaultMinFrames = 3;

  /// Expected PAN length for positional voting.
  static const panLength = 16;

  final int windowSize;
  final int minFrames;
  final List<String> _buffer = <String>[];

  OcrResultAccumulator({
    this.windowSize = defaultWindowSize,
    this.minFrames = defaultMinFrames,
  }) : assert(windowSize >= minFrames && minFrames > 0);

  /// Number of candidates currently in the buffer.
  int get length => _buffer.length;

  /// Adds a raw OCR candidate. Non-digit / empty strings are ignored.
  ///
  /// Candidates shorter or longer than [panLength] are still kept when they
  /// contain only digits — votes are applied only to overlapping indices.
  void add(String candidate) {
    final cleaned = candidate.replaceAll(RegExp(r'\D'), '');
    if (cleaned.isEmpty) return;

    _buffer.add(cleaned);
    while (_buffer.length > windowSize) {
      _buffer.removeAt(0);
    }
  }

  /// Majority vote across buffered frames for each digit position `0..15`.
  ///
  /// Returns `null` until at least [minFrames] candidates are present, or if
  /// any position has no votes.
  String? accumulateVotes() {
    if (_buffer.length < minFrames) return null;

    final counts = List.generate(panLength, (_) => <int, int>{});

    for (final candidate in _buffer) {
      final n = candidate.length < panLength ? candidate.length : panLength;
      for (var i = 0; i < n; i++) {
        final digit = candidate.codeUnitAt(i) - 0x30;
        if (digit < 0 || digit > 9) continue;
        counts[i][digit] = (counts[i][digit] ?? 0) + 1;
      }
    }

    final out = StringBuffer();
    for (var i = 0; i < panLength; i++) {
      final bucket = counts[i];
      if (bucket.isEmpty) return null;

      var bestDigit = 0;
      var bestCount = -1;
      bucket.forEach((digit, count) {
        if (count > bestCount || (count == bestCount && digit < bestDigit)) {
          bestDigit = digit;
          bestCount = count;
        }
      });
      out.writeCharCode(0x30 + bestDigit);
    }

    return out.toString();
  }

  /// Clears the rolling buffer (e.g. on scan stop / restart).
  void clear() => _buffer.clear();
}
