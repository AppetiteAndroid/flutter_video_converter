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
  
  private func convertVideo(
    videoPath: String,
    quality: String,
    format: String,
    progressRange: (start: Double, end: Double)? = nil,
    completion: @escaping (String?, Error?) -> Void
  ) {
    let sourceURL = URL(fileURLWithPath: videoPath)
    
    // Определение пресета качества
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
    
    // Определение типа файла
    let fileType: AVFileType
    let fileExtension: String
    switch format {
    case "mp4":
      fileType = .mp4
      fileExtension = "mp4"
    case "mov":
      fileType = .mov
      fileExtension = "mov"
    case "webm":
      // WebM не поддерживается напрямую в iOS, используем MP4
      fileType = .mp4
      fileExtension = "mp4"
    case "avi":
      // AVI не поддерживается напрямую в iOS, используем MP4
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
    
    // Setup progress monitoring
    let progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
      if exportSession.status == .exporting {
        DispatchQueue.main.async {
          if let progressRange = progressRange {
            // Scale progress within the given range
            let scaledProgress = progressRange.start + (exportSession.progress * (progressRange.end - progressRange.start))
            // Send progress with path
            self?.sendProgressWithPath(path: videoPath, progress: scaledProgress)
          } else {
            self?.sendProgressWithPath(path: videoPath, progress: exportSession.progress)
          }
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
        if let progressRange = progressRange {
          self?.sendProgressWithPath(path: videoPath, progress: progressRange.end)
        } else if exportSession.status == .completed {
          self?.sendProgressWithPath(path: videoPath, progress: 1.0)
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
  
  // Helper method to send progress with file path
  private func sendProgressWithPath(path: String, progress: Double) {
    let progressData: [String: Any] = [
      "path": path,
      "progress": progress
    ]
    progressEventSink?(progressData)
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
      progressRange: progressRange,
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
