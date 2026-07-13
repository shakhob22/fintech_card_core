import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'fintech_card_core_platform_interface.dart';

/// An implementation of [FintechCardCorePlatform] that uses method channels.
class MethodChannelFintechCardCore extends FintechCardCorePlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('fintech_card_core');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>(
      'getPlatformVersion',
    );
    return version;
  }
}
