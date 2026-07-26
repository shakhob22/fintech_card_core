import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import '../core/interfaces/i_nfc_reader.dart';
import '../core/models/card_data.dart';
import '../core/models/card_enums.dart';
import '../core/models/card_reader_exception.dart';
import '../core/models/card_reader_state.dart';
import 'apdu/apdu_command.dart';
import 'apdu/apdu_response.dart';
import 'emv/emv_parser.dart';
import 'emv/emv_tags.dart';
import 'nfc_bridge.dart';

/// Implements the full EMV card-reading flow over NFC.
///
/// Architecture overview
/// ─────────────────────
/// ```
///  Flutter (Dart)                     Native (Swift / Kotlin)
///  ────────────────────────────────   ──────────────────────────────
///  NfcCardReader
///    │
///    ├── [1] startSession ──────────► activate OS NFC hardware
///    │                                       │
///    │   ◄── 'tagDetected' event ────────────┘  (ISO 14443 tag present)
///    │
///    ├── [2] APDU: SELECT PPSE ─────► transceive raw bytes
///    │         ◄── raw response ─────  (native forwards verbatim)
///    │    TLV-parse → extract AID
///    │
///    ├── [3] APDU: SELECT App ──────► transceive
///    │         ◄── raw response ─────
///    │
///    ├── [4] APDU: GET PROC OPTIONS ► transceive
///    │         ◄── raw response ─────
///    │    TLV-parse → extract AFL
///    │
///    └── [5] APDU: READ RECORD(s) ──► transceive (repeated per AFL entry)
///              ◄── raw response ─────
///         TLV-parse → PAN, Expiry, Cardholder Name
/// ```
///
/// All protocol logic (APDU framing, TLV parsing, EMV sequencing) is in Dart.
/// The native layer is a pure byte relay — no EMV logic runs on the platform.
class NfcCardReader implements INfcReader {
  final NfcBridge _bridge;
  final _stateCtrl = StreamController<CardReaderState>.broadcast();

  bool _isAvailable = false;
  bool _isScanning = false;
  StreamSubscription<Map<String, dynamic>>? _eventSub;

  NfcCardReader({NfcBridge? bridge}) : _bridge = bridge ?? NfcBridge();

  // ── INfcReader ────────────────────────────────────────────────────────────

  @override
  bool get isAvailable => _isAvailable;

  @override
  Stream<CardReaderState> get stateStream => _stateCtrl.stream;

  /// Probe NFC availability (call once after construction).
  Future<void> initialize() async {
    _isAvailable = await _bridge.isAvailable();
  }

  @override
  Future<void> startScan() async {
    if (_isScanning) return;

    // Lazily initialise availability on first call
    _isAvailable = await _bridge.isAvailable();

    if (!_isAvailable) {
      _emit(CardReaderErrorState(CardReaderException(
        code: CardReaderErrorCode.nfcNotAvailable,
        message: _unavailableMessage(),
      )));
      return;
    }

    _isScanning = true;
    _emit(const CardReaderScanningState(
      mode: CardReadMode.nfc,
      message: 'Hold your card near the device…',
    ));

    try {
      await _bridge.startSession(alertMessage: 'Hold card near the back of your device');
      _subscribeEvents();
    } catch (e) {
      _isScanning = false;
      final detail = e is PlatformException ? (e.message ?? e.code) : '$e';
      _emit(CardReaderErrorState(CardReaderException(
        code: _mapNativeErrorCode(detail),
        message: _mapNativeErrorMessage(
          detail.isEmpty ? 'Failed to start NFC session.' : detail,
        ),
        cause: e,
      )));
    }
  }

  @override
  Future<void> stopScan() async {
    if (!_isScanning) return;
    _isScanning = false;
    _eventSub?.cancel();
    _eventSub = null;
    try {
      await _bridge.stopSession();
    } catch (_) {}
    _emit(const CardReaderIdleState());
  }

  @override
  Future<void> dispose() async {
    await stopScan();
    await _stateCtrl.close();
  }

  // ── Event handling ────────────────────────────────────────────────────────

  void _subscribeEvents() {
    _eventSub?.cancel();
    _eventSub = _bridge.events.listen(
      _handleEvent,
      onError: (Object err) {
        _isScanning = false;
        _emit(CardReaderErrorState(CardReaderException(
          code: CardReaderErrorCode.unknown,
          message: 'Event stream error.',
          cause: err,
        )));
      },
    );
  }

