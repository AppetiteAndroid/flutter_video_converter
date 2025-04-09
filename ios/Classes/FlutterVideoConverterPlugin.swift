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
      
      convertVideoToMP4(videoPath: videoPath) { outputPath, error in
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
      
      // Ignore quality and format parameters on iOS - always convert to MP4
      print("Note: iOS always converts to MP4 format regardless of parameters")
      
      convertVideoToMP4(videoPath: videoPath) { outputPath, error in
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
      
      convertMultipleToMP4(videoPaths: videoPaths) { outputPaths in
        result(outputPaths)
      }
      
    default:
      result(FlutterMethodNotImplemented)
    }
  }
  
  private func convertMultipleToMP4(videoPaths: [String], completion: @escaping ([String]) -> Void) {
    var outputPaths = [String]()
    let totalVideos = videoPaths.count
    let dispatchGroup = DispatchGroup()
    
    for (index, videoPath) in videoPaths.enumerated() {
      dispatchGroup.enter()
      
      let startProgress = Double(index) / Double(totalVideos)
      let endProgress = Double(index + 1) / Double(totalVideos)
      
      convertVideoToMP4WithScaledProgress(
        videoPath: videoPath,
        startProgress: startProgress,
        endProgress: endProgress
      ) { outputPath, error in
        if let outputPath = outputPath {
          outputPaths.append(outputPath)
        }
        dispatchGroup.leave()
      }
    }
    
    dispatchGroup.notify(queue: .main) {
      // Ensure 100% progress is sent at the end
      self.progressEventSink?(1.0)
      completion(outputPaths)
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
  
  private func convertVideoToMP4(videoPath: String, completion: @escaping (String?, Error?) -> Void) {
    convertVideoToMP4WithScaledProgress(
      videoPath: videoPath, 
      startProgress: 0.0, 
      endProgress: 1.0, 
      completion: completion
    )
  }
  
  private func convertVideoToMP4WithScaledProgress(
    videoPath: String,
    startProgress: Double = 0.0,
    endProgress: Double = 1.0,
    completion: @escaping (String?, Error?) -> Void
  ) {
    let sourceURL = URL(fileURLWithPath: videoPath)
    
    // Create output URL in cache directory with unique name
    let hashString = videoPath
    let hash = abs(hashString.hash)
    let outputFileName = "converted_\(hash).mp4"
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
    
    // Setup asset
    let asset = AVAsset(url: sourceURL)
    
    // Check if a more compatible preset might work better
    let compatiblePresets = AVAssetExportSession.exportPresets(compatibleWith: asset)
    let preferredPresets = [
      AVAssetExportPresetPassthrough,  // Try passthrough first to maintain quality
      AVAssetExportPresetHighestQuality,
      AVAssetExportPresetMediumQuality,
      AVAssetExportPreset1920x1080,    // Full HD
      AVAssetExportPreset1280x720      // HD
    ]
    
    // Find the highest quality compatible preset
    var selectedPreset = AVAssetExportPresetMediumQuality // Default fallback
    for preset in preferredPresets {
      if compatiblePresets.contains(preset) {
        selectedPreset = preset
        print("Using preset: \(preset)")
        break
      }
    }
    
    guard let exportSession = AVAssetExportSession(asset: asset, presetName: selectedPreset) else {
      completion(nil, NSError(domain: "VideoConverter", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create export session"]))
      return
    }
    
    // Configure export session
    exportSession.outputURL = outputURL
    exportSession.outputFileType = .mp4
    exportSession.shouldOptimizeForNetworkUse = true
    
    // Calculate the progress range for this conversion
    let progressRange = endProgress - startProgress
    
    // Setup progress monitoring
    let progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
      if exportSession.status == .exporting {
        // Scale the progress to fit in our range
        let scaledProgress = startProgress + (Double(exportSession.progress) * progressRange)
        DispatchQueue.main.async {
          self?.sendProgress(path: videoPath, progress: scaledProgress)
        }
      } else if exportSession.status != .waiting {
        timer.invalidate()
      }
    }
    
    // Export file
    exportSession.exportAsynchronously { [weak self] in
      progressTimer.invalidate()
      
      // Ensure final progress is sent at completion for this segment
      if exportSession.status == .completed {
        DispatchQueue.main.async {
          self?.sendProgress(path: videoPath, progress: endProgress)
        }
      }
      
      switch exportSession.status {
      case .completed:
        completion(outputURL.path, nil)
      case .failed:
        print("Export failed: \(String(describing: exportSession.error?.localizedDescription))")
        print("Error details: \(String(describing: exportSession.error))")
        completion(nil, exportSession.error)
      case .cancelled:
        completion(nil, NSError(domain: "VideoConverter", code: -2, userInfo: [NSLocalizedDescriptionKey: "Export cancelled"]))
      default:
        completion(nil, NSError(domain: "VideoConverter", code: -3, userInfo: [NSLocalizedDescriptionKey: "Unknown error"]))
      }
    }
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
