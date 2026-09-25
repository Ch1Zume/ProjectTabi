package com.ch1zume.projecttabi

import org.junit.Assert.*
import org.junit.Test

class CameraQualityPolicyTest {
    @Test fun findsStandaloneTelephotoWithoutALogicalCamera() {
        // Previously the longest focal length was also used as the main-camera baseline,
        // which made it impossible for any standalone camera to qualify as telephoto.
        val tele = CameraLensCandidate("2", relativeFocalLength = 3.0)
        assertEquals(tele, CameraQualityPolicy.telephoto(listOf(
            CameraLensCandidate("0", relativeFocalLength = 1.0),
            CameraLensCandidate("1", relativeFocalLength = 0.6), tele,
        )))
    }

    @Test fun findsTelephotoInsideAPublicLogicalCamera() {
        val physical = CameraLensCandidate("0", "3", 3.0)
        assertEquals(physical, CameraQualityPolicy.telephoto(listOf(
            CameraLensCandidate("0", "1", 1.0), physical,
        )))
    }

    @Test fun usesSensorSizeWhenComparingDifferentLenses() {
        val main = CameraQualityPolicy.normalizedFocalLength(8.0, 10.0, 7.5)!!
        val sameFieldOfView = CameraQualityPolicy.normalizedFocalLength(4.0, 5.0, 3.75)!!
        assertEquals(main, sameFieldOfView, 0.00001)
        assertNull(CameraQualityPolicy.telephoto(listOf(
            CameraLensCandidate("1", relativeFocalLength = sameFieldOfView / main),
        )))
        assertNull(CameraQualityPolicy.normalizedFocalLength(8.0, 0.0, 7.5))
    }

    @Test fun doesNotInventTelephotoFromMissingMetadata() {
        assertNull(CameraQualityPolicy.telephoto(emptyList()))
        assertNull(CameraQualityPolicy.telephoto(listOf(
            CameraLensCandidate("0", relativeFocalLength = Double.NaN),
            CameraLensCandidate("1", relativeFocalLength = 1.0),
        )))
    }

    @Test fun prefersAvailableAutomaticEnhancementAndFallsBackSafely() {
        assertEquals("auto", CameraQualityPolicy.enhancement("auto", setOf("auto", "hdr")))
        assertEquals("hdr", CameraQualityPolicy.enhancement("auto", setOf("hdr")))
        assertEquals("off", CameraQualityPolicy.enhancement("auto", setOf("night")))
        assertEquals("off", CameraQualityPolicy.enhancement("hdr", emptySet()))
        assertEquals("night", CameraQualityPolicy.enhancement("night", setOf("night")))
        assertEquals("off", CameraQualityPolicy.enhancement("off", setOf("auto", "hdr")))
    }
}
