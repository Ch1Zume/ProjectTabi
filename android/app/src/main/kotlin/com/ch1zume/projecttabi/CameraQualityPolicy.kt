package com.ch1zume.projecttabi

import kotlin.math.hypot

/** Only candidates exposed through CameraX or a public logical camera are considered. */
internal data class CameraLensCandidate(
    val cameraId: String,
    val physicalCameraId: String? = null,
    val relativeFocalLength: Double,
)

internal object CameraQualityPolicy {
    // Compare field of view, not focal length in mm across different sensor sizes.
    fun normalizedFocalLength(focalLength: Double, width: Double, height: Double): Double? {
        if (!focalLength.isFinite() || !width.isFinite() || !height.isFinite() ||
            focalLength <= 0 || width <= 0 || height <= 0
        ) return null
        return focalLength / hypot(width, height)
    }

    fun telephoto(candidates: List<CameraLensCandidate>): CameraLensCandidate? =
        candidates.filter { it.relativeFocalLength.isFinite() && it.relativeFocalLength > 1.5 }
            .maxWithOrNull(compareBy<CameraLensCandidate> { it.relativeFocalLength }
                .thenBy { it.physicalCameraId == null })

    fun enhancement(requested: String, supported: Set<String>): String = when (requested) {
        "auto" -> when {
            "auto" in supported -> "auto"
            "hdr" in supported -> "hdr"
            else -> "off"
        }
        "hdr", "night" -> if (requested in supported) requested else "off"
        else -> "off"
    }
}
