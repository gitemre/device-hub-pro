package com.devicehubpro.verifier

import android.hardware.Sensor
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class FoldableReadingsTest {

    @Test
    fun `posture follows the AVD hinge ranges and Device Hub Pro's labels`() {
        // hw.sensor.hinge_angles_posture_definitions=0-30, 30-150, 150-180
        assertEquals(Posture.CLOSED, postureFor(0f))
        assertEquals(Posture.CLOSED, postureFor(29.9f))
        assertEquals(Posture.HALF_OPENED, postureFor(30f))
        assertEquals(Posture.HALF_OPENED, postureFor(90f))
        assertEquals(Posture.HALF_OPENED, postureFor(149.9f))
        assertEquals(Posture.OPENED, postureFor(150f))
        assertEquals(Posture.OPENED, postureFor(180f))
        assertEquals(Posture.UNKNOWN, postureFor(null))
        assertEquals(listOf("Closed", "Half", "Opened"), listOf(Posture.CLOSED, Posture.HALF_OPENED, Posture.OPENED).map { it.label })
    }

    @Test
    fun `the hinge reads in degrees`() {
        assertEquals("90.0°", (hingeText(90f) as Reading.Value).text)
        assertTrue((hingeText(null) as Reading.Value).muted)
    }

    @Test
    fun `the foldable section mirrors the stage fold strip's posture and hinge`() {
        val section = buildSections(FakeCapabilities()).first { it.id == "foldable" }
        assertEquals(listOf("foldable.posture", "foldable.hinge"), section.rows.map { it.id })
    }

    @Test
    fun `the foldable section is gated on the hinge sensor`() {
        val withHinge = buildSections(
            FakeCapabilities(isEmulator = true, sensors = setOf(Sensor.TYPE_HINGE_ANGLE))
        ).first { it.id == "foldable" }
        assertTrue(withHinge.applicable)
        val without = buildSections(FakeCapabilities(isEmulator = true)).first { it.id == "foldable" }
        assertTrue(!without.applicable)
    }
}
