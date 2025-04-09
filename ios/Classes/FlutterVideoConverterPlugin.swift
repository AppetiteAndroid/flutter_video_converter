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
      // We'll use preset instead of trying to configure custom settings
      // as AVAssetExportSession doesn't support direct videoSettings configuration
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
      
      // Get video duration for progress tracking
      let durationInSeconds = CMTimeGetSeconds(asset.duration)
      
      // Set up initial progress
      sendProgress(path: videoPath, progress: 0.0)
      
      // Create a timer to monitor progress
      var progressTimer: Timer?
      progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak exportSession] timer in
        guard let session = exportSession else {
          timer.invalidate()
          return
        }
        
        // Get actual progress from export session
        let progress = Double(session.progress)
        sendProgress(path: videoPath, progress: progress)
        
        // If export is complete or failed, invalidate timer
        if session.status == .completed || session.status == .failed || session.status == .cancelled {
          timer.invalidate()
        }
      }
      
      // Start the export
      exportSession.exportAsynchronously { [weak progressTimer] in
        // Ensure timer is stopped
        progressTimer?.invalidate()
        
        DispatchQueue.main.async {
          switch exportSession.status {
          case .completed:
            sendProgress(path: videoPath, progress: 1.0)
            completion(outputURL.path, nil)
          case .failed:
            let error = exportSession.error ?? NSError(domain: "VideoConverter", code: -1, userInfo: [NSLocalizedDescriptionKey: "Export failed"])
            sendProgress(path: videoPath, progress: 1.0)
            completion(nil, error)
          case .cancelled:
            sendProgress(path: videoPath, progress: 1.0)
            completion(nil, NSError(domain: "VideoConverter", code: -2, userInfo: [NSLocalizedDescriptionKey: "Export cancelled"]))
          default:
            sendProgress(path: videoPath, progress: 1.0)
            completion(nil, NSError(domain: "VideoConverter", code: -3, userInfo: [NSLocalizedDescriptionKey: "Export completed with unknown status"]))
          }
        }
      }
    } else {
      // Failed to create export session
      let error = NSError(domain: "VideoConverter", code: -4, userInfo: [NSLocalizedDescriptionKey: "Failed to create export session"])
      sendProgress(path: videoPath, progress: 1.0)
      completion(nil, error)
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
