import 'dart:io';
import 'dart:async';
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

  /// Keep track of the active subscription
  static StreamSubscription? _activeProgressSubscription;

  /// Track the last progress value to avoid duplicate updates
  static double _lastProgress = -1.0;

  /// Track the last update time for debouncing
  static DateTime? _lastUpdateTime;

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
      // Cancel any existing subscription
      await _activeProgressSubscription?.cancel();
      _activeProgressSubscription = null;

      // Reset progress tracking variables
      _lastProgress = -1.0;
      _lastUpdateTime = null;

      // Set up progress listener if callback is provided
      if (onProgress != null) {
        _activeProgressSubscription = _progressChannel.receiveBroadcastStream().listen((dynamic event) {
          final now = DateTime.now();

          // Process the event data
          String path = videoFile.path;
          double progress = 0.0;

          if (event is Map) {
            // Extract path and progress from the map
            path = event['path'] as String? ?? videoFile.path;
            progress = event['progress'] as double? ?? 0.0;
            debugPrint('📣 MAP EVENT - Path: $path, Progress: ${(progress * 100).toStringAsFixed(0)}%');
          } else if (event is double) {
            // Backward compatibility for platforms that only send progress
            progress = event;
            debugPrint('📣 DOUBLE EVENT - Progress: ${(progress * 100).toStringAsFixed(0)}%');
          } else {
            debugPrint('📣 UNKNOWN EVENT TYPE: ${event.runtimeType}');
          }

          // Filter out duplicate updates (same progress value)
          if (progress == _lastProgress) {
            debugPrint('⛔ FILTERED: Duplicate progress value: ${(progress * 100).toStringAsFixed(0)}%');
            return;
          }

          // Filter out very small changes in progress (less than 1% difference)
          // except for start (0%) and completion (100%)
          if (_lastProgress >= 0 && progress != 0.0 && progress != 1.0) {
            final lastPercent = (_lastProgress * 100).round();
            final currentPercent = (progress * 100).round();
            if (lastPercent == currentPercent) {
              debugPrint('⛔ FILTERED: Trivial progress change: ${_lastProgress.toStringAsFixed(4)} → ${progress.toStringAsFixed(4)}');
              return;
            }
          }

          // Implement debounce - ignore updates that come too quickly
          if (_lastUpdateTime != null) {
            final difference = now.difference(_lastUpdateTime!).inMilliseconds;
            // Skip updates that come within 100ms of each other, except for 0% and 100%
            if (difference < 100 && progress != 0.0 && progress != 1.0) {
              debugPrint('⛔ DEBOUNCED: Update too quick (${difference}ms), progress: ${(progress * 100).toStringAsFixed(0)}%');
              return;
            }
          }

          // Update tracking variables
          _lastProgress = progress;
          _lastUpdateTime = now;

          // Invoke callback
          onProgress(path, progress);
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

      // Conversion is complete, cancel subscription
      await _activeProgressSubscription?.cancel();
      _activeProgressSubscription = null;

      return outputPath;
    } on PlatformException catch (e) {
      // Clean up subscription on error
      await _activeProgressSubscription?.cancel();
      _activeProgressSubscription = null;

      debugPrint('Failed to convert video: ${e.message}');
      return null;
    }
  }
}
