import 'package:flutter/material.dart';
import 'package:flutter_video_converter/flutter_video_converter.dart' as converter;
import 'dart:io';
import 'dart:typed_data';
import 'package:photo_manager/photo_manager.dart';
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
  File? _videoFileConverted;
  bool _isConverting = false;
  String? _convertedVideoPath;
  double _conversionProgress = 0.0;
  VideoPlayerController? _videoController;
  bool _isVideoPlayerInitialized = false;
  bool _isGalleryOpen = false;
  final List<AssetEntity> _videoAssets = [];
  AssetEntity? _asset;
  int _currentPage = 0;
  final int _pageSize = 30;
  bool _hasMoreToLoad = true;

  // Conversion parameters
  converter.VideoQuality _selectedQuality = converter.VideoQuality.medium;
  converter.VideoFormat _selectedFormat = converter.VideoFormat.mp4;

  @override
  void initState() {
    super.initState();
    PhotoManager.clearFileCache();
    converter.FlutterVideoConverter.clearCache();
    _checkPermission();
  }

  Future<void> _checkPermission() async {
    final PermissionState permissionState = await PhotoManager.requestPermissionExtend();
    if (permissionState.isAuth) {
      _loadAssets();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Please grant photo library access to select videos'),
          action: SnackBarAction(
            label: 'Settings',
            onPressed: () async {
              await PhotoManager.openSetting();
            },
          ),
        ),
      );
    }
  }

  Future<void> _loadAssets() async {
    if (!_hasMoreToLoad) return;

    final List<AssetPathEntity> paths = await PhotoManager.getAssetPathList(
      type: RequestType.video,
    );

    if (paths.isEmpty) return;

    final List<AssetEntity> videos = await paths.first.getAssetListPaged(
      page: _currentPage,
      size: _pageSize,
    );

    setState(() {
      _videoAssets.addAll(videos);
      _currentPage++;
      _hasMoreToLoad = videos.length >= _pageSize;
    });
  }

  Future<void> _openGallery() async {
    setState(() {
      _isGalleryOpen = true;
    });

    if (_videoAssets.isEmpty) {
      await _loadAssets();
    }
  }

  Future<void> _selectVideo(AssetEntity asset) async {
    final File? file = await asset.file;
    _asset = asset;
    if (file != null) {
      setState(() {
        _videoFile = file;
        _convertedVideoPath = null;
        _isGalleryOpen = false;
        _disposeVideoPlayer();
      });
    }
  }

  Widget _buildGalleryView() {
    return Column(
      children: [
        AppBar(
          title: const Text('Select a Video'),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () {
              setState(() {
                _isGalleryOpen = false;
              });
            },
          ),
        ),
        Expanded(
          child: _videoAssets.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : GridView.builder(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    crossAxisSpacing: 2,
                    mainAxisSpacing: 2,
                  ),
                  itemCount: _videoAssets.length + (_hasMoreToLoad ? 1 : 0),
                  itemBuilder: (context, index) {
                    if (index == _videoAssets.length) {
                      return GestureDetector(
                        onTap: _loadAssets,
                        child: const Center(
                          child: Icon(Icons.more_horiz, size: 40),
                        ),
                      );
                    }

                    final asset = _videoAssets[index];
                    return GestureDetector(
                      onTap: () => _selectVideo(asset),
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          FutureBuilder<Uint8List?>(
                            future: asset.thumbnailData,
                            builder: (_, snapshot) {
                              if (snapshot.hasData && snapshot.data != null) {
                                return Image.memory(
                                  snapshot.data!,
                                  fit: BoxFit.cover,
                                  width: double.infinity,
                                  height: double.infinity,
                                );
                              }
                              return Container(
                                color: Colors.grey[300],
                                child: const Center(
                                  child: CircularProgressIndicator(),
                                ),
                              );
                            },
                          ),
                          const Icon(
                            Icons.play_circle_outline,
                            color: Colors.white,
                            size: 30,
                          ),
                          Positioned(
                            bottom: 5,
                            right: 5,
                            child: Container(
                              padding: const EdgeInsets.all(2),
                              color: Colors.black54,
                              child: Text(
                                _formatDuration(asset.duration),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  String _formatDuration(int seconds) {
    final Duration duration = Duration(seconds: seconds);
    final String minutes = (duration.inMinutes % 60).toString().padLeft(2, '0');
    final String secs = (duration.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$secs';
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

  String transformVideoPath(String originalPath) {
    // Extract the file name from the path
    String fileName = originalPath.split('/').last;

    // Replace IMG_ with o_IMG_ and change extension to .mp4
    String newFileName = fileName.replaceFirst('IMG_', 'o_IMG_').replaceAll('.MOV', '.mp4');

    // Construct the new path by replacing the original filename
    String newPath = originalPath.substring(0, originalPath.lastIndexOf('/') + 1) + newFileName;

    return newPath;
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
            'Video Quality:',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
        Wrap(
          spacing: 8.0,
          children: [
            ChoiceChip(
              label: const Text('High'),
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
              label: const Text('Medium'),
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
              label: const Text('Low'),
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
            'Video Format:',
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
    print('Converted Photo  manager path: ${_videoFileConverted?.path}');
    print('Converted:Plugin manager path: $_convertedVideoPath');
    print('path: ${_videoFile?.path}');
    print('path1: ${_asset?.id}');
    if (_isGalleryOpen) {
      return Scaffold(
        body: SafeArea(
          child: _buildGalleryView(),
        ),
      );
    }

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
                'Select a video to convert',
                style: TextStyle(fontSize: 18),
              ),
              const SizedBox(height: 20),
              ElevatedButton.icon(
                onPressed: _openGallery,
                icon: const Icon(Icons.video_library),
                label: const Text('Select from Gallery'),
              ),
              const SizedBox(height: 10),
              ElevatedButton.icon(
                onPressed: () async {
                  _videoFileConverted = await _asset?.loadFile(darwinFileType: PMDarwinAVFileType.mp4);
                  setState(() {});
                },
                icon: const Icon(Icons.cleaning_services),
                label: const Text('Clear Cache'),
              ),

              // Conversion settings
              if (_videoFile != null) ...[
                const SizedBox(height: 20),
                const Divider(),
                const Text(
                  'Conversion Settings',
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
                  Text('Converted: ${_convertedVideoPath!}', style: const TextStyle(fontSize: 14, color: Colors.green)),
                  Text('Converted Plugin size: ${(File(_convertedVideoPath!).lengthSync() / (1024 * 1024))} MB', style: const TextStyle(fontSize: 14, color: Colors.green)),
                ],
                if (_videoFileConverted != null)
                  Text('Converted Poto manager size: ${(_videoFileConverted!.lengthSync() / (1024 * 1024))} MB', style: const TextStyle(fontSize: 14, color: Colors.green)),
                if (_videoFileConverted != null) Text('Converted Poto manager path: ${_videoFileConverted!.path}', style: const TextStyle(fontSize: 14, color: Colors.green)),
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
