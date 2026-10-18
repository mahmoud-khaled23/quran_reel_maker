package com.example.quran_reel_maker

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.Locale
import java.util.concurrent.CancellationException

class MainActivity : FlutterActivity() {
    private var pendingResult: MethodChannel.Result? = null
    private var pendingFile: File? = null
    private var pendingVideos: List<Map<String, String>>? = null
    @Volatile private var cancelBatch = false
    private lateinit var filesChannel: MethodChannel
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        filesChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "quran_reel/files")
        filesChannel.setMethodCallHandler { call, result ->
                if (call.method == "cancelSave") { cancelBatch = true; result.success(null); return@setMethodCallHandler }
                if (call.method == "saveVideos") {
                    if (pendingResult != null) { result.error("busy", "A save is already open.", null); return@setMethodCallHandler }
                    val videos = call.argument<List<Map<String, String>>>("videos")
                    if (videos.isNullOrEmpty() || videos.size > 1000 || videos.any {
                        val name = it["name"] ?: ""
                        val path = it["path"] ?: ""
                        !File(path).isFile || name.isBlank() || name.contains('/') || name.contains('\\') || name.contains('\u0000') || !name.endsWith(".mp4")
                    }) { result.error("invalid", "Select valid video segments and filenames.", null); return@setMethodCallHandler }
                    pendingResult = result
                    pendingVideos = videos
                    cancelBatch = false
                    try {
                        startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE), 7322)
                    } catch (error: Exception) {
                        pendingResult = null; pendingVideos = null
                        result.error("save", error.message, null)
                    }
                    return@setMethodCallHandler
                }
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
        if (requestCode == 7322) {
            val result = pendingResult ?: return
            val videos = pendingVideos
            val tree = data?.data
            if (resultCode != Activity.RESULT_OK || tree == null || videos == null) {
                pendingResult = null; pendingVideos = null; result.success(null); return
            }
            saveBatch(tree, videos, result)
            return
        }
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

    private fun saveBatch(tree: Uri, videos: List<Map<String, String>>, result: MethodChannel.Result) {
        Thread {
            val created = mutableListOf<Uri>()
            try {
                val documentId = DocumentsContract.getTreeDocumentId(tree)
                val directory = DocumentsContract.buildDocumentUriUsingTree(tree, documentId)
                val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, documentId)
                val used = mutableSetOf<String>()
                requireNotNull(contentResolver.query(children, arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)).use { cursor ->
                    while (cursor.moveToNext()) used.add(cursor.getString(0).lowercase(Locale.ROOT))
                }
                fun checkCancelled() { if (cancelBatch) throw CancellationException("Saving cancelled.") }
                fun create(name: String, mime: String): Pair<Uri, String> {
                    checkCancelled()
                    val dot = name.lastIndexOf('.')
                    val base = if (dot > 0) name.substring(0, dot) else name
                    val extension = if (dot > 0) name.substring(dot) else ""
                    var candidate = name
                    var number = 2
                    while (!used.add(candidate.lowercase(Locale.ROOT))) candidate = "$base (${number++})$extension"
                    val uri = requireNotNull(DocumentsContract.createDocument(contentResolver, directory, mime, candidate)) { "Cannot create a file in this folder." }
                    created.add(uri)
                    val actual = contentResolver.query(uri, arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)?.use { cursor ->
                        if (cursor.moveToFirst()) cursor.getString(0) else candidate
                    } ?: candidate
                    used.add(actual.lowercase(Locale.ROOT))
                    return Pair(uri, actual)
                }
                val total = videos.sumOf { File(it.getValue("path")).length() }.coerceAtLeast(1)
                var copied = 0L
                var reported = -1.0
                val names = mutableListOf<String>()
                for (video in videos) {
                    val file = File(video.getValue("path"))
                    val (uri, name) = create(video.getValue("name"), "video/mp4")
                    requireNotNull(contentResolver.openOutputStream(uri, "w")).use { output ->
                        file.inputStream().use { input ->
                            val buffer = ByteArray(256 * 1024)
                            while (true) {
                                checkCancelled()
                                val length = input.read(buffer)
                                if (length < 0) break
                                output.write(buffer, 0, length)
                                copied += length
                                val progress = (copied.toDouble() / total).coerceIn(0.0, 1.0)
                                if (progress - reported >= 0.01) {
                                    reported = progress
                                    runOnUiThread { filesChannel.invokeMethod("saveProgress", progress) }
                                }
                            }
                        }
                    }
                    val notice = File("${file.path}.txt")
                    if (notice.isFile) {
                        val (noticeUri, _) = create("$name.txt", "text/plain")
                        requireNotNull(contentResolver.openOutputStream(noticeUri, "w")).use { output -> notice.inputStream().use { it.copyTo(output) } }
                    }
                    names.add(name)
                }
                checkCancelled()
                runOnUiThread { pendingResult = null; pendingVideos = null; result.success(names) }
            } catch (error: Exception) {
                var remaining = 0
                for (uri in created.asReversed()) {
                    try { if (!DocumentsContract.deleteDocument(contentResolver, uri)) remaining++ } catch (_: Exception) { remaining++ }
                }
                runOnUiThread {
                    pendingResult = null; pendingVideos = null
                    val extra = if (remaining > 0) " $remaining new files could not be removed; inspect the selected folder." else " New files from this attempt were removed."
                    result.error(if (error is CancellationException && remaining == 0) "cancelled" else "save", "${error.message}$extra", null)
                }
            }
        }.start()
    }
}
