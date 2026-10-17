package com.example.quran_reel_maker

import android.app.Activity
import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private var pendingResult: MethodChannel.Result? = null
    private var pendingFile: File? = null
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "quran_reel/files")
            .setMethodCallHandler { call, result ->
                if (call.method != "saveVideo") { result.notImplemented(); return@setMethodCallHandler }
                if (pendingResult != null) { result.error("busy", "A save dialog is already open.", null); return@setMethodCallHandler }
                val path = call.argument<String>("path")
                if (path == null || !File(path).isFile) {
                    result.error("missing", "The exported video is missing.", null); return@setMethodCallHandler
                }
                pendingResult = result
                pendingFile = File(path)
                try {
                    val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "video/mp4"
                        putExtra(Intent.EXTRA_TITLE, call.argument<String>("name") ?: "quran-reel.mp4")
                    }
                    startActivityForResult(intent, 7321)
                } catch (error: Exception) {
                    pendingResult = null; pendingFile = null
                    result.error("save", error.message, null)
                }
            }
    }
    @Deprecated("Legacy activity result needed by FlutterActivity bridge")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != 7321) return
        val result = pendingResult ?: return
        val file = pendingFile
        pendingResult = null; pendingFile = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null || file == null) { result.success(null); return }
        // Stream the MP4: never load an entire recitation video into the Dart heap.
        Thread {
            try {
                contentResolver.openOutputStream(uri, "w").use { output ->
                    requireNotNull(output) { "Cannot open the chosen destination." }
                    file.inputStream().use { input -> input.copyTo(output) }
                }
                runOnUiThread { result.success(uri.toString()) }
            } catch (error: Exception) { runOnUiThread { result.error("save", error.message, null) } }
        }.start()
    }
}
