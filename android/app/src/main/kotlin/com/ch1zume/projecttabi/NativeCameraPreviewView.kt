package com.ch1zume.projecttabi

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.CaptureResult
import android.hardware.camera2.TotalCaptureResult
import android.location.Location
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Rational
import android.view.MotionEvent
import android.view.Surface
import android.view.View
import androidx.camera.core.AspectRatio
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.FocusMeteringAction
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.camera.core.Preview
import androidx.camera.camera2.interop.Camera2CameraInfo
import androidx.camera.camera2.interop.Camera2Interop
import androidx.camera.core.resolutionselector.AspectRatioStrategy
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.extensions.ExtensionMode
import androidx.camera.extensions.ExtensionsManager
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import androidx.exifinterface.media.ExifInterface
import androidx.lifecycle.LifecycleOwner
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.platform.PlatformView
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

private enum class NativeLensMode(val value: String) {
    BackAuto("backAuto"),
    BackTelephoto("backTelephoto"),
    Front("front"),
}

class NativeCameraPreviewView(
    private val activity: MainActivity,
    private val context: Context,
    messenger: BinaryMessenger,
    viewId: Int,
) : PlatformView, MethodChannel.MethodCallHandler {
    private val previewView = PreviewView(context)
    private val channel = MethodChannel(messenger, "seichi/native_camera_preview_$viewId")
    private val executor: ExecutorService = Executors.newSingleThreadExecutor()

    private var cameraProvider: ProcessCameraProvider? = null
    private var camera: Camera? = null
    private var imageCapture: ImageCapture? = null
    private var preview: Preview? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private var initializationGeneration = 0
    private var captureGeneration = 0
    private var pendingCapture: MethodChannel.Result? = null
    private var captureTimeout: Runnable? = null
    private var lensMode = NativeLensMode.BackAuto
    private var telephotoCamera: CameraLensCandidate? = null
    private var extensionsManager: ExtensionsManager? = null
    private var requestedEnhancement = "auto"
    private var activeEnhancement = "off"
    private var supportedEnhancements = emptySet<String>()
    private val failedExtensions = mutableSetOf<String>()
    private var qualityNotice = ""
    private var lastIssue = ""
    private var lastCaptureSize = ""
    @Volatile private var reportedPhysicalCamera = "系统未提供"
    @Volatile private var reportedFocalLength = "系统未提供"
    private var disposed = false
    private var captureInProgress = false
    private var flashMode = ImageCapture.FLASH_MODE_AUTO
    private var targetAspectRatio = 1.0
    private var cropCaptureToAspectRatio = true

    init {
        previewView.scaleType = PreviewView.ScaleType.FILL_CENTER
        previewView.implementationMode = PreviewView.ImplementationMode.COMPATIBLE
        previewView.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ ->
            val rotation = previewView.display?.rotation ?: Surface.ROTATION_0
            preview?.targetRotation = rotation
            imageCapture?.targetRotation = rotation
        }
        previewView.setOnTouchListener { _, event ->
            if (event.action == MotionEvent.ACTION_UP) {
                focusAt(event.x, event.y)
            }
            true
        }
        channel.setMethodCallHandler(this)
    }

    override fun getView(): View = previewView

    override fun dispose() {
        if (disposed) return
        disposed = true
        initializationGeneration++
        channel.setMethodCallHandler(null)
        finishPendingCapture("camera_closed", "拍摄页面已关闭。")
        releaseUseCases()
        executor.shutdown()
    }

    private fun releaseUseCases() {
        // A Flutter layout change can dispose an old view after its replacement binds.
        // Release only this view's use cases, never the provider's other cameras.
        val owned = listOfNotNull(preview, imageCapture)
        if (owned.isNotEmpty()) cameraProvider?.unbind(*owned.toTypedArray())
        preview = null
        imageCapture = null
        camera = null
        if (activeView === this) activeView = null
    }

    private fun finishPendingCapture(code: String, message: String) {
        captureTimeout?.let(mainHandler::removeCallbacks)
        captureTimeout = null
        captureGeneration++
        captureInProgress = false
        val result = pendingCapture
        pendingCapture = null
        result?.error(code, message, null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (disposed) {
            result.error("camera_closed", "拍摄页面已关闭，请重新打开。", null)
            return
        }
        if (captureInProgress && call.method !in setOf("getZoomState", "dispose")) {
            result.error("camera_busy", "照片正在处理中，请稍后再操作。", null)
            return
        }
        when (call.method) {
            "initialize" -> initialize(call, result)
            "getZoomState" -> result.success(zoomStateMap())
            "setZoomRatio" -> setZoomRatio(call, result)
            "setTargetAspectRatio" -> setTargetAspectRatio(call, result)
            "setCropCaptureToAspectRatio" -> setCropCaptureToAspectRatio(call, result)
            "setFlashMode" -> setFlashMode(call, result)
            "switchCamera" -> switchCamera(result)
            "switchLens" -> switchLens(result)
            "setEnhancementMode" -> setEnhancementMode(call, result)
            "takePicture" -> try {
                takePicture(call, result)
            } catch (error: Exception) {
                if (pendingCapture === result) {
                    finishPendingCapture("capture_failed", "照片拍摄失败，请检查剩余存储空间后重试。")
                } else {
                    captureInProgress = false
                    result.error("capture_failed", "照片拍摄失败，请检查剩余存储空间后重试。", null)
                }
            }
            "writePhotoLocation" -> writePhotoLocation(call, result)
            "dispose" -> {
                dispose()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun initialize(call: MethodCall, result: MethodChannel.Result) {
        val generation = ++initializationGeneration
        targetAspectRatio = sanitizedAspectRatio(
            call.argument<Double>("targetAspectRatio") ?: targetAspectRatio,
        )
        cropCaptureToAspectRatio = call.argument<Boolean>("cropCaptureToAspectRatio") ?: cropCaptureToAspectRatio
        requestedEnhancement = (call.argument<String>("enhancementMode") ?: requestedEnhancement)
            .takeIf { it in setOf("auto", "hdr", "night", "off") } ?: "auto"
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
            result.error("camera_permission_denied", "Camera permission is not granted.", null)
            return
        }

        val providerFuture = ProcessCameraProvider.getInstance(context)
        providerFuture.addListener(
            {
                if (disposed || generation != initializationGeneration) {
                    result.error("camera_closed", "相机连接已更新。", null)
                    return@addListener
                }
                try {
                    cameraProvider = providerFuture.get()
                    telephotoCamera = findTelephotoCamera()
                    initializeExtensions(result, generation)
                } catch (error: Exception) {
                    result.error("camera_initialize_failed", "相机启动失败，请关闭其他占用相机的应用后重试。", null)
                }
            },
            ContextCompat.getMainExecutor(context),
        )
    }

    private fun initializeExtensions(result: MethodChannel.Result, generation: Int) {
        val provider = cameraProvider ?: return
        fun finish() {
            if (disposed || generation != initializationGeneration) {
                result.error("camera_closed", "拍摄页面已关闭。", null)
                return
            }
            try {
                bindCamera()
                result.success(zoomStateMap())
            } catch (error: Exception) {
                result.error("camera_initialize_failed", "相机启动失败，请关闭其他占用相机的应用后重试。", null)
            }
        }
        try {
            val future = ExtensionsManager.getInstanceAsync(context, provider)
            future.addListener({
                try {
                    extensionsManager = future.get()
                } catch (error: Exception) {
                    lastIssue = "增强接口初始化失败：${error.javaClass.simpleName}"
                }
                finish()
            }, ContextCompat.getMainExecutor(context))
        } catch (error: Exception) {
            lastIssue = "增强接口不可用：${error.javaClass.simpleName}"
            finish()
        }
    }

    private fun bindCamera(zoom: Float = camera?.cameraInfo?.zoomState?.value?.zoomRatio ?: 1.0f) {
        val provider = cameraProvider ?: return
        val selector = cameraSelectorForLensMode(lensMode)
        val manager = extensionsManager
        // OEM extensions own their stream configuration. Do not let them silently replace
        // an explicitly selected physical telephoto with its parent logical camera.
        val pinnedPhysical = lensMode == NativeLensMode.BackTelephoto && telephotoCamera?.physicalCameraId != null
        supportedEnhancements = if (manager == null || pinnedPhysical) emptySet() else {
            enhancementModes.filter { (name, mode) ->
                extensionKey(name) !in failedExtensions &&
                    runCatching { manager.isExtensionAvailable(selector, mode) }.getOrDefault(false)
            }.keys
        }
        activeEnhancement = CameraQualityPolicy.enhancement(requestedEnhancement, supportedEnhancements)
        qualityNotice = when {
            requestedEnhancement == "off" -> "已关闭画质增强，使用标准拍摄。"
            pinnedPhysical -> "已指定长焦镜头；此模式使用标准拍摄。"
            activeEnhancement == "off" -> "当前镜头未提供可用增强，使用画质优先拍摄。"
            else -> ""
        }
        try {
            val enhancedSelector = if (activeEnhancement != "off" && manager != null) {
                manager.getExtensionEnabledCameraSelector(selector, enhancementModes.getValue(activeEnhancement))
            } else selector
            bindUseCases(provider, enhancedSelector, zoom)
        } catch (error: Exception) {
            if (activeEnhancement == "off") throw error
            failedExtensions.add(extensionKey(activeEnhancement))
            supportedEnhancements = supportedEnhancements - activeEnhancement
            activeEnhancement = "off"
            qualityNotice = "画质增强启动失败，已恢复标准拍摄；可重新打开拍摄页重试。"
            lastIssue = "增强启动失败：${error.javaClass.simpleName}"
            bindUseCases(provider, selector, zoom)
        }
    }

    private fun bindUseCases(provider: ProcessCameraProvider, selector: CameraSelector, zoom: Float) {
        if (disposed) throw IllegalStateException("Camera view is closed")
        if (activeView !== this) activeView?.releaseUseCases()
        releaseUseCases()
        activeView = this
        val rotation = previewView.display?.rotation ?: Surface.ROTATION_0
        reportedPhysicalCamera = "系统未提供"
        reportedFocalLength = "系统未提供"
        val previewBuilder = Preview.Builder()
            .setTargetAspectRatio(cameraTargetAspectRatio())
            .setTargetRotation(rotation)
        if (activeEnhancement == "off") {
            Camera2Interop.Extender(previewBuilder).setSessionCaptureCallback(
                object : CameraCaptureSession.CaptureCallback() {
                    override fun onCaptureCompleted(session: CameraCaptureSession, request: CaptureRequest, result: TotalCaptureResult) {
                        reportedFocalLength = result.get(CaptureResult.LENS_FOCAL_LENGTH)?.toString() ?: "系统未提供"
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                            reportedPhysicalCamera = result.get(CaptureResult.LOGICAL_MULTI_CAMERA_ACTIVE_PHYSICAL_ID) ?: "系统未提供"
                        }
                    }
                },
            )
        }
        val nextPreview = previewBuilder.build()
            .also {
                it.setSurfaceProvider(previewView.surfaceProvider)
            }
        val nextCapture = ImageCapture.Builder()
            .setCaptureMode(ImageCapture.CAPTURE_MODE_MAXIMIZE_QUALITY)
            .setJpegQuality(100)
            .setTargetRotation(rotation)
            .setResolutionSelector(ResolutionSelector.Builder()
                .setAspectRatioStrategy(AspectRatioStrategy(cameraTargetAspectRatio(), AspectRatioStrategy.FALLBACK_RULE_AUTO))
                .setResolutionStrategy(ResolutionStrategy.HIGHEST_AVAILABLE_STRATEGY)
                .build())
            .setFlashMode(flashMode)
            .build()

        preview = nextPreview
        imageCapture = nextCapture
        camera = provider.bindToLifecycle(
            activity as LifecycleOwner,
            selector,
            nextPreview,
            nextCapture,
        )
        val zoomState = camera?.cameraInfo?.zoomState?.value
        camera?.cameraControl?.setZoomRatio(zoom.coerceIn(zoomState?.minZoomRatio ?: 1f, zoomState?.maxZoomRatio ?: 1f))
    }

    private fun extensionKey(mode: String) = "${lensMode.value}:$mode"

    private fun setEnhancementMode(call: MethodCall, result: MethodChannel.Result) {
        val mode = call.argument<String>("mode") ?: "auto"
        if (mode !in setOf("auto", "hdr", "night", "off")) {
            result.error("invalid_enhancement", "请选择有效的画质模式。", null)
            return
        }
        val previous = requestedEnhancement
        requestedEnhancement = mode
        try {
            bindCamera()
            result.success(zoomStateMap())
        } catch (error: Exception) {
            requestedEnhancement = previous
            runCatching { bindCamera() }
            result.error("camera_enhancement_failed", "画质模式切换失败，请重新打开拍摄页面。", null)
        }
    }

    private val enhancementModes = mapOf("auto" to ExtensionMode.AUTO, "hdr" to ExtensionMode.HDR, "night" to ExtensionMode.NIGHT)

    private fun setZoomRatio(call: MethodCall, result: MethodChannel.Result) {
        val requested = ((call.argument<Double>("zoomRatio") ?: 1.0) / zoomScale()).toFloat()
        val state = camera?.cameraInfo?.zoomState?.value
        val minZoom = if (lensMode == NativeLensMode.BackTelephoto) max(1f, state?.minZoomRatio ?: 1f) else state?.minZoomRatio ?: 1f
        val maxZoom = state?.maxZoomRatio ?: 1.0f
        val nextZoom = min(max(requested, minZoom), maxZoom)
        val future = camera?.cameraControl?.setZoomRatio(nextZoom)
        if (future == null) {
            result.error("camera_not_ready", "相机尚未就绪，请稍后再试。", null)
            return
        }
        future.addListener({
            // A newer slider event can cancel an older zoom request.
            runCatching { future.get() }
            result.success(zoomStateMap())
        }, ContextCompat.getMainExecutor(context))
    }

    private fun setTargetAspectRatio(call: MethodCall, result: MethodChannel.Result) {
        val previous = targetAspectRatio
        val previousStreamRatio = cameraTargetAspectRatio()
        targetAspectRatio = sanitizedAspectRatio(
            call.argument<Double>("targetAspectRatio") ?: targetAspectRatio,
        )
        try {
            if (cameraProvider != null && previousStreamRatio != cameraTargetAspectRatio()) {
                bindCamera()
            }
            result.success(null)
        } catch (error: Exception) {
            targetAspectRatio = previous
            runCatching { bindCamera() }
            result.error("camera_ratio_failed", "照片比例设置失败，请重新打开拍摄页面。", null)
        }
    }

    private fun setCropCaptureToAspectRatio(call: MethodCall, result: MethodChannel.Result) {
        val enabled = call.argument<Boolean>("enabled") ?: cropCaptureToAspectRatio
        val resetCrop = cropCaptureToAspectRatio && !enabled
        cropCaptureToAspectRatio = enabled
        if (resetCrop) {
            try { bindCamera() } catch (_: Exception) {
                result.error("camera_ratio_failed", "照片比例设置失败，请重连相机后重试。", null)
                return
            }
        }
        result.success(null)
    }

    private fun setFlashMode(call: MethodCall, result: MethodChannel.Result) {
        when (call.argument<String>("flashMode") ?: "auto") {
            "off" -> {
                flashMode = ImageCapture.FLASH_MODE_OFF
                camera?.cameraControl?.enableTorch(false)
            }
            "on" -> {
                flashMode = ImageCapture.FLASH_MODE_ON
                camera?.cameraControl?.enableTorch(false)
            }
            "torch" -> {
                flashMode = ImageCapture.FLASH_MODE_OFF
                camera?.cameraControl?.enableTorch(true)
            }
            else -> {
                flashMode = ImageCapture.FLASH_MODE_AUTO
                camera?.cameraControl?.enableTorch(false)
            }
        }
        imageCapture?.flashMode = flashMode
        result.success(zoomStateMap())
    }

    private fun switchCamera(result: MethodChannel.Result) {
        switchLens(result)
    }

    private fun switchLens(result: MethodChannel.Result) {
        val previousMode = lensMode
        lensMode = nextLensMode()
        try {
            bindCamera(1.0f)
            result.success(zoomStateMap())
        } catch (error: Exception) {
            if (lensMode == NativeLensMode.BackTelephoto) telephotoCamera = null
            lensMode = NativeLensMode.BackAuto
            try {
                bindCamera()
            } catch (_: Exception) {
                lensMode = previousMode
            }
            lastIssue = "镜头切换失败：${error.javaClass.simpleName}"
            result.error("camera_switch_failed", "这颗镜头暂时无法使用，已尝试恢复后置相机。", null)
        }
    }

    private fun takePicture(call: MethodCall, result: MethodChannel.Result) {
        val capture = imageCapture
        if (capture == null) {
            result.error("camera_not_ready", "相机尚未就绪，请稍后再试。", null)
            return
        }

        val directory = File(context.filesDir, "visit_record_images")
        if (!directory.exists()) {
            directory.mkdirs()
        }
        val timestamp = SimpleDateFormat("yyyyMMdd_HHmmss_SSS", Locale.US).format(Date())
        val file = File(directory, "native_camera_$timestamp.jpg")
        val location = locationFromCall(call)
        val metadata = ImageCapture.Metadata().apply {
            this.location = location
        }
        val outputOptions = ImageCapture.OutputFileOptions.Builder(file)
            .setMetadata(metadata)
            .build()
        capture.targetRotation = previewView.display?.rotation ?: Surface.ROTATION_0
        if (cropCaptureToAspectRatio) {
            capture.setCropAspectRatio(Rational((targetAspectRatio * 10000).toInt(), 10000))
        }
        captureInProgress = true
        pendingCapture = result
        val generation = ++captureGeneration
        captureTimeout = Runnable {
            if (generation == captureGeneration && pendingCapture != null) {
                lastIssue = "拍摄超时"
                finishPendingCapture("capture_timeout", "相机处理超时，已尝试恢复预览，请重试或在设置中改用标准画质。")
                runCatching { bindCamera() }
            }
        }.also { mainHandler.postDelayed(it, 60000) }
        capture.takePicture(
            outputOptions,
            executor,
            object : ImageCapture.OnImageSavedCallback {
                override fun onImageSaved(outputFileResults: ImageCapture.OutputFileResults) {
                    // CameraX applies the requested crop and EXIF orientation. Preserve its
                    // output bytes: decoding and re-encoding here used to lose JPEG detail.
                    val size = runCatching {
                        val exif = ExifInterface(file.absolutePath)
                        "${exif.getAttribute(ExifInterface.TAG_IMAGE_WIDTH)} × ${exif.getAttribute(ExifInterface.TAG_IMAGE_LENGTH)}"
                    }.getOrDefault("")
                    activity.runOnUiThread {
                        if (disposed || generation != captureGeneration) return@runOnUiThread
                        captureTimeout?.let(mainHandler::removeCallbacks)
                        captureTimeout = null
                        pendingCapture = null
                        captureInProgress = false
                        lastCaptureSize = size
                        result.success(file.absolutePath)
                    }
                }

                override fun onError(exception: ImageCaptureException) {
                    activity.runOnUiThread {
                        if (disposed || generation != captureGeneration) return@runOnUiThread
                        captureTimeout?.let(mainHandler::removeCallbacks)
                        captureTimeout = null
                        pendingCapture = null
                        captureInProgress = false
                        lastIssue = "拍摄失败：${exception.imageCaptureError}"
                        result.error("capture_failed", "照片未能保存，请检查剩余存储空间后重试；增强模式下可切换标准模式再拍。", null)
                    }
                }
            },
        )
    }

    private fun writePhotoLocation(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        val location = locationFromCall(call)
        if (path.isNullOrBlank() || location == null) {
            result.error("invalid_photo_location", "Photo path or location is invalid.", null)
            return
        }
        executor.execute {
            try {
                val file = File(path)
                if (!file.isFile) {
                    throw IllegalArgumentException("Photo file does not exist.")
                }
                ExifInterface(file.absolutePath).apply {
                    setGpsInfo(location)
                    saveAttributes()
                }
                activity.runOnUiThread { result.success(true) }
            } catch (error: Exception) {
                activity.runOnUiThread {
                    result.error("photo_location_write_failed", error.message, null)
                }
            }
        }
    }

    private fun locationFromCall(call: MethodCall): Location? {
        val latitude = (call.argument<Number>("latitude") ?: return null).toDouble()
        val longitude = (call.argument<Number>("longitude") ?: return null).toDouble()
        if (!latitude.isFinite() || !longitude.isFinite() ||
            latitude !in -90.0..90.0 || longitude !in -180.0..180.0
        ) {
            return null
        }
        return Location("ProjectTabi").apply {
            this.latitude = latitude
            this.longitude = longitude
            (call.argument<Number>("accuracy")?.toFloat())?.let {
                if (it.isFinite() && it >= 0f) accuracy = it
            }
            (call.argument<Number>("altitude")?.toDouble())?.let {
                if (it.isFinite()) altitude = it
            }
            time = call.argument<Number>("locationTimestampMillis")?.toLong()
                ?: System.currentTimeMillis()
        }
    }

    private fun focusAt(x: Float, y: Float) {
        val currentCamera = camera ?: return
        val point = previewView.meteringPointFactory.createPoint(x, y)
        val action = FocusMeteringAction.Builder(point, FocusMeteringAction.FLAG_AF or FocusMeteringAction.FLAG_AE)
            .setAutoCancelDuration(3, java.util.concurrent.TimeUnit.SECONDS)
            .build()
        currentCamera.cameraControl.startFocusAndMetering(action)
    }

    private fun sanitizedAspectRatio(value: Double): Double {
        return value.coerceIn(0.2, 5.0)
    }

    private fun cameraTargetAspectRatio(): Int {
        val normalized = if (targetAspectRatio >= 1.0) targetAspectRatio else 1.0 / targetAspectRatio
        return if (abs(normalized - 16.0 / 9.0) < abs(normalized - 4.0 / 3.0)) {
            AspectRatio.RATIO_16_9
        } else {
            AspectRatio.RATIO_4_3
        }
    }

    private fun cameraSelectorForLensMode(mode: NativeLensMode): CameraSelector {
        if (mode == NativeLensMode.Front) return CameraSelector.DEFAULT_FRONT_CAMERA
        val tele = telephotoCamera
        if (mode != NativeLensMode.BackTelephoto || tele == null) {
            return CameraSelector.DEFAULT_BACK_CAMERA
        }
        return CameraSelector.Builder()
            .addCameraFilter { infos ->
                infos.filter { Camera2CameraInfo.from(it).cameraId == tele.cameraId }
            }
            .apply { tele.physicalCameraId?.let { setPhysicalCameraId(it) } }
            .build()
    }

    private fun nextLensMode(): NativeLensMode = when (lensMode) {
        NativeLensMode.BackAuto ->
            if (telephotoCamera != null) NativeLensMode.BackTelephoto else NativeLensMode.Front
        NativeLensMode.BackTelephoto -> NativeLensMode.Front
        NativeLensMode.Front -> NativeLensMode.BackAuto
    }

    private fun findTelephotoCamera(): CameraLensCandidate? {
        val provider = cameraProvider ?: return null
        val manager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        return try {
            val infos = CameraSelector.DEFAULT_BACK_CAMERA.filter(provider.availableCameraInfos)
            val default = infos.firstOrNull() ?: return null
            val defaultId = Camera2CameraInfo.from(default).cameraId
            val mainFocal = normalizedFocalLength(manager, defaultId) ?: return null
            val candidates = mutableListOf<CameraLensCandidate>()
            for (info in infos) {
                val id = Camera2CameraInfo.from(info).cameraId
                val relative = normalizedFocalLength(manager, id)?.div(mainFocal)
                if (id != defaultId && relative != null) {
                    candidates.add(CameraLensCandidate(id, relativeFocalLength = relative))
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                    val physicalIds = runCatching {
                        manager.getCameraCharacteristics(id).physicalCameraIds
                    }.getOrDefault(emptySet())
                    for (physicalId in physicalIds) {
                        val physicalFocal = normalizedFocalLength(manager, physicalId) ?: continue
                        candidates.add(CameraLensCandidate(id, physicalId, physicalFocal / mainFocal))
                    }
                }
            }
            CameraQualityPolicy.telephoto(candidates)
        } catch (error: Exception) {
            lastIssue = "镜头检测失败：${error.javaClass.simpleName}"
            null
        }
    }

    private fun normalizedFocalLength(manager: CameraManager, id: String): Double? = runCatching {
        val characteristics = manager.getCameraCharacteristics(id)
        val focal = characteristics.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)
            ?.minOrNull()?.toDouble() ?: return@runCatching null
        val size = characteristics.get(CameraCharacteristics.SENSOR_INFO_PHYSICAL_SIZE) ?: return@runCatching null
        CameraQualityPolicy.normalizedFocalLength(focal, size.width.toDouble(), size.height.toDouble())
    }.getOrNull()

    private fun zoomScale(): Double =
        if (lensMode == NativeLensMode.BackTelephoto) telephotoCamera?.relativeFocalLength ?: 1.0 else 1.0

    private fun qualityStateMap(): Map<String, Any> {
        val cameraId = runCatching {
            camera?.cameraInfo?.let { Camera2CameraInfo.from(it).cameraId }
        }.getOrNull() ?: "系统未提供"
        val lens = when (lensMode) {
            NativeLensMode.BackTelephoto -> "长焦"
            NativeLensMode.Front -> "前置"
            NativeLensMode.BackAuto -> "后置自动"
        }
        val resolution = imageCapture?.resolutionInfo?.resolution
        val outputSize = resolution?.let { "${it.width} × ${it.height}" } ?: "等待相机就绪"
        return mapOf(
            "requestedMode" to requestedEnhancement,
            "activeMode" to activeEnhancement,
            "availableModes" to supportedEnhancements.toList(),
            "lensLabel" to lens,
            "telephotoAvailable" to (telephotoCamera != null),
            "notice" to qualityNotice,
            "outputSize" to outputSize,
            "diagnostics" to listOf(
                "ProjectTabi / CameraX 1.6.2",
                "设备: ${Build.MANUFACTURER} ${Build.MODEL}",
                "Android: ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})",
                "系统版本: ${Build.DISPLAY}",
                "镜头: $lens / cameraId=$cameraId",
                "独立长焦: ${telephotoCamera ?: "未检测到可访问镜头"}",
                "当前物理镜头: ${if (lensMode == NativeLensMode.BackTelephoto) telephotoCamera?.physicalCameraId ?: "独立相机" else "由系统选择"}",
                "系统报告的活动物理镜头: $reportedPhysicalCamera / 报告焦距(mm): $reportedFocalLength",
                "增强请求: $requestedEnhancement / 实际: $activeEnhancement",
                "可用增强: ${supportedEnhancements.joinToString().ifEmpty { "无" }}",
                "变焦: ${camera?.cameraInfo?.zoomState?.value?.zoomRatio} / 光学倍率估计: ${zoomScale()}",
                "拍摄流尺寸: $outputSize / 最近照片: $lastCaptureSize",
                "参考图裁剪: $cropCaptureToAspectRatio / 比例: $targetAspectRatio",
                "状态: $qualityNotice",
                "最近问题: $lastIssue",
            ).joinToString("\n"),
        )
    }

    private fun zoomStateMap(): Map<String, Any> {
        val state = camera?.cameraInfo?.zoomState?.value
        val minZoom = if (lensMode == NativeLensMode.BackTelephoto) max(1f, state?.minZoomRatio ?: 1f) else state?.minZoomRatio ?: 1f
        val maxZoom = state?.maxZoomRatio ?: 1.0f
        val zoom = state?.zoomRatio ?: 1.0f
        val scale = zoomScale()
        return mapOf(
            "ready" to (camera != null && imageCapture != null),
            "minZoomRatio" to minZoom * scale,
            "maxZoomRatio" to maxZoom * scale,
            "zoomRatio" to zoom * scale,
            "lensFacing" to if (lensMode == NativeLensMode.Front) "front" else "back",
            "lensMode" to lensMode.value,
            "supportsTelephoto" to (telephotoCamera != null),
            "quality" to qualityStateMap(),
        )
    }

    companion object {
        // Accessed only on the main thread; explicitly cleared on view disposal.
        private var activeView: NativeCameraPreviewView? = null
    }
}
