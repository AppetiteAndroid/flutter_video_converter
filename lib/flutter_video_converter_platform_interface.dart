import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'flutter_video_converter_method_channel.dart';

abstract class FlutterVideoConverterPlatform extends PlatformInterface {
  /// Constructs a FlutterVideoConverterPlatform.
  FlutterVideoConverterPlatform() : super(token: _token);

  static final Object _token = Object();

  static FlutterVideoConverterPlatform _instance = MethodChannelFlutterVideoConverter();

  /// The default instance of [FlutterVideoConverterPlatform] to use.
  ///
  /// Defaults to [MethodChannelFlutterVideoConverter].
  static FlutterVideoConverterPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [FlutterVideoConverterPlatform] when
  /// they register themselves.
  static set instance(FlutterVideoConverterPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
