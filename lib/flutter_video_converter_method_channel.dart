import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'flutter_video_converter_platform_interface.dart';

/// An implementation of [FlutterVideoConverterPlatform] that uses method channels.
class MethodChannelFlutterVideoConverter extends FlutterVideoConverterPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('flutter_video_converter');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>('getPlatformVersion');
    return version;
  }
}
