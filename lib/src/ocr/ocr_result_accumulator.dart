import '../core/models/card_data.dart';

/// Cross-frame voting for OCR PAN / expiry with PAN-first completion.
///
/// - PAN locks after [panVotesRequired] consecutive identical Luhn-valid reads.
/// - Expiry locks after [expiryVotesRequired] consecutive identical reads.
/// - Once PAN is locked, [isComplete] becomes true when expiry locks **or**
///   [expiryGrace] elapses (caller supplies [now] / starts a timer).
class OcrResultAccumulator {
  /// Consecutive identical Luhn-valid PANs required before locking.
  /// CardScan SSD is digit-specialized — one stable Luhn-valid read is enough.
  static const panVotesRequired = 1;

  /// Consecutive identical expiry strings required before locking.
  static const expiryVotesRequired = 1;

  /// How long to keep searching for expiry after PAN locks.
  static const expiryGrace = Duration(milliseconds: 400);

  String? _lastPan;
  int _panMatchCount = 0;
  String? lockedPan;

  String? _lastExpiry;
  int _expiryMatchCount = 0;
  String? lockedExpiry;

  /// Wall-clock time when [lockedPan] was set (for grace checks).
  DateTime? panLockedAt;

  bool get hasLockedPan => lockedPan != null;

  /// True when PAN is locked and we should crop the expiry band instead.
  bool get preferExpiryRoi =>
      lockedPan != null && lockedExpiry == null;

  /// Whether success can be emitted (PAN locked + expiry locked or grace over).
  bool isComplete({DateTime? now}) {
    if (lockedPan == null) return false;
    if (lockedExpiry != null) return true;
    final lockedAt = panLockedAt;
    if (lockedAt == null) return false;
    final clock = now ?? DateTime.now();
    return clock.difference(lockedAt) >= expiryGrace;
  }

  /// Feed one frame's partial fields. Returns [CardData] when complete.
  CardData? accumulate(String? pan, String? expiry, {DateTime? now}) {
    final clock = now ?? DateTime.now();

    if (expiry != null) {
      if (expiry == _lastExpiry) {
        _expiryMatchCount++;
      } else {
        _lastExpiry = expiry;
        _expiryMatchCount = 1;
      }
      if (_expiryMatchCount >= expiryVotesRequired) {
        lockedExpiry = expiry;
      }
    }

    if (pan != null) {
      if (pan == _lastPan) {
        _panMatchCount++;
      } else {
        _lastPan = pan;
        _panMatchCount = 1;
      }
      if (_panMatchCount >= panVotesRequired && lockedPan == null) {
        lockedPan = pan;
        panLockedAt = clock;
      }
    }

    if (!isComplete(now: clock)) return null;
    return CardData.fromOcr(pan: lockedPan!, expiryDate: lockedExpiry);
  }

  /// Force completion after grace if PAN is locked (timer callback).
  CardData? completeIfReady({DateTime? now}) {
    if (!isComplete(now: now)) return null;
    return CardData.fromOcr(pan: lockedPan!, expiryDate: lockedExpiry);
  }

  void reset() {
    _lastPan = null;
    _panMatchCount = 0;
    lockedPan = null;
    _lastExpiry = null;
    _expiryMatchCount = 0;
    lockedExpiry = null;
    panLockedAt = null;
  }
}
