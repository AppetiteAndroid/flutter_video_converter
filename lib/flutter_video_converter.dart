import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Качество видео для конвертации
enum VideoQuality {
  /// Высокое качество, большой размер файла
  high,

  /// Стандартное качество, сбалансированный размер файла (по умолчанию)
  medium,

  /// Низкое качество, маленький размер файла
  low
}

/// Формат выходного видео
enum VideoFormat {
  /// MP4 формат (по умолчанию)
  mp4,

  /// MOV формат
  mov,

  /// WebM формат
  webm,

  /// AVI формат
  avi,
}

/// Extension для получения строкового представления формата видео
extension VideoFormatExtension on VideoFormat {
  String get value {
    switch (this) {
      case VideoFormat.mp4:
        return 'mp4';
      case VideoFormat.mov:
        return 'mov';
      case VideoFormat.webm:
        return 'webm';
      case VideoFormat.avi:
        return 'avi';
      default:
        return 'mp4';
    }
  }
}

/// Extension для получения строкового представления качества видео
extension VideoQualityExtension on VideoQuality {
  String get value {
    switch (this) {
      case VideoQuality.high:
        return 'high';
      case VideoQuality.medium:
        return 'medium';
      case VideoQuality.low:
        return 'low';
      default:
        return 'medium';
    }
  }
}

/// A Flutter plugin for converting videos to MP4 format on Android and iOS.
class FlutterVideoConverter {
  /// The method channel used to communicate with the native code.
  static const MethodChannel _channel = MethodChannel('com.example.flutter_video_converter/converter');

  /// The event channel used to receive progress updates from native code.
  static const EventChannel _progressChannel = EventChannel('com.example.flutter_video_converter/converter/progress');

  /// Converts a video file to specified format with selected quality.
  ///
  /// The [videoFile] is the source video file to convert.
  /// The [quality] specifies the output video quality (high, medium, low). Defaults to medium.
  /// The [format] specifies the output video format (mp4, mov, webm, avi). Defaults to mp4.
  /// The [onProgress] callback provides progress updates during conversion (path, 0.0 to 1.0).
  ///
  /// Returns the path to the converted video file, or null if conversion failed.
  static Future<String?> convertVideo(
    File videoFile, {
    VideoQuality quality = VideoQuality.medium,
    VideoFormat format = VideoFormat.mp4,
    Function(String, double)? onProgress,
  }) async {
    try {
      // Set up progress listener if callback is provided
      if (onProgress != null) {
        _progressChannel.receiveBroadcastStream().listen((dynamic event) {
          if (event is Map) {
            // Extract path and progress from the map
            final String path = event['path'] as String? ?? videoFile.path;
            final double progress = event['progress'] as double? ?? 0.0;
            onProgress(path, progress);
          } else if (event is double) {
            // Backward compatibility for platforms that only send progress
            onProgress(videoFile.path, event);
          }
        });
      }

      final String? outputPath = await _channel.invokeMethod<String>(
        'convertVideo',
        {
          'videoPath': videoFile.path,
          'quality': quality.value,
          'format': format.value,
        },
      );
      return outputPath;
    } on PlatformException catch (e) {
      debugPrint('Failed to convert video: ${e.message}');
      return null;
    }
  }
}
