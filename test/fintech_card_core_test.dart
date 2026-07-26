import 'dart:async';
import 'dart:ui' show Rect;

import 'package:camera/camera.dart';
import 'package:fintech_card_core/fintech_card_core.dart';
import 'package:flutter_test/flutter_test.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Fake sub-reader implementations for unit testing
//
// These replace NfcCardReader and OcrCardScanner so no MethodChannels are
// called (no platform plugins required).  All assertion logic stays in Dart.
// ─────────────────────────────────────────────────────────────────────────────

class _FakeNfcReader implements INfcReader {
  final _ctrl = StreamController<CardReaderState>.broadcast();
  @override bool get isAvailable => false;
  @override Stream<CardReaderState> get stateStream => _ctrl.stream;
  @override Future<void> startScan() async {}
  @override Future<void> stopScan() async {}
  @override Future<void> dispose() async { await _ctrl.close(); }
}

class _FakeOcrScanner implements IOcrScanner {
  final _ctrl = StreamController<CardReaderState>.broadcast();
  @override CameraController? get cameraController => null;
  @override Stream<CardReaderState> get stateStream => _ctrl.stream;
  @override void setScanRoi(Rect? normalizedRoi) {}
  @override Future<void> startScan() async {}
  @override Future<void> stopScan() async {}
  @override Future<void> dispose() async { await _ctrl.close(); }
}

/// Creates a [CardReaderController] wired with fakes — no platform channels.
CardReaderController fakeController() => CardReaderController(
  nfcReader: _FakeNfcReader(),
  ocrScanner: _FakeOcrScanner(),
);

// ─────────────────────────────────────────────────────────────────────────────

