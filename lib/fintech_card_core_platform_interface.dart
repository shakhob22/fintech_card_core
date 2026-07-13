import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'fintech_card_core_method_channel.dart';

abstract class FintechCardCorePlatform extends PlatformInterface {
  /// Constructs a FintechCardCorePlatform.
  FintechCardCorePlatform() : super(token: _token);

  static final Object _token = Object();

  static FintechCardCorePlatform _instance = MethodChannelFintechCardCore();

  /// The default instance of [FintechCardCorePlatform] to use.
  ///
  /// Defaults to [MethodChannelFintechCardCore].
  static FintechCardCorePlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [FintechCardCorePlatform] when
  /// they register themselves.
  static set instance(FintechCardCorePlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
