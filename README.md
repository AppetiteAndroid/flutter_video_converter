# Flutter Video Converter

A Flutter plugin for converting videos to MP4 format with progress tracking, parallel conversion support, and optimized file size.

## Features

- Convert videos to MP4 format on both Android and iOS
- Track conversion progress with real-time updates
- Convert multiple videos in parallel with aggregated progress
- Automatically optimize output file size with bitrate adjustment
- Simple, easy-to-use API

## Installation

Add this package to your `pubspec.yaml`:

```yaml
dependencies:
  flutter_video_converter: ^0.1.0
```

Or add it directly from GitHub:

```yaml
dependencies:
  flutter_video_converter:
    git:
      url: https://github.com/yourusername/flutter_video_converter.git
      ref: main  # or a specific branch/tag/commit
```

## Usage

### Basic Conversion

Convert a single video file to MP4 format:

```dart
import 'dart:io';
import 'package:flutter_video_converter/flutter_video_converter.dart';

// Convert a single video file
File videoFile = File('path/to/video.mov');
String? outputPath = await FlutterVideoConverter.convertToMp4(
  videoFile,
  onProgress: (progress) {
    // Update UI with progress (0.0 to 1.0)
    print('Conversion progress: ${(progress * 100).toStringAsFixed(1)}%');
  },
);

if (outputPath != null) {
  print('Video converted successfully: $outputPath');
} else {
  print('Conversion failed');
}
```

### Convert Multiple Videos in Parallel

Process multiple video files simultaneously with aggregated progress:

```dart
import 'dart:io';
import 'package:flutter_video_converter/flutter_video_converter.dart';

// Convert multiple video files in parallel
List<File> videoFiles = [
  File('path/to/video1.mov'),
  File('path/to/video2.mp4'),
  File('path/to/video3.avi'),
];

List<String> outputPaths = await FlutterVideoConverter.convertMultipleToMp4(
  videoFiles,
  onProgress: (progress) {
    // Update UI with aggregated progress (0.0 to 1.0)
    print('Total conversion progress: ${(progress * 100).toStringAsFixed(1)}%');
  },
);

print('Successfully converted ${outputPaths.length} of ${videoFiles.length} videos');
```

## Platform Specifics

### Android

- Uses `MediaMuxer` and `MediaExtractor` for video conversion
- Reduces video bitrate to 60% of the original to save space
- Reduces audio bitrate to 80% of the original
- Uses a default bitrate of 1.5Mbps for video if original bitrate is unknown

### iOS

- Uses `AVAssetExportSession` with `AVAssetExportPresetMediumQuality` for optimal file size
- Automatically optimizes for network use

## Example App

Check out the example app in the `example` directory for a complete implementation.

## License

This project is licensed under the MIT License - see the LICENSE file for details.