  void _handleEvent(Map<String, dynamic> event) {
    switch (event['type'] as String?) {
      case 'tagDetected':
        if (!_isScanning) return;
        _emit(const CardReaderScanningState(
          mode: CardReadMode.nfc,
          message: 'Card detected — reading…',
        ));
        _readEmvCard();
      case 'sessionEnded':
        // Ignore programmatic invalidate after Success/Error (see _completeScan).
        if (!_isScanning) return;
        _isScanning = false;
        _eventSub?.cancel();
        _eventSub = null;
        _emit(const CardReaderIdleState());
      case 'error':
        // Ignore late invalidation errors after we already finished the scan.
        if (!_isScanning) return;
        _isScanning = false;
        _eventSub?.cancel();
        _eventSub = null;
        final message =
            event['message'] as String? ?? 'Unknown NFC error';
        _emit(CardReaderErrorState(CardReaderException(
          code: _mapNativeErrorCode(message),
          message: _mapNativeErrorMessage(message),
        )));
    }
  }

  // ── EMV read sequence ─────────────────────────────────────────────────────

  Future<void> _readEmvCard() async {
    try {
      final cardData = await _executeEmvSequence();
      await _completeScan(CardReaderSuccessState(cardData));
    } on CardReaderException catch (ex) {
      await _completeScan(
        CardReaderErrorState(ex),
        errorMessage: 'Read failed',
      );
    } on PlatformException catch (e) {
      final message = e.message ?? 'Platform error during NFC read';
      await _completeScan(
        CardReaderErrorState(CardReaderException(
          code: _mapNativeErrorCode(message),
          message: _mapNativeErrorMessage(message),
          cause: e,
        )),
        errorMessage: 'Read failed',
      );
    } catch (e) {
      await _completeScan(
        CardReaderErrorState(CardReaderException(
          code: CardReaderErrorCode.unknown,
          message: 'Unexpected error: $e',
          cause: e,
        )),
        errorMessage: 'Read failed',
      );
    }
  }

  /// Ends the native session without letting a late `sessionEnded` wipe the
  /// terminal Success/Error state (Idle overwrite race).
  Future<void> _completeScan(
    CardReaderState terminal, {
    String? errorMessage,
  }) async {
    _isScanning = false;
    _eventSub?.cancel();
    _eventSub = null;
    try {
      await _bridge.stopSession(errorMessage: errorMessage);
    } catch (_) {}
    _emit(terminal);
  }

  /// Human-readable reason when [NfcBridge.isAvailable] is false.
  ///
  /// On iOS, a missing NFC Tag Reading entitlement (typical for personal/free
  /// Apple ID teams) often makes CoreNFC report unavailable even on NFC phones.
  static String _unavailableMessage() {
    if (Platform.isIOS) {
      return 'NFC is unavailable. On iOS the host app needs the NFC Tag '
          'Reading entitlement and a paid Apple Developer Program team '
          '(personal/free teams cannot sign it). '
          'See doc/IOS_NFC_SETUP.md.';
    }
    return 'NFC is not available or disabled on this device.';
  }

  static CardReaderErrorCode _mapNativeErrorCode(String message) {
    final lower = message.toLowerCase();
    if (lower.contains('entitlement') ||
        lower.contains('security violation') ||
        lower.contains('payment')) {
      return CardReaderErrorCode.nfcNotAvailable;
    }
    if (lower.contains('timeout') || lower.contains('timed out')) {
      return CardReaderErrorCode.nfcSessionTimeout;
    }
    if (lower.contains('tag connection') ||
        lower.contains('tag was lost') ||
        lower.contains('tag lost')) {
      return CardReaderErrorCode.nfcTagLost;
    }
    return CardReaderErrorCode.nfcTransceiveFailed;
  }

  static String _mapNativeErrorMessage(String message) {
    final lower = message.toLowerCase();
    if (lower.contains('entitlement') ||
        lower.contains('security violation') ||
        lower.contains('payment')) {
      return 'NFC session blocked by iOS (missing TAG entitlement, or '
          'payment AID not allowed by CoreNFC). '
          'See doc/IOS_NFC_SETUP.md. Original: $message';
    }
    return message;
  }

