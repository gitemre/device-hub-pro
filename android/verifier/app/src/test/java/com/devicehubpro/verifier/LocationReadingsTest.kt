package com.devicehubpro.verifier

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class LocationReadingsTest {

    @Test
    fun `no fix reads as a muted message`() {
        val reading = locationText(null, null, null, null)
        assertEquals("No fix yet", (reading as Reading.Value).text)
        assertTrue(reading.muted)
    }

    @Test
    fun `a fix renders five decimals, accuracy and time`() {
        val text = (locationText(41.0086, 28.9784, 5f, 0L) as Reading.Value).text
        assertTrue(text.startsWith("41.00860, 28.97840"))
        assertTrue(text.contains("± 5 m"))
        assertTrue(Regex("""· \d{2}:\d{2}:\d{2}""").containsMatchIn(text))
    }

    @Test
    fun `the location section is emulator gated`() {
        val onEmulator = buildSections(FakeCapabilities(isEmulator = true)).first { it.id == "location" }
        val onPhone = buildSections(FakeCapabilities(isEmulator = false)).first { it.id == "location" }
        assertTrue(onEmulator.applicable)
        assertTrue(!onPhone.applicable)
    }
}
