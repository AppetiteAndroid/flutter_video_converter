import 'package:flutter/material.dart';
import 'package:flutter_video_converter/flutter_video_converter.dart' as converter;
import 'dart:io';
import 'package:image_picker/image_picker.dart';
import 'package:video_player/video_player.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Video Converter Demo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const VideoConverterPage(),
    );
  }
}

class VideoConverterPage extends StatefulWidget {
  const VideoConverterPage({super.key});

  @override
  State<VideoConverterPage> createState() => _VideoConverterPageState();
}

class _VideoConverterPageState extends State<VideoConverterPage> {
  File? _videoFile;
  bool _isConverting = false;
  String? _convertedVideoPath;
  double _conversionProgress = 0.0;
  VideoPlayerController? _videoController;
  bool _isVideoPlayerInitialized = false;

  // Новые параметры для настройки конвертации
  converter.VideoQuality _selectedQuality = converter.VideoQuality.medium;
  converter.VideoFormat _selectedFormat = converter.VideoFormat.mp4;

  Future<void> _pickVideo() async {
    final picker = ImagePicker();
    final XFile? pickedVideo = await picker.pickVideo(source: ImageSource.gallery);

    if (pickedVideo != null) {
      setState(() {
        _videoFile = File(pickedVideo.path);
        _convertedVideoPath = null;
        _disposeVideoPlayer();
      });
    }
  }

  Future<void> _convertToMp4() async {
    if (_videoFile == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select a video first')),
      );
      return;
    }

