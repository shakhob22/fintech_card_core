import 'package:fintech_card_core/fintech_card_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CardBrandBadge.match', () {
    test('returns null for empty pan or empty list', () {
      expect(CardBrandBadge.match(const [], '1234'), isNull);
      expect(
        CardBrandBadge.match(
          [CardBrandBadge(prefix: '12', badge: const SizedBox())],
          '',
        ),
        isNull,
      );
    });

    test('longest prefix wins', () {
      final badges = [
        CardBrandBadge(prefix: '1', badge: const SizedBox(key: Key('1'))),
        CardBrandBadge(prefix: '12', badge: const SizedBox(key: Key('12'))),
        CardBrandBadge(prefix: '1212', badge: const SizedBox(key: Key('1212'))),
      ];
      expect(CardBrandBadge.match(badges, '1')!.normalizedPrefix, '1');
      expect(CardBrandBadge.match(badges, '12')!.normalizedPrefix, '12');
      expect(CardBrandBadge.match(badges, '1212 9999')!.normalizedPrefix, '1212');
    });

    test('strips non-digits from prefix and pan', () {
      final badges = [
        CardBrandBadge(prefix: '08-8', badge: const SizedBox()),
      ];
      expect(CardBrandBadge.match(badges, '0881')!.normalizedPrefix, '088');
    });

    test('ignores empty and overlong prefixes', () {
      final badges = [
        CardBrandBadge(prefix: '', badge: const SizedBox()),
        CardBrandBadge(prefix: '123456789', badge: const SizedBox()), // 9 digits
        CardBrandBadge(prefix: '99', badge: const SizedBox()),
      ];
      expect(CardBrandBadge.match(badges, '99')!.normalizedPrefix, '99');
      expect(CardBrandBadge.match(badges, '123456789'), isNull);
    });
  });
}
