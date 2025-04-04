package com.example.flutter_video_converter

import android.content.Context
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.os.Handler
import android.os.Looper
import androidx.annotation.NonNull
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import java.io.File
import java.io.IOException
import java.nio.ByteBuffer
import java.util.*
import kotlin.concurrent.thread

/** FlutterVideoConverterPlugin */
class FlutterVideoConverterPlugin: FlutterPlugin, MethodCallHandler {
  /// The MethodChannel that will the communication between Flutter and native Android
  ///
  /// This local reference serves to register the plugin with the Flutter Engine and unregister it
  /// when the Flutter Engine is detached from the Activity
  private lateinit var channel : MethodChannel
  private lateinit var progressChannel: EventChannel
  private lateinit var context: Context
  private var progressSink: EventChannel.EventSink? = null
  private val mainHandler = Handler(Looper.getMainLooper())

  // Track last time we sent a progress update to avoid sending too many
  private var lastProgressUpdateTime = 0L

  override fun onAttachedToEngine(@NonNull flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
    context = flutterPluginBinding.applicationContext
    channel = MethodChannel(flutterPluginBinding.binaryMessenger, "com.example.flutter_video_converter/converter")
    channel.setMethodCallHandler(this)
    
    progressChannel = EventChannel(flutterPluginBinding.binaryMessenger, "com.example.flutter_video_converter/converter/progress")
    progressChannel.setStreamHandler(object : EventChannel.StreamHandler {
      override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        progressSink = events
      }

      override fun onCancel(arguments: Any?) {
        progressSink = null
      }
    })
  }

  override fun onMethodCall(@NonNull call: MethodCall, @NonNull result: Result) {
    when (call.method) {
      "convertVideo" -> {
        val videoPath = call.argument<String>("videoPath")
        val quality = call.argument<String>("quality") ?: "medium"
        val format = call.argument<String>("format") ?: "mp4"
        
        if (videoPath == null) {
          result.error("INVALID_ARGS", "Video path is required", null)
          return
        }
        
        // Run conversion in a background thread
        thread {
          try {
            val outputPath = convertVideo(videoPath, quality, format)
            mainHandler.post {
              result.success(outputPath)
            }
          } catch (e: Exception) {
            mainHandler.post {
              result.error("CONVERSION_ERROR", e.message, null)
            }
          }
        }
      }
      "convertToMp4" -> {
        val videoPath = call.argument<String>("videoPath")
        if (videoPath == null) {
          result.error("INVALID_ARGS", "Video path is required", null)
          return
        }
        
        // Backwards compatibility - uses mp4 format with medium quality
        thread {
          try {
            val outputPath = convertVideo(videoPath, "medium", "mp4")
            mainHandler.post {
              result.success(outputPath)
            }
          } catch (e: Exception) {
            mainHandler.post {
              result.error("CONVERSION_ERROR", e.message, null)
            }
          }
        }
      }
      "convertMultipleToMp4" -> {
        val videoPaths = call.argument<List<String>>("videoPaths")
        if (videoPaths == null || videoPaths.isEmpty()) {
          result.error("INVALID_ARGS", "Video paths are required", null)
          return
        }
        
        // Run conversion in a background thread
        thread {
          try {
            val outputPaths = convertMultipleVideosToMp4(videoPaths)
            mainHandler.post {
              result.success(outputPaths)
            }
          } catch (e: Exception) {
            mainHandler.post {
              result.error("CONVERSION_ERROR", e.message, null)
            }
          }
        }
      }
      else -> {
        result.notImplemented()
      }
    }
  }

  override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
    channel.setMethodCallHandler(null)
  }
  
  // Send progress with input path
  private fun sendProgress(inputPath: String, progress: Double) {
    val now = System.currentTimeMillis()
    // Rate limit progress updates to avoid flooding the event channel
    if (now - lastProgressUpdateTime >= 200 || progress == 0.0 || progress == 1.0) {
      lastProgressUpdateTime = now
      
      mainHandler.post {
        val progressData = HashMap<String, Any>()
        progressData["path"] = inputPath
        progressData["progress"] = progress
        progressSink?.success(progressData)
      }
    }
  }
  
  private fun convertVideo(videoPath: String, quality: String, format: String): String {
    // Determine quality setting
    val compressionRate = when (quality) {
      "high" -> 0.9  // High quality - 90% of original bitrate
      "medium" -> 0.6  // Medium quality - 60% of original bitrate
      "low" -> 0.3  // Low quality - 30% of original bitrate
      else -> 0.6 // Default to medium
    }
    
    // Determine output format
    val outputFormat = when (format) {
      "mp4" -> MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4
      "webm" -> MediaMuxer.OutputFormat.MUXER_OUTPUT_WEBM
      else -> MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4 // Default to mp4 if format not supported
    }
    
    // Determine file extension
    val fileExtension = when (format) {
      "mp4" -> "mp4"
      "webm" -> "webm"
      "mov" -> "mov"
      "avi" -> "avi"
      else -> "mp4"
    }
    
    // Create output file
    val outputFileName = "converted_${Date().time}.$fileExtension"
    val outputDir = File(context.externalCacheDir, "converted_videos").apply {
      if (!exists()) {
        mkdirs()
      }
    }
    val outputFile = File(outputDir, outputFileName)
    val outputPath = outputFile.absolutePath
    
    try {
      // Notify start of conversion
      sendProgress(videoPath, 0.0)
      
      convertVideoImpl(
        inputPath = videoPath,
        outputPath = outputPath,
        outputFormat = outputFormat,
        compressionRate = compressionRate
      )
      
      // Ensure 100% progress is sent
      sendProgress(videoPath, 1.0)
      
      // Small delay to ensure progress updates are completed
      Thread.sleep(100)
      
      return outputPath
    } catch (e: Exception) {
      throw IOException("Failed to convert video: ${e.message}", e)
    }
  }
  
  @Throws(IOException::class)
  private fun convertVideoImpl(
    inputPath: String,
    outputPath: String,
    outputFormat: Int,
    compressionRate: Double
  ) {
    // Create extractor to read input
    val extractor = MediaExtractor()
    extractor.setDataSource(inputPath)
    
    // Create muxer for output
    val muxer = MediaMuxer(outputPath, outputFormat)
    
    // Map the track indices
    val trackCount = extractor.trackCount
    val indexMap = HashMap<Int, Int>(trackCount)
    
    // Track duration info for progress calculation
    var totalDuration: Long = 0
    
    // First pass: setup tracks and get duration information
    for (i in 0 until trackCount) {
      extractor.selectTrack(i)
      val format = extractor.getTrackFormat(i)
      val mime = format.getString(MediaFormat.KEY_MIME)
      
      // Get track duration if available
      if (format.containsKey(MediaFormat.KEY_DURATION)) {
        val trackDuration = format.getLong(MediaFormat.KEY_DURATION)
        totalDuration = Math.max(totalDuration, trackDuration)
      }
      
      if (mime?.startsWith("video/") == true) {
        // Modify video settings based on quality
        if (format.containsKey(MediaFormat.KEY_BIT_RATE)) {
          val originalBitrate = format.getInteger(MediaFormat.KEY_BIT_RATE)
          val newBitrate = (originalBitrate * compressionRate).toInt()
          format.setInteger(MediaFormat.KEY_BIT_RATE, newBitrate)
        } else {
          // Set default bitrate based on quality
          val defaultBitrate = when {
            compressionRate >= 0.8 -> 3000000 // High quality: ~3 Mbps
            compressionRate >= 0.5 -> 1500000 // Medium quality: ~1.5 Mbps
            else -> 750000 // Low quality: ~750 Kbps
          }
          format.setInteger(MediaFormat.KEY_BIT_RATE, defaultBitrate)
        }
        
        // Set key frame interval based on quality
        if (compressionRate < 0.5) {
          format.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 5) // Key frame every 5 seconds for low quality
        } else {
          format.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 2) // Key frame every 2 seconds for higher quality
        }
        
        // Add track to muxer
        val trackIndex = muxer.addTrack(format)
        indexMap[i] = trackIndex
      } else if (mime?.startsWith("audio/") == true) {
        // For audio tracks, apply more gentle compression
        if (format.containsKey(MediaFormat.KEY_BIT_RATE)) {
          val originalBitrate = format.getInteger(MediaFormat.KEY_BIT_RATE)
          // Audio compression is less aggressive
          val audioCompressionRate = compressionRate + ((1.0 - compressionRate) / 2)
          val newBitrate = (originalBitrate * audioCompressionRate).toInt()
          format.setInteger(MediaFormat.KEY_BIT_RATE, newBitrate)
        }
        
        val trackIndex = muxer.addTrack(format)
        indexMap[i] = trackIndex
      }
      extractor.unselectTrack(i)
    }
    
    // Start muxing
    muxer.start()
    
    // Prepare buffer for reading
    val maxBufferSize = 1024 * 1024 // 1MB buffer
    val buffer = ByteBuffer.allocate(maxBufferSize)
    val bufferInfo = MediaCodec.BufferInfo()
    
    // Process tracks and update progress
    for (i in 0 until trackCount) {
      if (!indexMap.containsKey(i)) continue
      
      extractor.selectTrack(i)
      
      while (true) {
        val sampleSize = extractor.readSampleData(buffer, 0)
        if (sampleSize < 0) break
        
        bufferInfo.offset = 0
        bufferInfo.size = sampleSize
        bufferInfo.presentationTimeUs = extractor.sampleTime
        bufferInfo.flags = extractor.sampleFlags
        
        muxer.writeSampleData(indexMap[i]!!, buffer, bufferInfo)
        
        // Update progress based on presentation time
        if (totalDuration > 0) {
          val videoProgress = bufferInfo.presentationTimeUs.toDouble() / totalDuration.toDouble()
          sendProgress(inputPath, videoProgress)
        }
        
        extractor.advance()
      }
      
      extractor.unselectTrack(i)
    }
    
    // Release resources
    muxer.stop()
    muxer.release()
    extractor.release()
  }
  
  private fun convertMultipleVideosToMp4(videoPaths: List<String>): List<String> {
    val outputPaths = mutableListOf<String>()
    val totalVideos = videoPaths.size
    
    for ((index, videoPath) in videoPaths.withIndex()) {
      try {
        // Convert the individual video
        val outputPath = convertVideo(videoPath, "medium", "mp4")
        outputPaths.add(outputPath)
      } catch (e: Exception) {
        // Log the error but continue with other videos
        e.printStackTrace()
      }
    }
    
    // Ensure 100% progress is sent at the end
    sendProgress(videoPaths[0], 1.0)
    return outputPaths
  }
}
