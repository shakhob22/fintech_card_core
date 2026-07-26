/// Machine-readable error codes emitted by the card-reader engine.
enum CardReaderErrorCode {
  // NFC errors
  nfcNotAvailable,
  nfcSessionTimeout,
  nfcTagLost,
  nfcTransceiveFailed,
  nfcUnsupportedCard,

  // OCR errors
  ocrCameraPermissionDenied,
  ocrNoCardDetected,
  ocrParsingFailed,

  // Manual-input errors
  manualInputInvalid,

  // Fallback
  unknown,
}

/// Structured exception thrown by all card-reader operations.
class CardReaderException implements Exception {
  final CardReaderErrorCode code;
  final String message;

  /// Original platform or Dart exception that caused this error (if any).
  final Object? cause;

  const CardReaderException({
    required this.code,
    required this.message,
    this.cause,
  });

  @override
  String toString() => 'CardReaderException(${code.name}): $message'
      '${cause != null ? ' — caused by: $cause' : ''}';
}
