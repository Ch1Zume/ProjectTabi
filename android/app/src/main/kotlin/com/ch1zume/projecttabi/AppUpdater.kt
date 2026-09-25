package com.ch1zume.projecttabi

import android.app.DownloadManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.concurrent.Executors

/** System downloads survive process death; installation always verifies the APK again. */
class AppUpdater(private val activity: MainActivity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "projecttabi/updater")
    private val executor = Executors.newSingleThreadExecutor()
    private val prefs = activity.getSharedPreferences("app_updater", Context.MODE_PRIVATE)
    private val downloads = activity.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
    private val packageManager = activity.packageManager
    private var candidate = runCatching { JSONObject(prefs.getString("candidate", "")!!) }.getOrNull()
    private var downloadId = prefs.getLong("downloadId", -1)
    private var phase = "idle"
    private var problem: String? = null
    private var downloaded = 0L
    private var verified = false
    private var closed = false

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method != "command") {
                result.notImplemented()
            } else {
                executor.execute {
                    try {
                        when (call.argument<String>("action")) {
                            "check" -> check()
                            "download" -> download(call.argument<Boolean>("wifiOnly") == true)
                            "cancel" -> cancel()
                            "install" -> install()
                            "status" -> refresh()
                            else -> throw UpdateFailure("无法识别更新操作，请重新打开更新页面。")
                        }
                    } catch (error: Exception) {
                        problem = when (error) {
                            is UpdateFailure -> error.message
                            is java.net.SocketTimeoutException -> "更新服务器连接超时，请检查网络或稍后重试。"
                            is java.net.UnknownHostException -> "无法连接更新服务器，请检查网络后重试。"
                            is java.io.IOException -> "更新文件无法读写或下载，请检查网络和剩余空间后重试。"
                            else -> "更新操作未完成，请重试或使用手动下载。"
                        }
                        phase = if (verified) "ready" else "error"
                    }
                    val state = state()
                    activity.runOnUiThread { if (!closed) result.success(state) }
                }
            }
        }
    }

    fun close() {
        closed = true
        channel.setMethodCallHandler(null)
        executor.shutdown()
    }

    private fun installed(): PackageInfo = packageManager.getPackageInfo(activity.packageName, signingFlags())
    private fun code(info: PackageInfo): Long = if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()
    private fun signingFlags(): Int = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES
    private fun signatures(info: PackageInfo): Set<String> {
        val values = if (Build.VERSION.SDK_INT >= 28) info.signingInfo?.apkContentsSigners else info.signatures
        return values?.map { hex(MessageDigest.getInstance("SHA-256").digest(it.toByteArray())) }?.toSet() ?: emptySet()
    }

    private fun check() {
        refresh()
        if (phase in setOf("downloading", "waiting", "ready", "verifying")) return
        phase = "checking"
        problem = null
        val connection = URL(MANIFEST_URL).openConnection() as HttpURLConnection
        connection.connectTimeout = 15000
        connection.readTimeout = 20000
        connection.setRequestProperty("User-Agent", "ProjectTabi-Updater")
        connection.useCaches = false
        val manifest = try {
            if (connection.responseCode != 200) throw UpdateFailure("无法获取更新信息（HTTP ${connection.responseCode}），请稍后重试或手动下载。")
            val bytes = connection.inputStream.use { input ->
                val output = ByteArrayOutputStream()
                val buffer = ByteArray(8192)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    if (output.size() + count > 1024 * 1024) throw UpdateFailure("更新信息异常，请稍后重试。")
                    output.write(buffer, 0, count)
                }
                output.toByteArray()
            }
            JSONObject(String(bytes, Charsets.UTF_8))
        } finally { connection.disconnect() }
        val android = manifest.getJSONObject("android")
        val version = manifest.getString("version")
        val build = android.getLong("versionCode")
        val name = android.getString("versionName")
        if (!Regex("[0-9]+\\.[0-9]+\\.[0-9]+\\+[0-9]+").matches(version) ||
            version != "$name+$build" || !validUrl(android.getString("url")) ||
            !Regex("[a-f0-9]{64}").matches(android.getString("sha256")) ||
            android.getLong("size") !in 1L..MAX_APK_SIZE) {
            throw UpdateFailure("更新信息校验失败，请使用官方发布页面下载。")
        }
        val current = installed()
        if (build <= code(current) || compareName(name, current.versionName ?: "0.0.0") < 0) {
            clearDownload()
            candidate = null
            prefs.edit().remove("candidate").apply()
            phase = "current"
            return
        }
        clearDownload()
        candidate = JSONObject(android.toString()).put("version", version).put("notes", manifest.optString("notes"))
        prefs.edit().putString("candidate", candidate.toString()).commit()
        phase = "available"
    }

    private fun compareName(a: String, b: String): Int {
        val left = a.split('.').map { it.toLongOrNull() ?: 0 }
        val right = b.split('.').map { it.toLongOrNull() ?: 0 }
        for (i in 0..2) {
            val delta = (left.getOrElse(i) { 0L }).compareTo(right.getOrElse(i) { 0L })
            if (delta != 0) return delta
        }
        return 0
    }

    private fun apkFile(): File {
        val root = activity.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)
            ?: throw UpdateFailure("无法访问下载目录，请检查可用存储空间。")
        val directory = File(root, "updates")
        if (!directory.isDirectory && !directory.mkdirs()) throw UpdateFailure("无法创建下载目录，请检查可用存储空间。")
        return File(directory, "ProjectTabi-${candidate!!.getLong("versionCode")}.apk")
    }

    private fun download(wifiOnly: Boolean) {
        if (phase != "error") refresh()
        if (phase in setOf("downloading", "waiting", "ready", "verifying")) return
        val update = candidate ?: throw UpdateFailure("请先检查更新。")
        if (!validUrl(update.getString("url"))) throw UpdateFailure("更新地址无效，请重新检查更新。")
        clearDownload()
        val file = apkFile()
        if (file.exists() && !file.delete()) throw UpdateFailure("无法清理旧下载，请检查可用存储空间后重试。")
        val request = DownloadManager.Request(Uri.parse(update.getString("url")))
            .setTitle("ProjectTabi ${update.getString("version")}")
            .setDescription("应用更新，下载后请返回 ProjectTabi 安装")
            .setMimeType("application/vnd.android.package-archive")
            .setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
            .setAllowedOverRoaming(false)
            .setDestinationUri(Uri.fromFile(file))
        if (wifiOnly) {
            request.setAllowedNetworkTypes(DownloadManager.Request.NETWORK_WIFI)
            request.setAllowedOverMetered(false)
        }
        downloadId = downloads.enqueue(request)
        prefs.edit().putLong("downloadId", downloadId).commit()
        phase = "downloading"
        problem = null
    }

    private fun refresh() {
        val update = candidate ?: return
        if (update.optLong("versionCode") <= code(installed())) {
            clearDownload()
            candidate = null
            prefs.edit().remove("candidate").apply()
            phase = "current"
            return
        }
        if (downloadId < 0) {
            if (phase == "idle") phase = "available"
            return
        }
        downloads.query(DownloadManager.Query().setFilterById(downloadId)).use { cursor ->
            if (!cursor.moveToFirst()) {
                clearDownload()
                phase = "available"
                problem = "下载任务已被移除，请重新下载。"
                return
            }
            downloaded = cursor.getLong(cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR)).coerceAtLeast(0)
            when (cursor.getInt(cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS))) {
                DownloadManager.STATUS_PENDING, DownloadManager.STATUS_PAUSED -> phase = "waiting"
                DownloadManager.STATUS_RUNNING -> phase = "downloading"
                DownloadManager.STATUS_SUCCESSFUL -> {
                    if (!verified) {
                        phase = "verifying"
                        verifyApk()
                        verified = true
                    }
                    phase = "ready"
                }
                DownloadManager.STATUS_FAILED -> {
                    val reason = cursor.getInt(cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_REASON))
                    phase = "error"
                    problem = when (reason) {
                        DownloadManager.ERROR_INSUFFICIENT_SPACE -> "空间不足，请释放空间后重新下载。"
                        DownloadManager.ERROR_DEVICE_NOT_FOUND -> "下载存储不可用，请检查存储后重试。"
                        else -> "下载失败（代码 $reason），请检查网络后重试或手动下载。"
                    }
                }
            }
        }
    }

    private fun verifyApk() {
        verified = false
        val update = candidate ?: throw UpdateFailure("请重新检查更新。")
        val file = apkFile()
        if (!file.isFile || file.length() != update.getLong("size")) throw UpdateFailure("安装包不完整，请取消后重新下载。")
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(65536)
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                digest.update(buffer, 0, read)
            }
        }
        if (hex(digest.digest()) != update.getString("sha256")) throw UpdateFailure("安装包校验失败，请取消后重新下载。")
        val archive = packageManager.getPackageArchiveInfo(file.absolutePath, signingFlags())
            ?: throw UpdateFailure("无法识别安装包，请重新下载。")
        val current = installed()
        if (archive.packageName != activity.packageName ||
            code(archive) != update.getLong("versionCode") || code(archive) <= code(current) ||
            archive.versionName != update.getString("versionName") ||
            signatures(archive).isEmpty() || signatures(archive) != signatures(current)) {
            throw UpdateFailure("安装包身份、版本或签名不匹配，已停止安装。请使用官方发布页面。")
        }
    }

    private fun install() {
        refresh()
        if (phase != "ready") throw UpdateFailure("请先完成更新包下载与校验。")
        verifyApk()
        verified = true
        problem = null
        if (Build.VERSION.SDK_INT >= 26 && !packageManager.canRequestPackageInstalls()) {
            problem = "请允许 ProjectTabi 安装应用，返回后再次点击“安装更新”。"
            activity.runOnUiThread {
                runCatching { activity.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${activity.packageName}"))) }
            }
            return
        }
        val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.updates", apkFile())
        activity.runOnUiThread {
            try {
                activity.startActivity(Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(uri, "application/vnd.android.package-archive")
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                })
            } catch (_: Exception) {
                // Report on the next status poll without exposing a platform exception.
                executor.execute { problem = "无法打开系统安装器，请使用手动下载入口安装。" }
            }
        }
    }

    private fun cancel() {
        clearDownload()
        problem = null
        phase = if (candidate == null) "idle" else "available"
    }

    private fun clearDownload() {
        if (downloadId >= 0) downloads.remove(downloadId)
        downloadId = -1
        downloaded = 0
        verified = false
        prefs.edit().remove("downloadId").apply()
    }

    private fun state(): Map<String, Any?> = mapOf(
        "supported" to true, "phase" to phase, "error" to problem,
        "version" to candidate?.optString("version"), "notes" to candidate?.optString("notes"),
        "downloaded" to downloaded, "total" to (candidate?.optLong("size") ?: 0),
    )

    private fun validUrl(value: String): Boolean {
        val uri = Uri.parse(value)
        return uri.scheme == "https" && uri.host == "github.com" &&
            uri.path?.startsWith("/Ch1Zume/ProjectTabi/releases/download/") == true &&
            uri.userInfo == null && uri.port == -1 && uri.query == null && uri.fragment == null
    }
    private fun hex(bytes: ByteArray) = bytes.joinToString("") { "%02x".format(it) }
    private class UpdateFailure(message: String) : Exception(message)
    companion object {
        const val MANIFEST_URL = "https://github.com/Ch1Zume/ProjectTabi/releases/latest/download/latest.json"
        const val MAX_APK_SIZE = 1024L * 1024 * 1024
    }
}
