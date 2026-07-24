/// TFLite card OCR module for [fintech_card_core].
///
/// Prefer this import when you only need the on-device CRNN scanner:
/// ```dart
/// import 'package:fintech_card_core/card_ocr_plugin.dart';
///
/// CardScannerView(
///   onCardScanned: (pan) => print(pan),
/// );
/// ```
///
/// Full card-reader API (NFC / manual / mock) remains available via
/// `package:fintech_card_core/fintech_card_core.dart`.
library;

export 'src/core/luhn.dart' show Luhn;
export 'src/ocr/ocr_result_accumulator.dart' show OcrResultAccumulator;
export 'src/ocr/ocr_roi.dart' show OcrRoi;
export 'src/services/card_ocr_engine.dart'
    show
        CardOcrEngine,
        CtcLayout,
        OcrPreprocessResult,
        flattenToTc,
        preprocessFrame;
export 'src/ui/card_scanner_view.dart'
    show CardScannerView, CardScannerViewTheme;
