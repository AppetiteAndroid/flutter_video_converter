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
    
    // Determine quality preset
    let preset: String
    switch quality {
    case "high":
      preset = AVAssetExportPresetHighestQuality
    case "medium":
      preset = AVAssetExportPresetMediumQuality
    case "low":
      preset = AVAssetExportPresetLowQuality
    default:
      preset = AVAssetExportPresetMediumQuality
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
    
    // Create output URL in temp directory
    let outputFileName = "converted_\(Int(Date().timeIntervalSince1970)).\(fileExtension)"
    let tempDirectory = FileManager.default.temporaryDirectory
    let outputURL = tempDirectory.appendingPathComponent(outputFileName)
    
    // Setup asset and export session
    let asset = AVAsset(url: sourceURL)
    
    guard let exportSession = AVAssetExportSession(asset: asset, presetName: preset) else {
      completion(nil, NSError(domain: "VideoConverter", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create export session"]))
      return
    }
    
    // Configure export session
    exportSession.outputURL = outputURL
    exportSession.outputFileType = fileType
    exportSession.shouldOptimizeForNetworkUse = true

    // Send initial progress
    sendProgress(path: videoPath, progress: 0.0)
    
    // Setup progress monitoring
    let progressTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] timer in
      if exportSession.status == .exporting {
        DispatchQueue.main.async {
          self?.sendProgress(path: videoPath, progress: exportSession.progress)
        }
      } else if exportSession.status != .waiting {
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
        // Wait a moment before returning the result to let the progress update
        // This should prevent any overlap between finishing one conversion and starting another
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
          completion(outputURL.path, nil)
        }
      case .failed:
        completion(nil, exportSession.error)
      case .cancelled:
        completion(nil, NSError(domain: "VideoConverter", code: -2, userInfo: [NSLocalizedDescriptionKey: "Export cancelled"]))
      default:
        completion(nil, NSError(domain: "VideoConverter", code: -3, userInfo: [NSLocalizedDescriptionKey: "Unknown error"]))
      }
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
}
