package com.example.secure_vault

import android.content.ContentUris
import android.content.ContentValues
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import androidx.annotation.RequiresApi
import androidx.exifinterface.media.ExifInterface
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class MainActivity : FlutterActivity() {

    private var pendingMetadataResult: MethodChannel.Result? = null
    private var pendingMetadataUri: Uri? = null
    private var pendingTakenMs: Long = 0L
    private var pendingModifiedMs: Long = 0L

    companion object {
        private const val REQUEST_EDIT_IMAGE = 4102
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "vault/export")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "save" -> handleSave(call, result)
                    "takenDates" -> handleTakenDates(call, result)
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "gallery/metadata")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "updateImageDates" -> handleUpdateImageDates(call, result)
                    else -> result.notImplemented()
                }
            }
    }

    // ───────────── save: vault -> gallery ─────────────
    private fun handleSave(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        val name = call.argument<String>("name")
        val mime = call.argument<String>("mime")
        val takenMs = call.argument<Number>("takenMs")?.toLong()
        val modifiedMs = call.argument<Number>("modifiedMs")?.toLong()

        if (path == null || name == null || mime == null || takenMs == null || modifiedMs == null) {
            result.success(false)
            return
        }

        Thread {
            val ok = saveToMediaStore(path, name, mime, takenMs, modifiedMs)
            runOnUiThread { result.success(ok) }
        }.start()
    }

    private fun saveToMediaStore(
        path: String, name: String, mime: String, takenMs: Long, modifiedMs: Long
    ): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return false

        val src = File(path)
        if (!src.exists()) return false

        var uri: Uri? = null
        return try {
            val isVideo = mime.startsWith("video")
            val isAudio = mime.startsWith("audio")
            val (collection, folder) = when {
                isVideo -> Pair(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, "Movies/Restored")
                isAudio -> Pair(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, "Music/Restored")
                else -> Pair(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, "Pictures/Restored")
            }

            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                put(MediaStore.MediaColumns.MIME_TYPE, mime)
                put(MediaStore.MediaColumns.RELATIVE_PATH, folder)
                if (!isAudio) put(MediaStore.MediaColumns.DATE_TAKEN, takenMs)
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }

            uri = contentResolver.insert(collection, values) ?: return false
            contentResolver.openOutputStream(uri!!)?.use { out ->
                src.inputStream().use { it.copyTo(out) }
            } ?: throw IOException("openOutputStream returned null")

            try {
                contentResolver.query(uri!!, arrayOf(MediaStore.MediaColumns.DATA), null, null, null)?.use { c ->
                    if (c.moveToFirst()) c.getString(0)?.let { File(it).setLastModified(modifiedMs) }
                }
            } catch (_: Exception) {}

            val done = ContentValues().apply {
                put(MediaStore.MediaColumns.IS_PENDING, 0)
                put(MediaStore.MediaColumns.DATE_MODIFIED, modifiedMs / 1000)
                if (!isAudio) put(MediaStore.MediaColumns.DATE_TAKEN, takenMs)
            }
            contentResolver.update(uri!!, done, null, null)
            true
        } catch (_: Exception) {
            uri?.let { try { contentResolver.delete(it, null, null) } catch (_: Exception) {} }
            false
        }
    }

    // ───────────── takenDates: gallery assets -> EXIF taken date ─────────────
    private fun handleTakenDates(call: MethodCall, result: MethodChannel.Result) {
        val ids = call.argument<List<String>>("ids") ?: emptyList()
        Thread {
            val map = HashMap<String, Long>()
            try {
                ids.chunked(500).forEach { chunk ->
                    val sel = "${MediaStore.MediaColumns._ID} IN (${chunk.joinToString(",") { "?" }})"
                    contentResolver.query(
                        MediaStore.Files.getContentUri("external"),
                        arrayOf(MediaStore.MediaColumns._ID, MediaStore.MediaColumns.DATE_TAKEN),
                        sel, chunk.toTypedArray(), null
                    )?.use { c ->
                        while (c.moveToNext()) {
                            val t = c.getLong(1)
                            if (t > 0) map[c.getLong(0).toString()] = t
                        }
                    }
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    ids.forEach { sid ->
                        val id = sid.toLongOrNull() ?: return@forEach
                        exifTakenMs(id)?.let { map[sid] = it }
                    }
                }
            } catch (_: Exception) {}
            runOnUiThread { result.success(map) }
        }.start()
    }

    @RequiresApi(Build.VERSION_CODES.N)
    private fun exifTakenMs(id: Long): Long? {
        return try {
            val uri = ContentUris.withAppendedId(MediaStore.Files.getContentUri("external"), id)
            contentResolver.openInputStream(uri)?.use { stream ->
                val exif = ExifInterface(stream)
                val raw = exif.getAttribute(ExifInterface.TAG_DATETIME_ORIGINAL)
                    ?: exif.getAttribute(ExifInterface.TAG_DATETIME_DIGITIZED)
                    ?: exif.getAttribute(ExifInterface.TAG_DATETIME)
                if (raw == null || raw.startsWith("0000")) null
                else SimpleDateFormat("yyyy:MM:dd HH:mm:ss", Locale.US).parse(raw.trim())?.time
            }
        } catch (_: Exception) { null }
    }

    // ───────────── edit: EXIF dates + MediaStore dates ─────────────
    private fun handleUpdateImageDates(call: MethodCall, result: MethodChannel.Result) {
        val id = call.argument<String>("assetId")?.toLongOrNull()
        val takenMs = call.argument<Number>("takenMs")?.toLong()
        val modifiedMs = call.argument<Number>("modifiedMs")?.toLong()
        if (id == null || takenMs == null || modifiedMs == null) {
            result.success(false)
            return
        }

        val uri = ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, id)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            try {
                // Android 11+ requires the user's approval before changing another app's image.
                pendingMetadataResult = result
                pendingMetadataUri = uri
                pendingTakenMs = takenMs
                pendingModifiedMs = modifiedMs
                val request = MediaStore.createWriteRequest(contentResolver, listOf(uri))
                startIntentSenderForResult(request.intentSender, REQUEST_EDIT_IMAGE, null, 0, 0, 0)
            } catch (e: Exception) {
                clearPendingMetadata()
                result.error("EDIT_PERMISSION", e.message ?: "Could not request image edit permission", null)
            }
        } else {
            Thread {
                val ok = writeImageDates(uri, takenMs, modifiedMs)
                runOnUiThread { result.success(ok) }
            }.start()
        }
    }

    @Deprecated("Deprecated in Android, retained for the MediaStore write approval callback")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_EDIT_IMAGE) return
        val callback = pendingMetadataResult ?: return
        val uri = pendingMetadataUri
        val taken = pendingTakenMs
        val modified = pendingModifiedMs
        clearPendingMetadata()
        if (resultCode != RESULT_OK || uri == null) {
            callback.success(false)
            return
        }
        Thread {
            val ok = writeImageDates(uri, taken, modified)
            runOnUiThread { callback.success(ok) }
        }.start()
    }

    private fun clearPendingMetadata() {
        pendingMetadataResult = null
        pendingMetadataUri = null
        pendingTakenMs = 0L
        pendingModifiedMs = 0L
    }

    private fun writeImageDates(uri: Uri, takenMs: Long, modifiedMs: Long): Boolean {
        return try {
            val formatted = SimpleDateFormat("yyyy:MM:dd HH:mm:ss", Locale.US).format(Date(takenMs))
            contentResolver.openFileDescriptor(uri, "rw")?.use { pfd ->
                val exif = ExifInterface(pfd.fileDescriptor)
                exif.setAttribute(ExifInterface.TAG_DATETIME_ORIGINAL, formatted)
                exif.setAttribute(ExifInterface.TAG_DATETIME_DIGITIZED, formatted)
                exif.setAttribute(ExifInterface.TAG_DATETIME, formatted)
                exif.saveAttributes()
            } ?: return false

            val values = ContentValues().apply {
                put(MediaStore.Images.Media.DATE_TAKEN, takenMs)
                put(MediaStore.Images.Media.DATE_MODIFIED, modifiedMs / 1000L)
            }
            val updated = contentResolver.update(uri, values, null, null)
            updated > 0
        } catch (_: SecurityException) {
            false
        } catch (_: Exception) {
            false
        }
    }
}
