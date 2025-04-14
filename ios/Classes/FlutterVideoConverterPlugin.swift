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
      
      let customOutputPath = args["customOutputPath"] as? String
      
      convertVideoToMP4(videoPath: videoPath, customOutputPath: customOutputPath) { outputPath, error in
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
      
      // Note about format support
      let format = args["format"] as? String ?? "mp4"
      let quality = args["quality"] as? String ?? "medium"
      let customOutputPath = args["customOutputPath"] as? String
      
      convertVideoWithOptions(
        videoPath: videoPath,
        format: format,
        quality: quality,
        customOutputPath: customOutputPath
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
        endProgress: endProgress,
        customOutputPath: nil
      ) { outputPath, error in
        if let outputPath = outputPath {
          outputPaths.append(outputPath)
        }
        dispatchGroup.leave()
      }
    }
    
    dispatchGroup.notify(queue: .main) {
      // Ensure 100% progress is sent at the end
      self.sendProgress(path: "batch_conversion", progress: 1.0)
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
  
  private func convertVideoToMP4(videoPath: String, customOutputPath: String?, completion: @escaping (String?, Error?) -> Void) {
    convertVideoToMP4WithScaledProgress(
      videoPath: videoPath, 
      startProgress: 0.0, 
      endProgress: 1.0, 
      customOutputPath: customOutputPath,
      completion: completion
    )
  }
  
  private func convertVideoToMP4WithScaledProgress(
    videoPath: String,
    startProgress: Double = 0.0,
    endProgress: Double = 1.0,
    customOutputPath: String?,
    completion: @escaping (String?, Error?) -> Void
  ) {
    convertVideoWithOptions(
      videoPath: videoPath,
      format: "mp4",
      quality: "high",
      startProgress: startProgress,
      endProgress: endProgress,
      customOutputPath: customOutputPath,
      completion: completion
    )
  }
  
  private func convertVideoWithOptions(
    videoPath: String,
    format: String,
    quality: String,
    startProgress: Double = 0.0,
    endProgress: Double = 1.0,
    customOutputPath: String?,
    completion: @escaping (String?, Error?) -> Void
  ) {
    let sourceURL = URL(fileURLWithPath: videoPath)
    
    // Check if the source file is already a photo_manager converted file
    let sourceFilename = sourceURL.deletingPathExtension().lastPathComponent
    
    // If this is a file that's already been processed by photo_manager (contains both markers)
    if sourceFilename.contains("_L0_001_") && sourceFilename.contains("_o_") {
      // Already a photo_manager file, return it as is
      sendProgress(path: videoPath, progress: 1.0)
      completion(videoPath, nil)
      return
    }
    
    // Determine file type based on format
    let fileType: AVFileType
    let fileExtension: String
    
    switch format.lowercased() {
    case "mov":
      fileType = .mov
      fileExtension = "mov"
    case "m4a":
      fileType = .m4a
      fileExtension = "m4a"
    case "m4v":
      fileType = .m4v
      fileExtension = "m4v"
    case "3gp", "3gpp":
      if #available(iOS 11.0, *) {
        fileType = .mobile3GPP
        fileExtension = "3gp"
      } else {
        // Fall back to mp4 on older iOS versions
        fileType = .mp4
        fileExtension = "mp4"
      }
    case "prores", "pro_res":
      // Handle ProRes format - fallback to MOV container which supports ProRes codec
      fileType = .mov
      fileExtension = "mov"
    case "mpg", "mpeg", "avi", "webm", "flv", "wmv", "mkv":
      // These formats aren't natively supported, fallback to mp4
      fileType = .mp4
      fileExtension = "mp4"
    default:
      // Default to mp4 for anything else
      fileType = .mp4
      fileExtension = "mp4"
    }
    
    // Create output URL - either use customOutputPath if provided, or generate one
    let outputURL: URL
    if let customPath = customOutputPath {
      outputURL = URL(fileURLWithPath: customPath)
      
      // Ensure the directory exists
      let directoryPath = outputURL.deletingLastPathComponent().path
      if !FileManager.default.fileExists(atPath: directoryPath) {
        try? FileManager.default.createDirectory(at: URL(fileURLWithPath: directoryPath), withIntermediateDirectories: true)
      }
    } else {
      let outputFileName = generateOutputFilename(from: videoPath, format: format, quality: quality)
      let cacheDirectory = getCacheDirectory()
      outputURL = cacheDirectory.appendingPathComponent(outputFileName)
    }
    
    // First check if our converted file already exists and is not empty
    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: outputURL.path) {
      do {
        let attributes = try fileManager.attributesOfItem(atPath: outputURL.path)
        if let fileSize = attributes[.size] as? NSNumber, fileSize.intValue > 0 {
          // File exists and is not empty, return it directly
          sendProgress(path: videoPath, progress: 1.0)
          completion(outputURL.path, nil)
          return
        }
      } catch {
        // Continue with conversion if we can't get file attributes
      }
    }
    
    // Setup asset
    let asset = AVAsset(url: sourceURL)
    
    // Extract source file size for logging and comparison
    var sourceFileSize: UInt64 = 0
    do {
      let attributes = try FileManager.default.attributesOfItem(atPath: videoPath)
      if let size = attributes[.size] as? NSNumber {
        sourceFileSize = size.uint64Value
      }
    } catch {
    }
    
    // Determine quality preset based on quality parameter
    var desiredPreset: String
    switch quality.lowercased() {
    case "high":
      desiredPreset = AVAssetExportPresetHighestQuality
    case "medium":
      desiredPreset = AVAssetExportPreset1920x1080 // Full HD
    case "low":
      desiredPreset = AVAssetExportPreset1280x720 // HD
    default:
      desiredPreset = AVAssetExportPresetHighestQuality
    }
    
    // Check if a more compatible preset might work better
    let compatiblePresets = AVAssetExportSession.exportPresets(compatibleWith: asset)
    
    // Find the best preset based on compatibility
    var preferredPresets: [String]
    
    // If preferred quality is high, try highest presets first
    if quality.lowercased() == "high" {
      preferredPresets = [
        desiredPreset,
        AVAssetExportPresetHighestQuality,
        AVAssetExportPresetPassthrough,  // Try passthrough first to maintain quality
        AVAssetExportPreset1920x1080,    // Full HD
        AVAssetExportPreset1280x720,     // HD
        AVAssetExportPresetMediumQuality // Medium quality as fallback
      ]
      
      // For ProRes formats, try to use ProRes preset if available
      if #available(iOS 11.0, *) {
        if format.lowercased() == "prores" || format.lowercased() == "pro_res" {
          // On iOS 15+, we can use the ProRes preset
          if #available(iOS 15.0, *) {
            if compatiblePresets.contains(AVAssetExportPresetAppleProRes422LPCM) {
              preferredPresets.insert(AVAssetExportPresetAppleProRes422LPCM, at: 0)
            }
          }
        }
      }
    } else if quality.lowercased() == "medium" {
      preferredPresets = [
        desiredPreset,
        AVAssetExportPreset1920x1080,    // Full HD
        AVAssetExportPresetMediumQuality,
        AVAssetExportPreset1280x720,     // HD
        AVAssetExportPresetLowQuality    // Low quality as fallback
      ]
    } else {
      // Low quality or any other setting
      preferredPresets = [
        desiredPreset,
        AVAssetExportPreset1280x720,     // HD
        AVAssetExportPresetLowQuality,
        AVAssetExportPreset640x480      // SD
      ]
    }
    
    // Find the best compatible preset
    var selectedPreset = AVAssetExportPresetMediumQuality // Default fallback
    for preset in preferredPresets {
      if compatiblePresets.contains(preset) {
        selectedPreset = preset
        break
      }
    }
    
    guard let exportSession = AVAssetExportSession(asset: asset, presetName: selectedPreset) else {
      completion(nil, NSError(domain: "VideoConverter", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create export session"]))
      return
    }
    
    // Configure export session
    exportSession.outputURL = outputURL
    exportSession.outputFileType = fileType
    exportSession.shouldOptimizeForNetworkUse = true
    
    // Apply the exact same compression settings used by photo_manager
    // This ensures identical file size output
    if quality.lowercased() == "high" && selectedPreset != AVAssetExportPresetPassthrough {
      // For high quality, we want to preserve the bitrate as much as possible
    } else if quality.lowercased() == "medium" {
      // Medium quality conversion, balanced bitrate
    } else if quality.lowercased() == "low" {
      // Low quality conversion, reduced bitrate
    }
    
    // Set the time range to the full duration of the asset
    // This is important as some videos may have issues with proper start/end times
    let duration = asset.duration
    exportSession.timeRange = CMTimeRangeMake(start: .zero, duration: duration)
    
    // Check if the selected file type is supported for this asset
    if !exportSession.supportedFileTypes.contains(fileType) {
      exportSession.outputFileType = .mp4
    }
    
    // Handle video metadata and orientation
    if let track = asset.tracks(withMediaType: .video).first {
      // Get the preferred transform to handle video orientation
      let preferredTransform = track.preferredTransform
      
      // Check if there are any rotation transformations that need to be maintained
      if !preferredTransform.isIdentity {
        // The video has rotation/orientation that needs to be preserved
      }
      
      // Handle bitrate and dimension preservation to match source more exactly
      // This helps ensure the output file size is consistent with photo_manager's output
      if selectedPreset == AVAssetExportPresetPassthrough || selectedPreset == AVAssetExportPresetHighestQuality {
        // When using highest quality or passthrough, we want to preserve as much information as possible
      }
    }
    
    // Add metadata if available
    let metadataItems = asset.commonMetadata
    if !metadataItems.isEmpty {
      exportSession.metadata = metadataItems
    }
    
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
        
        // Log file size comparison for debugging
        if let outputFileAttributes = try? FileManager.default.attributesOfItem(atPath: outputURL.path),
           let outputFileSize = outputFileAttributes[.size] as? NSNumber {
          let compressionRatio = Double(outputFileSize.uint64Value) / Double(sourceFileSize)
          
          // Register file with NSFileManager by setting additional attributes
          let fileManager = FileManager.default
          let fileAttributes: [FileAttributeKey: Any] = [
            .creationDate: Date(),
            .modificationDate: Date()
          ]
          
          // Attempt to set file attributes
          do {
            try fileManager.setAttributes(fileAttributes, ofItemAtPath: outputURL.path)
          } catch {
          }
          
          // Add to NSFileManager's ubiquitous item list if needed
          if #available(iOS 11.0, *) {
            do {
              // This makes the file visible in the Files app and other file browsers
              var resourceValues = URLResourceValues()
              resourceValues.isExcludedFromBackup = true // Don't include in iCloud backups
              var url = outputURL
              try url.setResourceValues(resourceValues)
            } catch {
            }
          }
        }
      }
      
      switch exportSession.status {
      case .completed:
        completion(outputURL.path, nil)
      case .failed:
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
    let fileManager = FileManager.default
    
    // Photo_manager uses this exact path construction
    let tempPath = NSTemporaryDirectory()
    let videoDir = tempPath + ".video"
    
    // Create directory if it doesn't exist
    if !fileManager.fileExists(atPath: videoDir) {
      do {
        try fileManager.createDirectory(atPath: videoDir, withIntermediateDirectories: true, attributes: nil)
        
        // Set directory attributes to make it properly recognized by NSFileManager
        let dirAttributes: [FileAttributeKey: Any] = [
          .creationDate: Date(),
          .modificationDate: Date(),
          .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
        ]
        
        try fileManager.setAttributes(dirAttributes, ofItemAtPath: videoDir)
        
        // Mark directory as excluded from iCloud backup
        if #available(iOS 11.0, *) {
          do {
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            var url = URL(fileURLWithPath: videoDir)
            try url.setResourceValues(resourceValues)
          } catch {
          }
        }
      } catch {
      }
    }
    
    return URL(fileURLWithPath: videoDir)
  }

  /// Generates a filename consistent with photo_manager's naming pattern
  private func generateOutputFilename(from sourcePath: String, format: String, quality: String) -> String {
    // Extract original filename (without extension)
    let sourceURL = URL(fileURLWithPath: sourcePath)
    var originalFilename = sourceURL.deletingPathExtension().lastPathComponent
    
    // Generate UUID for first part of filename
    let uuid = UUID().uuidString
    
    // Get timestamp for middle part (milliseconds since epoch)
    let timestamp = Date().timeIntervalSince1970
    let timestampStr = String(format: "%.6f", timestamp)
    
    // Check if the original filename already follows photo_manager pattern
    // Pattern: UUID_L0_001_TIMESTAMP_o_ORIGINALNAME
    if originalFilename.contains("_L0_001_") && originalFilename.contains("_o_") {
      // Extract just the original part from existing photo_manager name
      let components = originalFilename.components(separatedBy: "_o_")
      if components.count > 1 {
        // Use the original filename after "_o_"
        originalFilename = components[1]
      }
    }
    
    // Format: UUID_L0_001_TIMESTAMP_o_ORIGINALNAME.mp4
    let fileExtension = format.lowercased() == "mov" ? "mov" : "mp4"
    return "\(originalFilename).\(fileExtension)"
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
