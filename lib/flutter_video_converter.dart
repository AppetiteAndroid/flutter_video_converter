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

  /// Flag to indicate if a conversion is in progress
  static bool _conversionInProgress = false;

  /// Cache of converted files - maps original path + parameters to converted path
  static final Map<String, String> _conversionCache = {};

  /// Converts a video file to specified format with selected quality.
  ///
  /// The [videoFile] is the source video file to convert.
  /// The [quality] specifies the output video quality (high, medium, low). Defaults to medium.
  /// The [format] specifies the output video format (mp4, mov, webm, avi). Defaults to mp4.
  /// The [onProgress] callback provides progress updates during conversion (path, 0.0 to 1.0).
  /// The [useCache] determines whether to use cached conversions. Defaults to true.
  /// The [customOutputPath] allows specifying an exact output path for the converted video.
  ///
  /// Returns the path to the converted video file, or null if conversion failed.
  static Future<String?> convertVideo(
    File videoFile, {
    VideoQuality quality = VideoQuality.medium,
    VideoFormat format = VideoFormat.mp4,
    Function(String, double)? onProgress,
    bool useCache = true,
    String? customOutputPath,
  }) async {
    try {
      // If customOutputPath is provided, don't use cache
      if (customOutputPath != null) {
        useCache = false;
      }

      // Create a cache key for this conversion
      final String cacheKey = _generateCacheKey(videoFile.path, quality, format);

      // Check if we have this conversion in cache
      if (useCache && _conversionCache.containsKey(cacheKey)) {
        final String cachedPath = _conversionCache[cacheKey]!;

        // Verify the file still exists
        if (File(cachedPath).existsSync()) {
          // Return the cached file path directly, with 100% progress
          if (onProgress != null) {
            onProgress(videoFile.path, 1.0);
          }
          debugPrint('Using cached conversion: $cachedPath');
          return cachedPath;
        } else {
          // File doesn't exist anymore, remove from cache
          _conversionCache.remove(cacheKey);
        }
      }

      // Ensure any previous conversion is cleaned up
      await _activeProgressSubscription?.cancel();
      _activeProgressSubscription = null;
      _conversionInProgress = true;

      // Set up progress listener if callback is provided
      if (onProgress != null) {
        _activeProgressSubscription = _progressChannel.receiveBroadcastStream().listen((dynamic event) {
          // Skip events if we're not actively converting
          if (!_conversionInProgress) return;

          // Process the event data
          String path = videoFile.path;
          double progress = 0.0;

          if (event is Map) {
            // Extract path and progress from the map
            path = event['path'] as String? ?? videoFile.path;
            progress = event['progress'] as double? ?? 0.0;
            debugPrint('Progress update: $path - ${(progress * 100).toStringAsFixed(0)}%');
          } else if (event is double) {
            // Backward compatibility for platforms that only send progress
            progress = event;
            debugPrint('Progress update: ${(progress * 100).toStringAsFixed(0)}%');
          } else {
            return; // Skip unknown event types
          }

          // Validate progress is in valid range
          if (progress < 0.0) progress = 0.0;
          if (progress > 1.0) progress = 1.0;

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
          'customOutputPath': customOutputPath,
        },
      );

      // If conversion was successful and we're not using a custom path, add to cache
      if (outputPath != null && customOutputPath == null) {
        _conversionCache[cacheKey] = outputPath;
      }

      // Mark conversion as complete
      _conversionInProgress = false;

      // Clean up subscription
      await _activeProgressSubscription?.cancel();
      _activeProgressSubscription = null;

      return outputPath;
    } on PlatformException catch (e) {
      // Clean up on error
      _conversionInProgress = false;
      await _activeProgressSubscription?.cancel();
      _activeProgressSubscription = null;

      debugPrint('Failed to convert video: ${e.message}');
      return null;
    }
  }

  /// Deletes all converted files from the cache directory.
  ///
  /// Returns the number of files deleted.
  static Future<int> clearCache() async {
    try {
      final int deletedCount = await _channel.invokeMethod<int>(
            'clearCache',
            {},
          ) ??
          0;

      // Clear the in-memory cache
      _conversionCache.clear();

      return deletedCount;
    } on PlatformException catch (e) {
      debugPrint('Failed to clear cache: ${e.message}');
      return 0;
    }
  }

  /// Deletes a specific converted file from the cache.
  ///
  /// The [videoFile] is the original source video file.
  /// The [quality] and [format] parameters should match those used for conversion.
  ///
  /// Returns true if the file was successfully deleted or did not exist.
  static Future<bool> removeCachedFile(
    File videoFile, {
    VideoQuality quality = VideoQuality.medium,
    VideoFormat format = VideoFormat.mp4,
  }) async {
    final String cacheKey = _generateCacheKey(videoFile.path, quality, format);

    // Check if we have this conversion in cache
    if (_conversionCache.containsKey(cacheKey)) {
      final String cachedPath = _conversionCache[cacheKey]!;

      try {
        // Delete the file if it exists
        final File cachedFile = File(cachedPath);
        if (await cachedFile.exists()) {
          await cachedFile.delete();
        }

        // Remove from cache
        _conversionCache.remove(cacheKey);
        return true;
      } catch (e) {
        debugPrint('Failed to delete cached file: $e');
        return false;
      }
    }

    return true; // File wasn't in cache, so consider it "removed"
  }

  /// Gets the list of all cached video paths.
  ///
  /// Returns a list of file paths for all cached converted videos.
  static Future<List<String>> getCachedFiles() async {
    try {
      final List<dynamic>? cachedFiles = await _channel.invokeMethod<List<dynamic>>(
        'getCachedFiles',
        {},
      );

      return cachedFiles?.map((path) => path.toString()).toList() ?? [];
    } on PlatformException catch (e) {
      debugPrint('Failed to get cached files: ${e.message}');
      return [];
    }
  }

  /// Generates a unique cache key for a conversion.
  static String _generateCacheKey(String filePath, VideoQuality quality, VideoFormat format) {
    return '$filePath|${quality.value}|${format.value}';
  }

  /// Converts a video file to MP4 format.
  ///
  /// The [videoFile] is the source video file to convert.
  /// The [onProgress] callback provides progress updates during conversion.
  /// The [useCache] determines whether to use cached conversions. Defaults to true.
  /// The [customOutputPath] allows specifying an exact output path for the converted video.
  ///
  /// Returns the path to the converted MP4 video file, or null if conversion failed.
  static Future<String?> convertToMp4(
    File videoFile, {
    Function(String, double)? onProgress,
    bool useCache = true,
    String? customOutputPath,
  }) async {
    return convertVideo(
      videoFile,
      quality: VideoQuality.high,
      format: VideoFormat.mp4,
      onProgress: onProgress,
      useCache: useCache,
      customOutputPath: customOutputPath,
    );
  }
}
