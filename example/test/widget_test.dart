import 'package:flutter_test/flutter_test.dart';
import 'package:fintech_card_core_example/main.dart';

void main() {
  testWidgets('ExampleApp renders without error', (WidgetTester tester) async {
    await tester.pumpWidget(const ExampleApp());
    await tester.pumpAndSettle();

    // Bottom nav with three tabs should be present
    expect(find.text('NFC'), findsOneWidget);
    expect(find.text('Manual'), findsOneWidget);
    expect(find.text('Mock'), findsOneWidget);
  });
}
