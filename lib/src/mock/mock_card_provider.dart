import '../core/interfaces/i_mock_provider.dart';
import '../core/models/card_data.dart';
import '../core/models/card_enums.dart';
import '../core/models/card_reader_exception.dart';
import 'mock_cards.dart';

/// Developer-mode implementation of [IMockProvider].
///
/// Returns dummy card data instantly or after a configurable delay,
/// and can simulate error/declined scenarios without touching any real API.
class MockCardProvider implements IMockProvider {
  /// Optional global delay applied to every [getCard] call unless overridden.
  final Duration defaultDelay;

  const MockCardProvider({this.defaultDelay = Duration.zero});

  @override
  Future<CardData> getCard({MockCardPreset preset = MockCardPreset.visa}) async {
    if (defaultDelay != Duration.zero) {
      await Future<void>.delayed(defaultDelay);
    }
    return _buildCard(preset);
  }

  @override
  Future<CardData> getCardWithDelay({
    MockCardPreset preset = MockCardPreset.visa,
    Duration delay = const Duration(seconds: 2),
  }) async {
    await Future<void>.delayed(delay);
    return _buildCard(preset);
  }

  @override
  Future<void> simulateError({
    Duration delay = const Duration(seconds: 1),
  }) async {
    await Future<void>.delayed(delay);
    throw const CardReaderException(
      code: CardReaderErrorCode.mockProviderError,
      message: 'Simulated transaction declined — no real network call was made.',
    );
  }

  // ── Builder ───────────────────────────────────────────────────────────────

  static CardData _buildCard(MockCardPreset preset) {
    final card = MockCards.get(preset);
    return CardData.fromMock(
      pan: card.pan,
      expiryDate: card.expiryDate,
      cvv: card.cvv,
      cardholderName: card.cardholderName,
    );
  }
}
