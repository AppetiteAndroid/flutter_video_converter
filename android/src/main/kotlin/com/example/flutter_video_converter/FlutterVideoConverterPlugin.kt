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
      "convertToMp4" -> {
        val videoPath = call.argument<String>("videoPath")
        if (videoPath == null) {
          result.error("INVALID_ARGS", "Video path is required", null)
          return
        }
        
        // Run conversion in a background thread
        thread {
          try {
            val outputPath = convertVideoToMp4(videoPath)
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
  
  private fun updateProgress(progress: Double) {
    mainHandler.post {
      progressSink?.success(progress)
    }
  }
  
  private fun convertMultipleVideosToMp4(videoPaths: List<String>): List<String> {
    val outputPaths = mutableListOf<String>()
    val totalVideos = videoPaths.size
    
    for ((index, videoPath) in videoPaths.withIndex()) {
      try {
        // Convert the individual video
        val outputPath = convertVideoToMp4WithScaledProgress(
          videoPath,
          startProgress = index.toDouble() / totalVideos,
          endProgress = (index + 1.0) / totalVideos
        )
        outputPaths.add(outputPath)
      } catch (e: Exception) {
        // Log the error but continue with other videos
        e.printStackTrace()
      }
    }
    
    // Ensure 100% progress is sent at the end
    updateProgress(1.0)
    return outputPaths
  }
  
  private fun convertVideoToMp4(videoPath: String): String {
    return convertVideoToMp4WithScaledProgress(videoPath, 0.0, 1.0)
  }
  
  private fun convertVideo(videoPath: String, quality: String, format: String): String {
    // Определение качества конвертации
    val compressionRate = when (quality) {
      "high" -> 0.9  // высокое качество - 90% оригинального битрейта
      "medium" -> 0.6  // среднее качество - 60% оригинального битрейта
      "low" -> 0.3  // низкое качество - 30% оригинального битрейта
      else -> 0.6 // по умолчанию среднее
    }
    
    // Определение формата вывода
    val outputFormat = when (format) {
      "mp4" -> MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4
      "webm" -> MediaMuxer.OutputFormat.MUXER_OUTPUT_WEBM
      else -> MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4 // mp4 по умолчанию, если формат не поддерживается
    }
    
    // Определение расширения файла
    val fileExtension = when (format) {
      "mp4" -> "mp4"
      "webm" -> "webm"
      "mov" -> "mov"
      "avi" -> "avi"
      else -> "mp4"
    }
    
    // Создание имени выходного файла
    val outputFileName = "converted_${Date().time}.$fileExtension"
    val outputDir = File(context.externalCacheDir, "converted_videos").apply {
      if (!exists()) {
        mkdirs()
      }
    }
    val outputFile = File(outputDir, outputFileName)
    val outputPath = outputFile.absolutePath
    
    // Конвертация видео
    try {
      convertWithCustomFormat(
        inputPath = videoPath,
        outputPath = outputPath,
        outputFormat = outputFormat,
        compressionRate = compressionRate,
        startProgress = 0.0,
        endProgress = 1.0
      )
      return outputPath
    } catch (e: Exception) {
      throw IOException("Failed to convert video: ${e.message}", e)
    }
  }
  
  private fun convertVideoToMp4WithScaledProgress(
    videoPath: String, 
    startProgress: Double = 0.0, 
    endProgress: Double = 1.0
  ): String {
    // Create output file in a more accessible location (external cache)
    val outputFileName = "converted_${Date().time}.mp4"
    val outputDir = File(context.externalCacheDir, "converted_videos").apply {
      if (!exists()) {
        mkdirs()
      }
    }
    val outputFile = File(outputDir, outputFileName)
    val outputPath = outputFile.absolutePath
    
    // Use the MediaMuxer approach
    try {
      convertWithMuxer(videoPath, outputPath, startProgress, endProgress)
      return outputPath
    } catch (e: Exception) {
      throw IOException("Failed to convert video: ${e.message}", e)
    }
  }
  
  @Throws(IOException::class)
  private fun convertWithCustomFormat(
    inputPath: String,
    outputPath: String,
    outputFormat: Int,
    compressionRate: Double,
    startProgress: Double = 0.0,
    endProgress: Double = 1.0
  ) {
    // Calculate the progress range for this conversion
    val progressRange = endProgress - startProgress
    
    // Create extractor to read input
    val extractor = MediaExtractor()
    extractor.setDataSource(inputPath)
    
    // Create muxer for output
    val muxer = MediaMuxer(outputPath, outputFormat)
    
    // Map the track indices
    val trackCount = extractor.trackCount
    val indexMap = HashMap<Int, Int>(trackCount)
    
    // Use a simpler progress approach based on tracks
    val trackDurations = LongArray(trackCount)
    var totalDuration: Long = 0
    
    // First pass: setup tracks and get duration information
    for (i in 0 until trackCount) {
      extractor.selectTrack(i)
      val format = extractor.getTrackFormat(i)
      val mime = format.getString(MediaFormat.KEY_MIME)
      
      if (mime?.startsWith("video/") == true) {
        // Get track duration if available
        var trackDuration: Long = 0
        if (format.containsKey(MediaFormat.KEY_DURATION)) {
          trackDuration = format.getLong(MediaFormat.KEY_DURATION)
          trackDurations[i] = trackDuration
          totalDuration = Math.max(totalDuration, trackDuration)
        }
        
        // Modify the video bitrate to match selected quality
        if (format.containsKey(MediaFormat.KEY_BIT_RATE)) {
          val originalBitrate = format.getInteger(MediaFormat.KEY_BIT_RATE)
          val newBitrate = (originalBitrate * compressionRate).toInt()
          format.setInteger(MediaFormat.KEY_BIT_RATE, newBitrate)
        } else {
          // Установка битрейта по умолчанию в зависимости от качества
          val defaultBitrate = when {
            compressionRate >= 0.8 -> 3000000 // High quality: ~3 Mbps
            compressionRate >= 0.5 -> 1500000 // Medium quality: ~1.5 Mbps
            else -> 750000 // Low quality: ~750 Kbps
          }
          format.setInteger(MediaFormat.KEY_BIT_RATE, defaultBitrate)
        }
        
        // Добавление параметров для управления качеством
        if (compressionRate < 0.5) {
          // При низком качестве мы уменьшаем частоту ключевых кадров
          format.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 5) // Ключевой кадр каждые 5 секунд
        } else {
          format.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 2) // Ключевой кадр каждые 2 секунды
        }
        
        // Add track to muxer
        val trackIndex = muxer.addTrack(format)
        indexMap[i] = trackIndex
      } else if (mime?.startsWith("audio/") == true) {
        // For audio tracks, we can reduce bitrate too but not as aggressively
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
    
    // Process tracks and update progress based on presentation time
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
          val scaledProgress = startProgress + (videoProgress * progressRange)
          updateProgress(scaledProgress)
        }
        
        extractor.advance()
      }
      
      extractor.unselectTrack(i)
    }
    
    // Update progress to the end of this video's range
    updateProgress(endProgress)
    
    // Release resources
    muxer.stop()
    muxer.release()
    extractor.release()
  }
  
  @Throws(IOException::class)
  private fun convertWithMuxer(
    inputPath: String, 
    outputPath: String, 
    startProgress: Double = 0.0, 
    endProgress: Double = 1.0
  ) {
    // Используем новую реализацию с параметрами по умолчанию
    convertWithCustomFormat(
      inputPath = inputPath,
      outputPath = outputPath,
      outputFormat = MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4,
      compressionRate = 0.6, // средний уровень качества
      startProgress = startProgress,
      endProgress = endProgress
    )
  }
}
