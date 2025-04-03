import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_video_converter/flutter_video_converter.dart';
import 'package:flutter_video_converter/flutter_video_converter_platform_interface.dart';
import 'package:flutter_video_converter/flutter_video_converter_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockFlutterVideoConverterPlatform
    with MockPlatformInterfaceMixin
    implements FlutterVideoConverterPlatform {

  @override
  Future<String?> getPlatformVersion() => Future.value('42');
}

void main() {
  final FlutterVideoConverterPlatform initialPlatform = FlutterVideoConverterPlatform.instance;

  test('$MethodChannelFlutterVideoConverter is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelFlutterVideoConverter>());
  });

  test('getPlatformVersion', () async {
    FlutterVideoConverter flutterVideoConverterPlugin = FlutterVideoConverter();
    MockFlutterVideoConverterPlatform fakePlatform = MockFlutterVideoConverterPlatform();
    FlutterVideoConverterPlatform.instance = fakePlatform;

    expect(await flutterVideoConverterPlugin.getPlatformVersion(), '42');
  });
}
