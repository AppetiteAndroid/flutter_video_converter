import Flutter
import UIKit
import AVFoundation

@objc public class FlutterVideoConverterPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private var progressEventSink: FlutterEventSink?
  
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "com.example.flutter_video_converter/converter", binaryMessenger: registrar.messenger())
    let progressChannel = FlutterEventChannel(name: "com.example.flutter_video_converter/converter/progress", binaryMessenger: registrar.messenger())
    
    let instance = FlutterVideoConverterPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
    progressChannel.setStreamHandler(instance)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "convertToMp4":
      guard let args = call.arguments as? [String: Any],
            let videoPath = args["videoPath"] as? String else {
        result(FlutterError(code: "INVALID_ARGS", message: "Invalid arguments", details: nil))
        return
      }
      
      // Backwards compatibility - uses mp4 format with medium quality
      convertVideo(
        videoPath: videoPath, 
        quality: "medium", 
        format: "mp4"
      ) { outputPath, error in
        if let error = error {
          result(FlutterError(code: "CONVERSION_ERROR", message: error.localizedDescription, details: nil))
        } else if let outputPath = outputPath {
          result(outputPath)
        } else {
          result(nil)
        }
      }
      
    case "convertVideo":
      guard let args = call.arguments as? [String: Any],
            let videoPath = args["videoPath"] as? String else {
        result(FlutterError(code: "INVALID_ARGS", message: "Invalid arguments", details: nil))
        return
      }
      
      let quality = args["quality"] as? String ?? "medium"
      let format = args["format"] as? String ?? "mp4"
      
      convertVideo(
        videoPath: videoPath,
        quality: quality,
        format: format
      ) { outputPath, error in
        if let error = error {
          result(FlutterError(code: "CONVERSION_ERROR", message: error.localizedDescription, details: nil))
        } else if let outputPath = outputPath {
          result(outputPath)
        } else {
          result(nil)
        }
      }
    
    case "clearCache":
      do {
        let count = try clearCache()
        result(count)
      } catch {
        result(FlutterError(code: "CACHE_ERROR", message: error.localizedDescription, details: nil))
      }
      
    case "getCachedFiles":
      do {
        let cachedFiles = try getCachedFiles()
        result(cachedFiles)
      } catch {
        result(FlutterError(code: "CACHE_ERROR", message: error.localizedDescription, details: nil))
      }
      
    case "convertMultipleToMp4":
      guard let args = call.arguments as? [String: Any],
            let videoPaths = args["videoPaths"] as? [String] else {
        result(FlutterError(code: "INVALID_ARGS", message: "Invalid arguments", details: nil))
        return
      }
      
      convertMultipleVideosToMP4(videoPaths: videoPaths) { outputPaths in
        result(outputPaths)
      }
      
    default:
      result(FlutterMethodNotImplemented)
    }
  }
  
  private func convertMultipleVideosToMP4(videoPaths: [String], completion: @escaping ([String]) -> Void) {
    let totalVideos = videoPaths.count
    var convertedPaths: [String] = []
    var completedCount = 0
    
    for (index, videoPath) in videoPaths.enumerated() {
      let startProgress = Double(index) / Double(totalVideos)
      let endProgress = Double(index + 1) / Double(totalVideos)
      
      convertVideoToMP4(
        videoPath: videoPath,
        progressRange: (startProgress, endProgress)
      ) { outputPath, error in
        DispatchQueue.main.async {
          completedCount += 1
          
          if let outputPath = outputPath {
            convertedPaths.append(outputPath)
          }
          
          // If this is the last video, complete the process
          if completedCount == totalVideos {
            completion(convertedPaths)
          }
        }
      }
    }
    
    // If there are no videos to convert, return an empty array
    if videoPaths.isEmpty {
      completion([])
    }
  }
  
  // Helper method to send progress with file path
  private func sendProgress(path: String, progress: Double) {
    let progressData: [String: Any] = [
      "path": path,
      "progress": progress
    ]
    progressEventSink?(progressData)
  }
  
  private func convertVideo(
    videoPath: String,
    quality: String,
    format: String,
    completion: @escaping (String?, Error?) -> Void
  ) {
    let sourceURL = URL(fileURLWithPath: videoPath)
    
    // Determine quality preset and compression settings
    let preset: String
    var compressionSettings: [String: Any]? = nil
    
    // Get asset to determine video dimensions for appropriate bitrate
    let asset = AVAsset(url: sourceURL)
    
    // Determine appropriate bitrate based on quality setting
    let videoBitrate: Int
    switch quality {
    case "high":
      preset = AVAssetExportPresetHighestQuality
      videoBitrate = 8000000  // 8 Mbps for high quality
    case "medium":
      preset = AVAssetExportPresetMediumQuality
      videoBitrate = 2000000  // 2 Mbps for medium quality
    case "low":
      preset = AVAssetExportPresetLowQuality
      videoBitrate = 750000   // 750 Kbps for low quality
    default:
      preset = AVAssetExportPresetMediumQuality
      videoBitrate = 2000000  // Default to medium
    }
    
    // Set video compression settings if format supports it
    if format == "mp4" || format == "mov" {
      compressionSettings = [
        AVVideoAverageBitRateKey: videoBitrate,
        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
      ]
    }
    
    // Determine file type
    let fileType: AVFileType
    let fileExtension: String
    switch format {
    case "mp4":
      fileType = .mp4
      fileExtension = "mp4"
    case "mov":
      fileType = .mov
      fileExtension = "mov"
    case "webm", "avi":
      // WebM and AVI not directly supported on iOS, use MP4
      fileType = .mp4
      fileExtension = "mp4"
    default:
      fileType = .mp4
      fileExtension = "mp4"
    }
    
    // Create output URL in cache directory with unique name based on input params
    let hashString = "\(videoPath)|\(quality)|\(format)"
    let hash = abs(hashString.hash)
    let outputFileName = "converted_\(hash).\(fileExtension)"
    let cacheDirectory = getCacheDirectory()
    let outputURL = cacheDirectory.appendingPathComponent(outputFileName)
    
    // Check if file already exists and is not empty
    if FileManager.default.fileExists(atPath: outputURL.path) {
      do {
        let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        if let fileSize = attributes[.size] as? NSNumber, fileSize.intValue > 0 {
          // File exists and is not empty, return it directly
          sendProgress(path: videoPath, progress: 1.0)
          completion(outputURL.path, nil)
          return
        }
      } catch {
        // Continue with conversion if we can't get file attributes
        print("Failed to check existing file: \(error.localizedDescription)")
      }
    }
    
    // Try to use AVAssetExportSession with explicit compression settings if possible
    if let exportSession = AVAssetExportSession(asset: asset, presetName: preset) {
      // Configure export session
      exportSession.outputURL = outputURL
      exportSession.outputFileType = fileType
      exportSession.shouldOptimizeForNetworkUse = true
      
      // Apply custom compression settings when available
      if let compressionSettings = compressionSettings {
        // Only supported on certain iOS versions
        if #available(iOS 11.0, *) {
          // Create video settings dictionary
          var videoSettings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.h264]
          
          // Add compression settings
          videoSettings[AVVideoCompressionPropertiesKey] = compressionSettings
          
          // Use different approach based on format
          if fileType == .mp4 || fileType == .mov {
            if let videoTrack = asset.tracks(withMediaType: .video).first {
              // Get natural dimensions
              let naturalSize = videoTrack.naturalSize
              
              // Set size settings
              videoSettings[AVVideoWidthKey] = naturalSize.width
              videoSettings[AVVideoHeightKey] = naturalSize.height
              
              // Try to set video settings - this may fail silently for some export presets
              do {
                try exportSession.setValue(videoSettings, forKey: "videoSettings")
              } catch {
                print("Warning: Unable to set custom video settings: \(error.localizedDescription)")
                // Continue with default preset settings
              }
            }
          }
        }
      }

      // Send initial progress
      sendProgress(path: videoPath, progress: 0.0)
      
      // Get video duration to estimate progress
      let durationInSeconds = CMTimeGetSeconds(asset.duration)
      
      // Calculate estimated total time based on video duration and quality
      // Higher quality takes longer to process
      let estimatedFactor: Double
      switch quality {
      case "high":
        estimatedFactor = 0.3 // 30% of video duration
      case "medium":
        estimatedFactor = 0.2 // 20% of video duration
      case "low":
        estimatedFactor = 0.15 // 15% of video duration
      default:
        estimatedFactor = 0.2
      }
      
      let estimatedDurationSeconds = max(durationInSeconds * estimatedFactor, 2.0) // At least 2 seconds
      
      // Create our own progress timer to avoid unreliable progress from AVAssetExportSession
      let startTime = Date()
      var lastReportedProgress = 0.0
      
      let progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
        // Calculate progress based on elapsed time compared to estimated duration
        let elapsedSeconds = Date().timeIntervalSince(startTime)
        let progress = min(0.99, elapsedSeconds / estimatedDurationSeconds)
        
        // Only send updates if progress increased by at least 1%
        if progress - lastReportedProgress >= 0.01 {
          lastReportedProgress = progress
          DispatchQueue.main.async {
            self?.sendProgress(path: videoPath, progress: progress)
          }
        }
        
        // Check export session status
        if exportSession.status != .exporting && exportSession.status != .waiting {
          timer.invalidate()
        }
      }
      
      // Export file
      exportSession.exportAsynchronously {
        progressTimer.invalidate()
        
        // Send final progress update
        DispatchQueue.main.async { [weak self] in
          if exportSession.status == .completed {
            self?.sendProgress(path: videoPath, progress: 1.0)
          }
        }
        
        switch exportSession.status {
        case .completed:
          // Log file size for debugging
          do {
            if let fileSize = try FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber {
              print("Converted video size (\(quality) quality): \(fileSize.intValue / 1024 / 1024) MB")
            }
          } catch {
            print("Failed to get file size: \(error)")
          }
          
          // Wait a moment before returning the result
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            completion(outputURL.path, nil)
          }
        case .failed:
          self.sendProgress(path: videoPath, progress: 1.0) // Ensure final progress even on error
          print("Export failed with error: \(exportSession.error?.localizedDescription ?? "Unknown error")")
          completion(nil, exportSession.error)
        case .cancelled:
          self.sendProgress(path: videoPath, progress: 1.0) // Ensure final progress even on error
          completion(nil, NSError(domain: "VideoConverter", code: -2, userInfo: [NSLocalizedDescriptionKey: "Export cancelled"]))
        default:
          self.sendProgress(path: videoPath, progress: 1.0) // Ensure final progress even on error
          completion(nil, NSError(domain: "VideoConverter", code: -3, userInfo: [NSLocalizedDescriptionKey: "Unknown error"]))
        }
      }
    } else {
      completion(nil, NSError(domain: "VideoConverter", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create export session"]))
    }
  }
  
  private func convertVideoToMP4(
    videoPath: String,
    progressRange: (start: Double, end: Double)? = nil,
    completion: @escaping (String?, Error?) -> Void
  ) {
    // Используем обновленный метод с параметрами по умолчанию
    convertVideo(
      videoPath: videoPath,
      quality: "medium",
      format: "mp4",
      completion: completion
    )
  }
  
  // MARK: - FlutterStreamHandler
  
  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    progressEventSink = events
    return nil
  }
  
  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    progressEventSink = nil
    return nil
  }
  
  // MARK: - Cache Management
  
  /// Gets the cache directory for converted videos
  private func getCacheDirectory() -> URL {
    // Use the app's cache directory instead of the temporary directory
    let cacheBaseDir: URL
    if let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
      cacheBaseDir = cachesDirectory
    } else {
      // Fall back to temporary directory if caches directory is not available
      cacheBaseDir = FileManager.default.temporaryDirectory
    }
    
    let cacheDirectory = cacheBaseDir.appendingPathComponent("converted_videos")
    
    // Create directory if it doesn't exist
    if !FileManager.default.fileExists(atPath: cacheDirectory.path) {
      try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }
    
    return cacheDirectory
  }
  
  /// Clears all files from the cache directory
  private func clearCache() throws -> Int {
    let cacheDirectory = getCacheDirectory()
    let fileManager = FileManager.default
    
    // Get all files in the directory
    let fileURLs = try fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)
    
    // Delete each file
    var deletedCount = 0
    for fileURL in fileURLs {
      try fileManager.removeItem(at: fileURL)
      deletedCount += 1
    }
    
    return deletedCount
  }
  
  /// Gets a list of all file paths in the cache directory
  private func getCachedFiles() throws -> [String] {
    let cacheDirectory = getCacheDirectory()
    let fileManager = FileManager.default
    
    // If directory doesn't exist, return empty array
    if !fileManager.fileExists(atPath: cacheDirectory.path) {
      return []
    }
    
    // Get all files in the directory
    let fileURLs = try fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)
    
    // Return file paths
    return fileURLs.map { $0.path }
  }
}
