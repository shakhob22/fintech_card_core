import 'card_data.dart';
import 'card_enums.dart';
import 'card_reader_exception.dart';

/// Sealed state hierarchy for the [CardReaderController] state machine.
///
/// Exhaustive pattern matching is enforced at compile time (Dart 3 sealed):
/// ```dart
/// switch (state) {
///   case CardReaderIdleState():    ...
///   case CardReaderScanningState(): ...
///   case CardReaderSuccessState():  ...
///   case CardReaderErrorState():    ...
/// }
/// ```
sealed class CardReaderState {
  const CardReaderState();
}

/// The controller is idle and not actively reading.
final class CardReaderIdleState extends CardReaderState {
  const CardReaderIdleState();
}

/// An active scan is in progress on [mode].
final class CardReaderScanningState extends CardReaderState {
  final CardReadMode mode;

  /// Human-readable hint to display in the UI (e.g. "Hold card near device").
  final String? message;

  const CardReaderScanningState({required this.mode, this.message});
}

/// A card was read successfully; [data] contains the extracted card info.
final class CardReaderSuccessState extends CardReaderState {
  final CardData data;
  const CardReaderSuccessState(this.data);
}

/// An error occurred; [exception] carries the structured error detail.
final class CardReaderErrorState extends CardReaderState {
  final CardReaderException exception;
  const CardReaderErrorState(this.exception);
}
