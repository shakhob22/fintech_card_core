import '../models/card_data.dart';
import '../models/card_enums.dart';

/// Contract for the Developer-Mode mock card provider.
///
/// All returned cards use industry-standard dummy PAN values (Luhn-valid,
/// never real cards). No maps, locations, or external integrations are used.
abstract interface class IMockProvider {
  /// Return a mock [CardData] for the given [preset] immediately.
  Future<CardData> getCard({MockCardPreset preset = MockCardPreset.visa});

  /// Return a mock [CardData] after an artificial [delay] (simulates latency).
  Future<CardData> getCardWithDelay({
    MockCardPreset preset = MockCardPreset.visa,
    Duration delay = const Duration(seconds: 2),
  });

  /// Throw a [CardReaderException] after [delay] (simulates a declined / error
  /// scenario without touching any real network endpoint).
  Future<void> simulateError({Duration delay = const Duration(seconds: 1)});
}
