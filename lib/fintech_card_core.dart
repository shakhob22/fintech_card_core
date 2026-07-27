// fintech_card_core — Headless Flutter plugin for payment card reading.
//
// Quick start:
//   final controller = CardReaderController();
//   controller.stateStream.listen((state) { ... });
//   await controller.startNfcScan();      // NFC
//   await controller.startOcrScan();      // OCR
//   await controller.submitManualInput(pan: '4111...', expiryDate: '12/28');
// ── Core ─────────────────────────────────────────────────────────────────────
export 'src/core/card_reader_controller.dart'
    show ICardReaderController, CardReaderController;

// ── Models ────────────────────────────────────────────────────────────────────
export 'src/core/models/card_data.dart' show CardData;
export 'src/core/models/card_enums.dart'
    show CardType, CardReadMode, CardInputScheme;
export 'src/core/models/card_reader_exception.dart'
    show CardReaderException, CardReaderErrorCode;
export 'src/core/models/card_reader_state.dart'
    show
        CardReaderState,
        CardReaderIdleState,
        CardReaderScanningState,
        CardReaderSuccessState,
        CardReaderErrorState;

// ── Interfaces (for DI / testing) ─────────────────────────────────────────────
export 'src/core/interfaces/i_nfc_reader.dart' show INfcReader;
export 'src/core/interfaces/i_ocr_scanner.dart' show IOcrScanner;

// ── NFC internals (advanced usage) ───────────────────────────────────────────
export 'src/nfc/nfc_bridge.dart' show NfcBridge;
export 'src/nfc/nfc_card_reader.dart' show NfcCardReader;
export 'src/nfc/apdu/apdu_command.dart' show ApduCommand;
export 'src/nfc/apdu/apdu_response.dart' show ApduResponse;
export 'src/nfc/emv/emv_tags.dart' show EmvTags;
export 'src/nfc/emv/emv_parser.dart' show EmvParser, TlvObject;

// ── OCR ───────────────────────────────────────────────────────────────────────
export 'src/ocr/ocr_card_scanner.dart' show OcrCardScanner;
export 'src/ocr/ocr_parser.dart' show OcrParser, PartialOcrResult;
export 'src/ocr/ocr_result_accumulator.dart' show OcrResultAccumulator;
export 'src/ocr/ocr_roi.dart' show OcrRoi;
export 'src/ocr/frame_consensus_buffer.dart' show FrameConsensusBuffer;
export 'src/ocr/pan_heuristics.dart' show PanHeuristics;
export 'src/ocr/native_preprocessor.dart'
    show FramePreprocessor, PreprocessedFrame, CardCvMode;
export 'src/ocr/engine/card_ocr_engine_result.dart' show CardOcrEngineResult;
export 'src/ocr/engine/card_ocr_backend.dart' show CardOcrBackend;
export 'src/ocr/engine/card_scan_card_ocr_backend.dart'
    show CardScanCardOcrBackend;
export 'src/core/luhn.dart' show Luhn;

// ── UI (optional pre-built widgets) ──────────────────────────────────────────
export 'src/ui/smart_card_input.dart'
    show SmartCardInput, SmartCardInputStyle, CardBrandBadge;
export 'src/ui/nfc_scan_dialog.dart'
    show NfcScanDialog, NfcScanDialogTheme, NfcScanDialogStatus;
export 'src/ui/card_scanner_overlay.dart'
    show CardScannerOverlay, CardScannerOverlayTheme, CardScannerOverlayStatus;
