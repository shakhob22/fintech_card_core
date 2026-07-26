import 'package:fintech_card_core/fintech_card_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('CardReaderController — manual input (no hardware required)', () {
    late CardReaderController controller;

    setUp(() => controller = CardReaderController());
    tearDown(() => controller.dispose());

    testWidgets('submitManualInput validates Luhn', (tester) async {
      expect(
        () => controller.submitManualInput(
          pan: '1234567890123456', // fails Luhn
          expiryDate: '12/28',
        ),
        throwsA(isA<CardReaderException>().having(
          (e) => e.code,
          'code',
          CardReaderErrorCode.manualInputInvalid,
        )),
      );
    });

    testWidgets('submitManualInput accepts valid card', (tester) async {
      final card = await controller.submitManualInput(
        pan: '4111111111111111',
        expiryDate: '12/28',
        cvv: '737',
      );
      expect(card.cardType, CardType.visa);
      expect(card.readMode, CardReadMode.manual);
      expect(card.maskedPan, endsWith('1111'));
    });

    testWidgets('stateStream emits success after manual input', (tester) async {
      final states = <CardReaderState>[];
      final sub = controller.stateStream.listen(states.add);

      await controller.submitManualInput(
        pan: '4111111111111111',
        expiryDate: '12/28',
      );
      await sub.cancel();

      expect(states.last, isA<CardReaderSuccessState>());
    });
  });
}
