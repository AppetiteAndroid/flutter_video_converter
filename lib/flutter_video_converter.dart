import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'flutter_video_converter_platform_interface.dart';

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
  /// The [onProgress] callback provides progress updates during conversion (0.0 to 1.0).
  ///
  /// Returns the path to the converted video file, or null if conversion failed.
  static Future<String?> convertVideo(
    File videoFile, {
    VideoQuality quality = VideoQuality.medium,
    VideoFormat format = VideoFormat.mp4,
    Function(double)? onProgress,
  }) async {
    try {
      // Set up progress listener if callback is provided
      if (onProgress != null) {
        _progressChannel.receiveBroadcastStream().listen((dynamic event) {
          if (event is double) {
            onProgress(event);
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

  /// Converts multiple video files to specified format with selected quality, running conversions in parallel.
  ///
  /// The [videoFiles] is a list of source video files to convert.
  /// The [quality] specifies the output video quality (high, medium, low). Defaults to medium.
  /// The [format] specifies the output video format (mp4, mov, webm, avi). Defaults to mp4.
  /// The [onProgress] callback provides aggregated progress updates (0.0 to 1.0).
  ///
  /// Returns a list of paths to all successfully converted video files.
  static Future<List<String>> convertMultipleVideos(
    List<File> videoFiles, {
    VideoQuality quality = VideoQuality.medium,
    VideoFormat format = VideoFormat.mp4,
    Function(double)? onProgress,
  }) async {
    if (videoFiles.isEmpty) {
      return [];
    }

    final int totalFiles = videoFiles.length;
    final Map<int, double> fileProgresses = {};

    // Initialize progress for each file
    for (int i = 0; i < totalFiles; i++) {
      fileProgresses[i] = 0.0;
    }

    // Function to update total progress
    void updateTotalProgress(int fileIndex, double progress) {
      if (onProgress != null) {
        fileProgresses[fileIndex] = progress;
        // Calculate average progress across all files
        double totalProgress = fileProgresses.values.reduce((a, b) => a + b) / totalFiles;
        onProgress(totalProgress);
      }
    }

    // Create futures for each conversion to run in parallel
    List<Future<String?>> conversions = [];

    // Start all conversions in parallel with separate progress handlers
    for (int i = 0; i < videoFiles.length; i++) {
      final int index = i;
      conversions.add(
        convertVideo(
          videoFiles[i],
          quality: quality,
          format: format,
          onProgress: (progress) => updateTotalProgress(index, progress),
        ),
      );
    }

    // Wait for all conversions to complete
    List<String?> results = await Future.wait(conversions);

    // Filter out any null results (failed conversions)
    List<String> outputPaths = results.where((path) => path != null).map((path) => path!).toList();

    // Ensure 100% progress at the end
    if (onProgress != null) {
      onProgress(1.0);
    }

    return outputPaths;
  }

  /// Сохранена для обратной совместимости
  /// @deprecated Используйте convertVideo вместо convertToMp4
  static Future<String?> convertToMp4(File videoFile, {Function(double)? onProgress}) async {
    return convertVideo(videoFile, format: VideoFormat.mp4, onProgress: onProgress);
  }

  /// Сохранена для обратной совместимости
  /// @deprecated Используйте convertMultipleVideos вместо convertMultipleToMp4
  static Future<List<String>> convertMultipleToMp4(List<File> videoFiles, {Function(double)? onProgress}) async {
    return convertMultipleVideos(videoFiles, format: VideoFormat.mp4, onProgress: onProgress);
  }
}
