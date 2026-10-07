package com.devicehubpro.verifier

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class StatusBarReadingsTest {

    @Test
    fun `unset keys read as off, like SystemUI's getInt default`() {
        assertEquals("Off", text(demoModeText(null, null)))
        assertEquals("Off", text(demoModeText("null", "null")))
        assertEquals("Off", text(demoModeText("0", "0")))
        assertFalse(readingMuted(demoModeText("0", "0")))
    }

    @Test
    fun `the gate alone is off but allowed`() {
        assertEquals("Off · allowed (sysui_demo_allowed = 1)", text(demoModeText("1", "0")))
    }

    @Test
    fun `the tuner key reads on, with or without the gate`() {
        assertEquals("On (sysui_tuner_demo_on = 1)", text(demoModeText("1", "1")))
        // Measured on API 37 (probe-on-by-tuner-gate-off): SystemUI is in demo mode and ignores commands.
        assertEquals(
            "On (sysui_tuner_demo_on = 1) · commands blocked (sysui_demo_allowed = 0)",
            text(demoModeText("0", "1")),
        )
        assertEquals("On (sysui_tuner_demo_on = 1)", text(demoModeText(" 2 ", "1")))
    }

    @Test
    fun `a value SystemUI cannot read is unreadable`() {
        val reading = demoModeText("x", "0")
        assertEquals("Unreadable", text(reading))
        assertTrue(readingMuted(reading))
        assertTrue(readingMuted(demoModeText("0", "on")))
    }

    @Test
    fun `the section is one key-value row`() {
        val section = buildSections(FakeCapabilities(isEmulator = false)).first { it.id == "statusBar" }
        assertTrue(section.applicable)
        assertEquals(listOf("statusBar.demoMode"), section.rows.map { it.id })
        assertEquals(RowKind.KEY, section.rows.single().kind)
        val ids = buildSections(FakeCapabilities()).map { it.id }
        assertEquals(ids.indexOf("languageTime") + 1, ids.indexOf("statusBar"))
    }

    private fun text(reading: Reading): String = (reading as Reading.Value).text
}
