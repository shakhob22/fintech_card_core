import 'dart:collection';

/// Phase 3 — Multi-frame consensus buffer (positional voting).
///
/// Keeps a rolling window of the last [capacity] per-frame PAN readings and
/// votes **per character position**: if position 5 reads '8' in 4 of the last
/// 5 frames and '3' once (a glare glitch), the consensus keeps '8'.
///
/// Readings may contain `?` for characters the frame could not resolve —
/// those abstain from the vote at that position. Positions where no character
/// reaches [minVotes] (or where votes tie) emit `?` in the consensus string,
/// which the Phase 4 heuristics engine then attempts to repair (BIN
/// completion + Luhn brute-force).
///
/// This differs from [OcrResultAccumulator]'s whole-string voting: a PAN that
/// is never read perfectly in any single frame can still converge, because
/// each frame only needs to get each *position* right often enough.
class FrameConsensusBuffer {
  /// Rolling window size.
  final int capacity;

  /// Minimum identical votes a character needs at a position.
  final int minVotes;

  /// Expected PAN length — readings of other lengths are rejected because
  /// positional voting requires aligned strings. (16 covers Visa, Mastercard,
  /// HUMO and UzCard; run a second buffer with length 15 for Amex.)
  final int expectedLength;

  final Queue<String> _frames = Queue<String>();

  FrameConsensusBuffer({
    this.capacity = 5,
    this.minVotes = 3,
    this.expectedLength = 16,
  })  : assert(capacity > 0),
        assert(minVotes > 0 && minVotes <= capacity);

  int get frameCount => _frames.length;

  /// Whether enough frames are buffered for a meaningful vote.
  bool get isWarm => _frames.length >= minVotes;

  /// Adds one frame's reading. Returns false when the reading is misaligned
  /// (wrong length) and was ignored.
  ///
  /// [reading] must contain only `0-9` and `?` — normalise raw OCR output
  /// through `PanHeuristics.normalize` first.
  bool add(String reading) {
    if (reading.length != expectedLength) return false;
    // A reading that resolved nothing carries no information.
    if (!reading.contains(RegExp(r'\d'))) return false;

    _frames.addLast(reading);
    while (_frames.length > capacity) {
      _frames.removeFirst();
    }
    return true;
  }

  /// Per-position majority vote across the buffered frames.
  ///
  /// Returns `null` until [isWarm]; otherwise a string of [expectedLength]
  /// characters where unresolved positions are `?`.
  String? get consensus {
    if (!isWarm) return null;

    final out = StringBuffer();
    for (var pos = 0; pos < expectedLength; pos++) {
      final votes = <String, int>{};
      for (final frame in _frames) {
        final ch = frame[pos];
        if (ch == '?') continue; // abstain
        votes[ch] = (votes[ch] ?? 0) + 1;
      }

      String winner = '?';
      var best = 0;
      var tied = false;
      votes.forEach((ch, count) {
        if (count > best) {
          winner = ch;
          best = count;
          tied = false;
        } else if (count == best) {
          tied = true;
        }
      });

      out.write((best >= minVotes && !tied) ? winner : '?');
    }
    return out.toString();
  }

  /// Number of unresolved (`?`) positions in the current consensus,
  /// or [expectedLength] when not yet warm.
  int get unresolvedCount {
    final c = consensus;
    if (c == null) return expectedLength;
    return '?'.allMatches(c).length;
  }

  void clear() => _frames.clear();
}
