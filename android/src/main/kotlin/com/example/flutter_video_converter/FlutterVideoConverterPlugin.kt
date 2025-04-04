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
import android.util.Log
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaMetadataRetriever

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
      "clearCache" -> {
        thread {
          try {
            val deletedCount = clearCache()
            mainHandler.post {
              result.success(deletedCount)
            }
          } catch (e: Exception) {
            mainHandler.post {
              result.error("CACHE_ERROR", e.message, null)
            }
          }
        }
      }
      "getCachedFiles" -> {
        thread {
          try {
            val cachedFiles = getCachedFiles()
            mainHandler.post {
              result.success(cachedFiles)
            }
          } catch (e: Exception) {
            mainHandler.post {
              result.error("CACHE_ERROR", e.message, null)
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
    // Determine quality setting - now we'll use explicit bitrates instead of multipliers
    val qualityLevel = when (quality) {
      "high" -> VideoQuality.HIGH
      "medium" -> VideoQuality.MEDIUM
      "low" -> VideoQuality.LOW
      else -> VideoQuality.MEDIUM // Default to medium
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
    
    // Create a hash of the input params for consistent file naming
    val hash = "$videoPath|$quality|$format".hashCode()
    
    // Create output file with consistent naming based on input parameters
    val outputFileName = "converted_${hash}.$fileExtension"
    val outputDir = File(context.externalCacheDir, "converted_videos").apply {
      if (!exists()) {
        mkdirs()
      }
    }
    val outputFile = File(outputDir, outputFileName)
    val outputPath = outputFile.absolutePath
    
    // Check if the file already exists
    if (outputFile.exists() && outputFile.length() > 0) {
      // File already exists, return it directly
      Log.d("VideoConverter", "Using existing file: $outputPath")
      sendProgress(videoPath, 1.0)
      return outputPath
    }
    
    try {
      // Send initial progress
      sendProgress(videoPath, 0.0)
      
      // Use a simpler approach that will work reliably
      val compressionRate = when (qualityLevel) {
        VideoQuality.HIGH -> 0.9  // High quality - 90% of original
        VideoQuality.MEDIUM -> 0.6  // Medium quality - 60% of original
        VideoQuality.LOW -> 0.3  // Low quality - 30% of original
      }
      
      // Extract and log video metadata to help with debugging
      val retriever = MediaMetadataRetriever()
      retriever.setDataSource(videoPath)
      val width = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)
      val height = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)
      val duration = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
      Log.d("VideoConverter", "Video metadata: ${width}x${height}, duration: ${duration}ms, quality: $quality")
      
      // Create an extractor to read the source file
      val extractor = MediaExtractor()
      extractor.setDataSource(videoPath)
      
      // Create a muxer to write to the destination file
      val muxer = MediaMuxer(outputPath, outputFormat)
      
      // Track the indexes that we process
      val trackIndexMap = HashMap<Int, Int>()
      
      // Find all tracks and add them to the muxer
      for (i in 0 until extractor.trackCount) {
        val format = extractor.getTrackFormat(i)
        val mimeType = format.getString(MediaFormat.KEY_MIME)
        
        Log.d("VideoConverter", "Track $i mime type: $mimeType")
        
        // Modify the bitrate for video tracks
        if (mimeType?.startsWith("video/") == true) {
          // Get original bitrate or estimate one based on resolution and frame rate
          var originalBitrate = if (format.containsKey(MediaFormat.KEY_BIT_RATE)) {
            format.getInteger(MediaFormat.KEY_BIT_RATE)
          } else {
            // Estimate bitrate if not present (resolution * framerate * 0.07 as a rough estimate)
            val frameRate = if (format.containsKey(MediaFormat.KEY_FRAME_RATE)) {
              format.getInteger(MediaFormat.KEY_FRAME_RATE)
            } else {
              30 // Assume 30fps if not specified
            }
            val videoWidth = format.getInteger(MediaFormat.KEY_WIDTH)
            val videoHeight = format.getInteger(MediaFormat.KEY_HEIGHT)
            (videoWidth * videoHeight * frameRate * 0.07).toInt()
          }
          
          // Make sure we have a reasonable minimum bitrate
          if (originalBitrate < 500000) {
            originalBitrate = 500000 // 500 Kbps minimum
          }
          
          // Apply compression based on quality
          val newBitrate = (originalBitrate * compressionRate).toInt()
          format.setInteger(MediaFormat.KEY_BIT_RATE, newBitrate)
          
          // Set i-frame interval based on quality
          val iFrameInterval = when (qualityLevel) {
            VideoQuality.HIGH -> 1  // Keyframe every 1 second
            VideoQuality.MEDIUM -> 2  // Keyframe every 2 seconds
            VideoQuality.LOW -> 5  // Keyframe every 5 seconds
          }
          format.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, iFrameInterval)
          
          Log.d("VideoConverter", "Setting video bitrate: $newBitrate (${newBitrate/1000} Kbps)")
        } else if (mimeType?.startsWith("audio/") == true) {
          // Also adjust audio bitrate for lower quality settings
          if (format.containsKey(MediaFormat.KEY_BIT_RATE)) {
            val audioBitrate = when (qualityLevel) {
              VideoQuality.HIGH -> format.getInteger(MediaFormat.KEY_BIT_RATE) // Keep original for high
              VideoQuality.MEDIUM -> 128000  // 128 Kbps for medium
              VideoQuality.LOW -> 96000  // 96 Kbps for low
            }
            format.setInteger(MediaFormat.KEY_BIT_RATE, audioBitrate)
            Log.d("VideoConverter", "Setting audio bitrate: $audioBitrate (${audioBitrate/1000} Kbps)")
          }
        }
        
        // Add track to muxer
        val destTrackIndex = muxer.addTrack(format)
        trackIndexMap[i] = destTrackIndex
      }
      
      // Start the muxer now that all tracks are added
      muxer.start()
      
      // Buffer for reading from extractor
      val MAX_BUFFER_SIZE = 1024 * 1024 // 1MB
      val buffer = ByteBuffer.allocate(MAX_BUFFER_SIZE)
      val bufferInfo = MediaCodec.BufferInfo()
      
      // Track our progress
      val startTime = System.currentTimeMillis()
      val estimatedDurationMs = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLong() ?: 10000
      var lastProgressUpdate = 0.0
      
      // Process each track
      for (trackIndex in trackIndexMap.keys) {
        extractor.selectTrack(trackIndex)
        
        while (true) {
          // Update progress periodically
          val currentTime = System.currentTimeMillis()
          val elapsedTimeMs = currentTime - startTime
          val progressPercent = Math.min(0.99, elapsedTimeMs.toDouble() / (estimatedDurationMs * 1.5))
          
          if (progressPercent - lastProgressUpdate >= 0.05) { // Update progress every 5%
            sendProgress(videoPath, progressPercent)
            lastProgressUpdate = progressPercent
          }
          
          // Read a sample from the extractor
          val sampleSize = extractor.readSampleData(buffer, 0)
          if (sampleSize < 0) {
            break // End of track
          }
          
          // Set up the buffer info
          bufferInfo.offset = 0
          bufferInfo.size = sampleSize
          bufferInfo.presentationTimeUs = extractor.sampleTime
          bufferInfo.flags = extractor.sampleFlags
          
          // Write the sample to the muxer
          muxer.writeSampleData(trackIndexMap[trackIndex]!!, buffer, bufferInfo)
          
          // Advance to the next sample
          extractor.advance()
        }
        
        // Deselect this track before moving to the next one
        extractor.unselectTrack(trackIndex)
      }
      
      // Clean up
      retriever.release()
      muxer.stop()
      muxer.release()
      extractor.release()
      
      // Send final progress
      sendProgress(videoPath, 1.0)
      
      // Log size difference
      val sourceFile = File(videoPath)
      val sourceSize = sourceFile.length()
      val outputSize = outputFile.length()
      val ratioPercent = (outputSize.toDouble() / sourceSize.toDouble() * 100).toInt()
      
      Log.d("VideoConverter", "Conversion complete - Original: ${sourceSize/1024}KB, Converted: ${outputSize/1024}KB, Ratio: $ratioPercent%")
      
      return outputPath
    } catch (e: Exception) {
      Log.e("VideoConverter", "Error during conversion: ${e.message}", e)
      sendProgress(videoPath, 1.0) // Ensure we send final progress even on error
      throw IOException("Failed to convert video: ${e.message}", e)
    }
  }
  
  // Enum class for quality levels
  enum class VideoQuality {
    HIGH, MEDIUM, LOW
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
  
  // Add methods for cache management
  
  /**
   * Deletes all files in the conversion cache directory.
   *
   * @return The number of files deleted
   */
  private fun clearCache(): Int {
    val cacheDir = File(context.externalCacheDir, "converted_videos")
    if (!cacheDir.exists()) {
      return 0
    }
    
    var count = 0
    cacheDir.listFiles()?.forEach { file ->
      if (file.isFile && file.delete()) {
        count++
      }
    }
    
    return count
  }
  
  /**
   * Gets a list of all file paths in the conversion cache directory.
   *
   * @return List of file paths
   */
  private fun getCachedFiles(): List<String> {
    val cacheDir = File(context.externalCacheDir, "converted_videos")
    if (!cacheDir.exists()) {
      return emptyList()
    }
    
    return cacheDir.listFiles()
      ?.filter { it.isFile }
      ?.map { it.absolutePath }
      ?: emptyList()
  }
}
