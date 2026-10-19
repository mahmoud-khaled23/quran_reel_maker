package com.example.quran_reel_maker

import android.app.ActivityManager
import android.content.Context
import android.os.Process
import com.example.quran_reel_maker.alignment.QuranAligner
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** Owns one bounded CPU job; no retained model session after success/cancel/error. */
class AlignmentBridge(private val activity: MainActivity, engine: FlutterEngine) {
    private val channel = MethodChannel(engine.dartExecutor.binaryMessenger, "quran_reel/alignment")
    private val executor = Executors.newSingleThreadExecutor()
    private val busy = AtomicBoolean(false)
    @Volatile private var token: QuranAligner.Cancellation? = null
    @Volatile private var closed = false
    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "cancel" -> { cancel(); result.success(null) }
                "align" -> {
                    if (!Process.is64Bit()) {
                        result.error("abi", "Local alignment requires a 64-bit Android installation. Manual timing and exports remain available on this device.", null)
                    } else if (!busy.compareAndSet(false, true)) {
                        result.error("busy", "An alignment is already finishing. Wait and retry.", null)
                    } else {
                        activity.window.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        val job = QuranAligner.Cancellation(); token = job
                        val request = call.argument<String>("request")
                        val model = call.argument<String>("modelPath")
                        val pcm = call.argument<String>("pcmPath")
                        val id = call.argument<String>("id")
                        executor.execute {
                            val cpuStart = Process.getElapsedCpuTime()
                            val wallStart = android.os.SystemClock.elapsedRealtime()
                            try {
                                val memory = ActivityManager.MemoryInfo()
                                (activity.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager).getMemoryInfo(memory)
                                require(!memory.lowMemory && memory.availMem >= 1200L * 1024 * 1024) {
                                    "Not enough available memory to start. Close other apps, retry, or use manual timing."
                                }
                                fun privateFile(path: String?): File {
                                    val file = File(requireNotNull(path)).canonicalFile
                                    require(file.path.startsWith(activity.filesDir.canonicalPath + File.separator) ||
                                        file.path.startsWith(activity.cacheDir.canonicalPath + File.separator)) { "Alignment input must be in private app storage." }
                                    require(file.isFile) { "Alignment file missing. Download/repair the model or reimport audio." }
                                    return file
                                }
                                val modelFile = privateFile(model); val pcmFile = privateFile(pcm)
                                val quran = activity.assets.open("flutter_assets/assets/quran/quran-uthmani.txt").use { it.readBytes() }
                                val vocab = activity.assets.open("flutter_assets/assets/models/quran-ctc-vocab.json").use { it.readBytes() }
                                fun progress(value: Double, message: String) {
                                    activity.runOnUiThread { if (!closed) channel.invokeMethod("progress", mapOf("id" to id, "value" to value, "message" to message)) }
                                }
                                progress(0.06, "Verifying and loading the local model…")
                                val text = QuranAligner(modelFile, quran, vocab, job).use { aligner ->
                                    job.check()
                                    val output = aligner.align(JSONObject(requireNotNull(request)), pcmFile, job) { value, message -> progress(value, message) }
                                    val metrics = output.getJSONObject("metrics")
                                    metrics.put("processPeakRssKiB", peakRss()).put("androidNativeHeapBytes", android.os.Debug.getNativeHeapAllocatedSize())
                                        .put("processCpuMs", Process.getElapsedCpuTime() - cpuStart)
                                        .put("nativeWallMs", android.os.SystemClock.elapsedRealtime() - wallStart)
                                    job.check()
                                    output.toString()
                                }
                                activity.runOnUiThread { if (!closed) result.success(text) }
                            } catch (error: Throwable) {
                                // Native allocation errors must leave the editor/manual timings usable.
                                var message = when (error) {
                                    is OutOfMemoryError -> "Alignment ran out of memory. Close other apps or use a shorter clip/manual timing."
                                    is UnsatisfiedLinkError -> "Native alignment library unavailable for this ABI. Reinstall the matching 64-bit APK; manual timing remains available."
                                    else -> error.message ?: "Local alignment failed. Retry with a shorter clip or use manual timing."
                                }
                                try { job.check() } catch (cancelled: java.util.concurrent.CancellationException) { message = cancelled.message ?: message }
                                val metrics = mapOf("processPeakRssKiB" to peakRss(),
                                    "processCpuMs" to (Process.getElapsedCpuTime() - cpuStart),
                                    "nativeWallMs" to (android.os.SystemClock.elapsedRealtime() - wallStart))
                                activity.runOnUiThread { if (!closed) result.error("alignment", message, metrics) }
                            } finally {
                                token = null; busy.set(false)
                                activity.runOnUiThread {
                                    if (!activity.packageName.endsWith(".benchmark")) activity.window.clearFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                                }
                            }
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
    private fun peakRss(): Long? = try {
        File("/proc/self/status").useLines { lines -> lines.firstOrNull { it.startsWith("VmHWM:") }?.split(Regex("\\s+"))?.getOrNull(1)?.toLongOrNull() }
    } catch (_: Exception) { null }
    fun cancel(reason: String = "Alignment cancelled. Existing timings were kept.") { token?.cancel(reason) }
    fun close() { closed = true; cancel(); channel.setMethodCallHandler(null); executor.shutdown() }
}