  Future<CardData> _executeEmvSequence() async {
    // ── Step 1: SELECT PPSE ────────────────────────────────────────────────
    final ppseResp = await _transceive(ApduCommand.selectPpse());
    _assertSuccess(ppseResp, 'SELECT PPSE');

    final ppseTlv = EmvParser.parseTlv(ppseResp.data);
    final aid = EmvParser.extractAid(ppseTlv);
    if (aid == null) {
      throw const CardReaderException(
        code: CardReaderErrorCode.nfcUnsupportedCard,
        message: 'No Application ID found in PPSE response.',
      );
    }

    // ── Step 2: SELECT Application ─────────────────────────────────────────
    final appResp = await _transceive(ApduCommand.selectApplication(aid));
    _assertSuccess(appResp, 'SELECT Application');

    // Extract PDOL (tag 0x9F38) from FCI so we can build a proper GPO payload.
    // If no PDOL is advertised, null → getProcessingOptions uses empty template.
    final appTlv = EmvParser.parseTlv(appResp.data);
    final pdolNode = EmvParser.findTag(appTlv, EmvTags.pdol);
    final pdolData =
        pdolNode != null ? EmvParser.buildPdolData(pdolNode) : null;

    // ── Step 3: GET PROCESSING OPTIONS ─────────────────────────────────────
    // GPO is not supported by all cards (e.g. some contactless-only issuers
    // return SW=6D00). Treat failure as a soft error: AFL stays empty and the
    // fallback full-SFI scan below will still recover the card data.
    List<Map<String, int>> aflRecords = [];
    final gpoResp =
        await _transceive(ApduCommand.getProcessingOptions(pdolData));
    if (gpoResp.isSuccess) {
      final gpoTlv = EmvParser.parseTlv(gpoResp.data);
      // AFL may be in template Format 1 (0x80) or Format 2 (0x77)
      aflRecords = EmvParser.extractAfl(gpoTlv);
      if (aflRecords.isEmpty) {
        aflRecords = EmvParser.extractAflFromTemplate1(gpoTlv);
      }
    }

    // ── Step 4: READ RECORDs ───────────────────────────────────────────────
    String? pan;
    String? expiryDate;
    String? cardholderName;

    for (final entry in aflRecords) {
      if (pan != null && expiryDate != null) break;

      final recResp = await _transceive(
        ApduCommand.readRecord(entry['record']!, entry['sfi']!),
      );
      if (!recResp.isSuccess) continue;

      final recTlv = EmvParser.parseTlv(recResp.data);

      pan ??= EmvParser.extractPan(recTlv)
          ?? EmvParser.extractPanFromTrack2(recTlv);
      expiryDate ??= EmvParser.extractExpiryDate(recTlv)
          ?? EmvParser.extractExpiryFromTrack2(recTlv);
      cardholderName ??= EmvParser.extractCardholderName(recTlv);
    }

    // ── Fallback: scan all SFIs 1-10, records 1-8 ─────────────────────────
    if (pan == null || expiryDate == null) {
      outer:
      for (int sfi = 1; sfi <= 10; sfi++) {
        for (int rec = 1; rec <= 8; rec++) {
          final r = await _transceive(ApduCommand.readRecord(rec, sfi));
          if (!r.isSuccess) continue;
          final t = EmvParser.parseTlv(r.data);
          pan ??= EmvParser.extractPan(t) ?? EmvParser.extractPanFromTrack2(t);
          expiryDate ??= EmvParser.extractExpiryDate(t)
              ?? EmvParser.extractExpiryFromTrack2(t);
          cardholderName ??= EmvParser.extractCardholderName(t);
          if (pan != null && expiryDate != null) break outer;
        }
      }
    }

    if (pan == null || expiryDate == null) {
      throw const CardReaderException(
        code: CardReaderErrorCode.nfcUnsupportedCard,
        message: 'Could not extract PAN / expiry from EMV records.',
      );
    }

    return CardData.fromNfc(
      pan: pan,
      expiryDate: expiryDate,
      cardholderName: cardholderName,
    );
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  Future<ApduResponse> _transceive(ApduCommand cmd) async {
    final raw = await _bridge.transceive(cmd.toBytes());
    final resp = ApduResponse.parse(raw);

    // Handle GET RESPONSE chaining (SW1 = 0x61)
    if (resp.needsGetResponse) {
      final getResp = await _bridge.transceive(
        ApduCommand(
          cla: 0x00, ins: 0xC0, p1: 0x00, p2: 0x00,
          le: resp.bytesAvailable,
        ).toBytes(),
      );
      return ApduResponse.parse([...resp.data, ...getResp]);
    }

    return resp;
  }

  void _assertSuccess(ApduResponse resp, String step) {
    if (!resp.isSuccess) {
      throw CardReaderException(
        code: CardReaderErrorCode.nfcTransceiveFailed,
        message: '$step failed — ${resp.statusDescription}',
      );
    }
  }

  void _emit(CardReaderState state) {
    if (!_stateCtrl.isClosed) _stateCtrl.add(state);
  }
}
