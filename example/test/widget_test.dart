import 'package:flutter_test/flutter_test.dart';
import 'package:fintech_card_core_example/main.dart';

void main() {
  testWidgets('Demo home shows three reading modes', (tester) async {
    await tester.pumpWidget(const ExampleApp());
    await tester.pumpAndSettle();

    expect(find.text('fintech_card_core'), findsOneWidget);
    expect(find.text('NFC'), findsWidgets);
    expect(find.text('Camera'), findsWidgets);
    expect(find.text('Manual'), findsWidgets);
    expect(find.text('Scan with NFC'), findsOneWidget);
  });

  testWidgets('Can open Manual tab', (tester) async {
    await tester.pumpWidget(const ExampleApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Manual').last);
    await tester.pumpAndSettle();

    expect(find.text('Input scheme'), findsOneWidget);
  });
}