void main() {
  // ── CardData ──────────────────────────────────────────────────────────────

  group('CardData', () {
    test('detects Visa from BIN', () {
      final card = CardData.fromManual(pan: '4111111111111111', expiryDate: '12/28');
      expect(card.cardType, CardType.visa);
      expect(card.readMode, CardReadMode.manual);
    });

    test('detects Mastercard from BIN', () {
      final card = CardData.fromManual(pan: '5500005555555559', expiryDate: '08/27');
      expect(card.cardType, CardType.mastercard);
    });

    test('detects Amex from BIN', () {
      final card = CardData.fromManual(pan: '371449635398431', expiryDate: '03/26');
      expect(card.cardType, CardType.amex);
    });

    test('maskedPan shows only last 4 digits', () {
      final card = CardData.fromManual(pan: '4111111111111111', expiryDate: '12/28');
      expect(card.maskedPan, endsWith('1111'));
      expect(card.maskedPan, startsWith('*'));
    });

    test('formattedPan inserts spaces every 4 digits', () {
      final card = CardData.fromManual(pan: '4111111111111111', expiryDate: '12/28');
      expect(card.formattedPan, '4111 1111 1111 1111');
    });

    test('equality — same field values produce equal objects', () {
      final ts = DateTime.utc(2026, 1, 1);
      final a = CardData(
        pan: '4111111111111111', expiryDate: '12/28',
        cardType: CardType.visa, readMode: CardReadMode.manual, timestamp: ts,
      );
      final b = CardData(
        pan: '4111111111111111', expiryDate: '12/28',
        cardType: CardType.visa, readMode: CardReadMode.manual, timestamp: ts,
      );
      expect(a, equals(b));
    });
  });

  // ── CardReaderController — manual input ───────────────────────────────────

  group('CardReaderController — manual input', () {
    late CardReaderController ctrl;
    setUp(() => ctrl = fakeController());
    tearDown(() => ctrl.dispose());

    test('accepts Luhn-valid PAN (with spaces)', () async {
      final card = await ctrl.submitManualInput(
        pan: '4111 1111 1111 1111',
        expiryDate: '12/28',
        cvv: '737',
      );
      expect(card.pan, '4111111111111111');
      expect(card.cardType, CardType.visa);
      expect(card.readMode, CardReadMode.manual);
    });

    test('rejects Luhn-invalid PAN', () {
      expect(
        () => ctrl.submitManualInput(pan: '4111111111111112', expiryDate: '12/28'),
        throwsA(isA<CardReaderException>().having(
          (e) => e.code, 'code', CardReaderErrorCode.manualInputInvalid,
        )),
      );
    });

    test('rejects invalid expiry format', () {
      expect(
        () => ctrl.submitManualInput(pan: '4111111111111111', expiryDate: '1228'),
        throwsA(isA<CardReaderException>().having(
          (e) => e.code, 'code', CardReaderErrorCode.manualInputInvalid,
        )),
      );
    });

    test('emits CardReaderSuccessState to stateStream', () async {
      CardReaderState? lastState;
      ctrl.stateStream.listen((s) => lastState = s);

      await ctrl.submitManualInput(pan: '4111111111111111', expiryDate: '12/28');

      expect(lastState, isA<CardReaderSuccessState>());
      expect(
        (lastState as CardReaderSuccessState).data.maskedPan,
        endsWith('1111'),
      );
    });
  });

  // ── EMV TLV Parser ────────────────────────────────────────────────────────

  group('EmvParser — TLV parsing', () {
    test('parseTlv extracts a single primitive tag', () {
      // TLV: Tag=0x5A, Len=8, Value=BCD PAN 4111111111111111
      final raw = [0x5A, 0x08, 0x41, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11];
      final tlv = EmvParser.parseTlv(raw);
      expect(tlv.length, 1);
      expect(tlv.first.tag, EmvTags.pan);
    });

    test('extractPan decodes 16-digit BCD PAN', () {
      // 4111111111111111 → BCD: 41 11 11 11 11 11 11 11 (no F padding needed)
      final raw = [0x5A, 0x08, 0x41, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11];
      expect(EmvParser.extractPan(EmvParser.parseTlv(raw)), '4111111111111111');
    });

    test('extractPan strips trailing F from 15-digit Amex PAN', () {
      // 371449635398431 → BCD: 37 14 49 63 53 98 43 1F  (trailing F padding)
      final raw = [0x5A, 0x08, 0x37, 0x14, 0x49, 0x63, 0x53, 0x98, 0x43, 0x1F];
      expect(EmvParser.extractPan(EmvParser.parseTlv(raw)), '371449635398431');
    });

    test('extractExpiryDate converts YYMMDD BCD to MM/YY', () {
      // Expiry 12/28 → YYMMDD: 28 12 31
      final raw = [0x5F, 0x24, 0x03, 0x28, 0x12, 0x31];
      expect(EmvParser.extractExpiryDate(EmvParser.parseTlv(raw)), '12/28');
    });

    test('extractAfl returns correct SFI/record map entries', () {
      // AFL: SFI=1 (0x08>>3), first=1, last=2
      final raw = [0x94, 0x04, 0x08, 0x01, 0x02, 0x00];
      final afl = EmvParser.extractAfl(EmvParser.parseTlv(raw));
      expect(afl.length, 2);
      expect(afl.first, {'sfi': 1, 'record': 1});
      expect(afl.last,  {'sfi': 1, 'record': 2});
    });
  });

  // ── OCR Parser ────────────────────────────────────────────────────────────

  group('OcrParser', () {
    test('extracts 16-digit Visa PAN and expiry', () {
      const text = 'VALID THRU\n4111 1111 1111 1111\n12/28\nJOHN DOE';
      final card = OcrParser.parse(text);
      expect(card?.pan, '4111111111111111');
      expect(card?.expiryDate, '12/28');
      expect(card?.readMode, CardReadMode.ocr);
    });

    test('extracts hyphen-separated PAN', () {
      final card = OcrParser.parse('5500-0055-5555-5559 08/27');
      expect(card?.pan, '5500005555555559');
    });

    test('returns null when no PAN found', () {
      expect(OcrParser.parse('No card info here'), isNull);
    });

    test('allows PAN-only when expiry is missing', () {
      final card = OcrParser.parse('4111 1111 1111 1111');
      expect(card?.pan, '4111111111111111');
      expect(card?.expiryDate, isNull);
    });
  });

  // ── APDU Command ─────────────────────────────────────────────────────────

  group('ApduCommand serialization', () {
    test('selectPpse header bytes', () {
      final b = ApduCommand.selectPpse().toBytes();
      expect(b[0], 0x00); expect(b[1], 0xA4); // CLA, INS
      expect(b[2], 0x04); expect(b[3], 0x00); // P1, P2
      expect(b[4], 14);                        // Lc = len("2PAY.SYS.DDF01")
    });

    test('readRecord encodes SFI in P2', () {
      final b = ApduCommand.readRecord(1, 2).toBytes();
      expect(b[2], 1);              // P1 = record number
      expect(b[3], (2 << 3) | 4);  // P2 = (SFI << 3) | 4
    });

    test('selectApplication includes AID bytes', () {
      final aid = [0xA0, 0x00, 0x00, 0x00, 0x03, 0x10, 0x10];
      final b = ApduCommand.selectApplication(aid).toBytes();
      expect(b[4], aid.length);
      expect(b.sublist(5, 5 + aid.length), aid);
    });
  });

  // ── APDU Response ─────────────────────────────────────────────────────────

  group('ApduResponse parsing', () {
    test('isSuccess for SW=0x9000', () {
      final resp = ApduResponse.parse([0xAB, 0xCD, 0x90, 0x00]);
      expect(resp.isSuccess, isTrue);
      expect(resp.data, [0xAB, 0xCD]);
      expect(resp.statusHex, '9000');
    });

    test('throws FormatException for < 2 bytes', () {
      expect(() => ApduResponse.parse([0x90]), throwsFormatException);
    });

    test('needsGetResponse for SW1=0x61', () {
      final resp = ApduResponse.parse([0x61, 0x10]);
      expect(resp.needsGetResponse, isTrue);
      expect(resp.bytesAvailable, 0x10);
    });

    test('statusDescription is human-readable', () {
      expect(ApduResponse.parse([0x6A, 0x82]).statusDescription, contains('not found'));
    });
  });
}
