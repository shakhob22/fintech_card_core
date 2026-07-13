import 'package:flutter_test/flutter_test.dart';
import 'package:fintech_card_core/fintech_card_core.dart';
import 'package:fintech_card_core/fintech_card_core_platform_interface.dart';
import 'package:fintech_card_core/fintech_card_core_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockFintechCardCorePlatform
    with MockPlatformInterfaceMixin
    implements FintechCardCorePlatform {
  @override
  Future<String?> getPlatformVersion() => Future.value('42');
}

void main() {
  final FintechCardCorePlatform initialPlatform = FintechCardCorePlatform.instance;

  test('$MethodChannelFintechCardCore is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelFintechCardCore>());
  });

  test('getPlatformVersion', () async {
    FintechCardCore fintechCardCorePlugin = FintechCardCore();
    MockFintechCardCorePlatform fakePlatform = MockFintechCardCorePlatform();
    FintechCardCorePlatform.instance = fakePlatform;

    expect(await fintechCardCorePlugin.getPlatformVersion(), '42');
  });
}
