package com.devicehubpro.verifier

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class FormFactorReadingsTest {

    @Test
    fun `window size renders dp, dpi and smallest width`() {
        assertEquals("411×891 dp · 420 dpi · sw411dp", windowText(411, 891, 420, 411))
    }

    @Test
    fun `the form factor section is emulator gated and mirrors the preset row`() {
        // The extra-display (picture-in-picture) feature is gone from Device Hub Pro, and so is its row.
        val section = buildSections(FakeCapabilities(isEmulator = true)).first { it.id == "formFactor" }
        assertEquals(listOf("formFactor.window"), section.rows.map { it.id })
        assertEquals("Preset", section.rows.single().title)
        val phone = buildSections(FakeCapabilities(isEmulator = false)).first { it.id == "formFactor" }
        assertTrue(!phone.applicable)
    }
}