    try {
      setState(() {
        _isConverting = true;
        _conversionProgress = 0.0;
      });

      _convertedVideoPath = await converter.FlutterVideoConverter.convertVideo(
        _videoFile!,
        quality: _selectedQuality,
        format: _selectedFormat,
        onProgress: (path, progress) {
          setState(() {
            _conversionProgress = progress;
            // You can use the input path if needed
            print('Converting: $path - Progress: ${(progress * 100).toStringAsFixed(0)}%');
          });
        },
      );

      setState(() {
        _isConverting = false;
      });

      if (_convertedVideoPath != null) {
        _initializeVideoPlayer(_convertedVideoPath!);

        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Video successfully converted to ${_selectedFormat.value.toUpperCase()}')),
        );
      } else {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to convert video')),
        );
      }
    } catch (e) {
      setState(() {
        _isConverting = false;
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: ${e.toString()}')),
      );
    }
  }

  void _initializeVideoPlayer(String videoPath) {
    _disposeVideoPlayer();

    _videoController = VideoPlayerController.file(File(videoPath))
      ..initialize().then((_) {
        setState(() {
          _isVideoPlayerInitialized = true;
        });
      });
  }

  void _disposeVideoPlayer() {
    if (_videoController != null) {
      _videoController!.dispose();
      _isVideoPlayerInitialized = false;
    }
  }

  @override
  void dispose() {
    _disposeVideoPlayer();
    super.dispose();
  }

  Widget _buildQualitySelector() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(left: 8.0, top: 16.0, bottom: 8.0),
          child: Text(
            'Качество видео:',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
        Wrap(
          spacing: 8.0,
          children: [
            ChoiceChip(
              label: const Text('Высокое'),
              selected: _selectedQuality == converter.VideoQuality.high,
              onSelected: (selected) {
                if (selected) {
                  setState(() {
                    _selectedQuality = converter.VideoQuality.high;
                  });
                }
              },
            ),
            ChoiceChip(
              label: const Text('Среднее'),
              selected: _selectedQuality == converter.VideoQuality.medium,
              onSelected: (selected) {
                if (selected) {
                  setState(() {
                    _selectedQuality = converter.VideoQuality.medium;
                  });
                }
              },
            ),
            ChoiceChip(
              label: const Text('Низкое'),
              selected: _selectedQuality == converter.VideoQuality.low,
              onSelected: (selected) {
                if (selected) {
                  setState(() {
                    _selectedQuality = converter.VideoQuality.low;
                  });
                }
              },
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildFormatSelector() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(left: 8.0, top: 16.0, bottom: 8.0),
          child: Text(
            'Формат видео:',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
        Wrap(
          spacing: 8.0,
          children: [
            ChoiceChip(
              label: const Text('MP4'),
              selected: _selectedFormat == converter.VideoFormat.mp4,
              onSelected: (selected) {
                if (selected) {
                  setState(() {
                    _selectedFormat = converter.VideoFormat.mp4;
                  });
                }
              },
            ),
            ChoiceChip(
              label: const Text('MOV'),
              selected: _selectedFormat == converter.VideoFormat.mov,
              onSelected: (selected) {
                if (selected) {
                  setState(() {
                    _selectedFormat = converter.VideoFormat.mov;
                  });
                }
              },
            ),
            ChoiceChip(
              label: const Text('WebM'),
              selected: _selectedFormat == converter.VideoFormat.webm,
              onSelected: (selected) {
                if (selected) {
                  setState(() {
                    _selectedFormat = converter.VideoFormat.webm;
                  });
                }
              },
            ),
            ChoiceChip(
              label: const Text('AVI'),
              selected: _selectedFormat == converter.VideoFormat.avi,
              onSelected: (selected) {
                if (selected) {
                  setState(() {
                    _selectedFormat = converter.VideoFormat.avi;
                  });
                }
              },
            ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: const Text('Video Converter Demo'),
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              const Text(
                'Select videos to convert',
                style: TextStyle(fontSize: 18),
              ),
              const SizedBox(height: 20),
              ElevatedButton.icon(
                onPressed: _pickVideo,
                icon: const Icon(Icons.attach_file),
                label: const Text('Select Video'),
              ),

              // Настройки конвертации
              if (_videoFile != null) ...[
                const SizedBox(height: 20),
                const Divider(),
                const Text(
                  'Параметры конвертации',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                _buildQualitySelector(),
                _buildFormatSelector(),
                const Divider(),
              ],

              if (_videoFile != null) ...[
                const SizedBox(height: 20),
                Text('Selected: ${_videoFile!.path.split('/').last}', style: const TextStyle(fontSize: 14)),
                Text('Size: ${(_videoFile!.lengthSync() / (1024 * 1024)).toStringAsFixed(2)} MB', style: const TextStyle(fontSize: 14)),
                const SizedBox(height: 20),
                _isConverting
                    ? Column(
                        children: [
                          Stack(
                            alignment: Alignment.center,
                            children: [
                              SizedBox(
                                width: 250,
                                child: LinearProgressIndicator(
                                  value: _conversionProgress,
                                  backgroundColor: Colors.grey[300],
                                  valueColor: AlwaysStoppedAnimation<Color>(Theme.of(context).primaryColor),
                                  minHeight: 10,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              ),
                              Text(
                                '${(_conversionProgress * 100).toStringAsFixed(0)}%',
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Converting to ${_selectedFormat.value.toUpperCase()}...',
                            style: const TextStyle(fontSize: 14),
                          ),
                        ],
                      )
                    : ElevatedButton.icon(
                        onPressed: _convertToMp4,
                        icon: const Icon(Icons.sync),
                        label: Text('Convert to ${_selectedFormat.value.toUpperCase()}'),
                      ),
                if (_convertedVideoPath != null) ...[
                  const SizedBox(height: 10),
                  Text('Converted: ${_convertedVideoPath!.split('/').last}', style: const TextStyle(fontSize: 14, color: Colors.green)),
                  Text('Converted size: ${(File(_convertedVideoPath!).lengthSync() / (1024 * 1024)).toStringAsFixed(2)} MB', style: const TextStyle(fontSize: 14, color: Colors.green)),
                ],
              ],

              // Video player section
              if (_isVideoPlayerInitialized && _videoController != null) ...[
                const SizedBox(height: 20),
                const Divider(),
                const SizedBox(height: 10),
                const Text(
                  'Preview Converted Video',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 10),
                AspectRatio(
                  aspectRatio: _videoController!.value.aspectRatio,
                  child: VideoPlayer(_videoController!),
                ),
                VideoProgressIndicator(
                  _videoController!,
                  allowScrubbing: true,
                  padding: const EdgeInsets.symmetric(vertical: 8.0),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      icon: Icon(
                        _videoController!.value.isPlaying ? Icons.pause : Icons.play_arrow,
                      ),
                      onPressed: () {
                        setState(() {
                          _videoController!.value.isPlaying ? _videoController!.pause() : _videoController!.play();
                        });
                      },
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
