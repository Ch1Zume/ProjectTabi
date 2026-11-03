package com.ch1zume.projecttabi

import android.Manifest
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.provider.OpenableColumns
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Picks travel photos while keeping their EXIF location.
 *
 * Android redacts GPS tags from shared media unless the app holds
 * ACCESS_MEDIA_LOCATION and opens the original via setRequireOriginal, which
 * the generic image pickers do not do. Picked photos are copied into the
 * cache and their paths returned to Dart.
 */
class TravelPhotoPicker(
    private val activity: Activity,
    messenger: BinaryMessenger,
) {
    private val channel = MethodChannel(messenger, "projecttabi/travel_photos")
    private val mainHandler = Handler(Looper.getMainLooper())
    private var pending: MethodChannel.Result? = null

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method != "pickPhotos") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            if (pending != null) {
                result.error("BUSY", "A photo picker is already open", null)
                return@setMethodCallHandler
            }
            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "image/*"
                putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
            }
            pending = result
            try {
                activity.startActivityForResult(intent, REQUEST_CODE)
            } catch (error: ActivityNotFoundException) {
                pending = null
                result.error("NO_PICKER", error.message, null)
            }
        }
    }

    fun close() {
        channel.setMethodCallHandler(null)
        pending?.success(emptyList<String>())
        pending = null
    }

    /** Returns true when the result belonged to this picker. */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_CODE) return false
        val result = pending ?: return true
        pending = null
        if (resultCode != Activity.RESULT_OK || data == null) {
            result.success(emptyList<String>())
            return true
        }
        val uris = mutableListOf<Uri>()
        val clip = data.clipData
        if (clip != null) {
            for (index in 0 until clip.itemCount) uris.add(clip.getItemAt(index).uri)
        } else {
            data.data?.let(uris::add)
        }
        Thread {
            val directory = File(activity.cacheDir, "travel_import").apply { mkdirs() }
            val paths = uris.mapIndexedNotNull { index, uri -> copyPhoto(uri, directory, index) }
            mainHandler.post { result.success(paths) }
        }.start()
        return true
    }

    private fun copyPhoto(uri: Uri, directory: File, index: Int): String? {
        val name = displayName(uri)?.replace(Regex("[^A-Za-z0-9._-]"), "_") ?: "photo.jpg"
        val target = File(directory, "${System.currentTimeMillis()}_${index}_$name")
        for (source in listOf(originalUri(uri), uri).distinct()) {
            try {
                val input = activity.contentResolver.openInputStream(source) ?: continue
                input.use { stream -> target.outputStream().use { stream.copyTo(it) } }
                return target.absolutePath
            } catch (_: Exception) {
                // Fall back to the redacted stream if the original is refused.
            }
        }
        return null
    }

    private fun originalUri(uri: Uri): Uri {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return uri
        if (activity.checkSelfPermission(Manifest.permission.ACCESS_MEDIA_LOCATION) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            return uri
        }
        return try {
            val mediaUri = try {
                MediaStore.getMediaUri(activity, uri)
            } catch (_: Exception) {
                null
            }
            MediaStore.setRequireOriginal(mediaUri ?: uri)
        } catch (_: Exception) {
            uri
        }
    }

    private fun displayName(uri: Uri): String? = try {
        activity.contentResolver
            .query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            ?.use { cursor -> if (cursor.moveToFirst()) cursor.getString(0) else null }
    } catch (_: Exception) {
        null
    }

    companion object {
        private const val REQUEST_CODE = 0x7A71
    }
}
