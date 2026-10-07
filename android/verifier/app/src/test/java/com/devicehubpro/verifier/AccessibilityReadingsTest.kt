package com.devicehubpro.verifier

import android.view.View
import org.junit.Assert.assertEquals
import org.junit.Test

class AccessibilityReadingsTest {

    @Test
    fun `talkback packages are the GMS package or a dot-talkback suffix`() {
        assertEquals(true, isTalkBackPackage("com.google.android.marvin.talkback"))
        assertEquals(true, isTalkBackPackage("com.samsung.android.talkback"))
        assertEquals(false, isTalkBackPackage("com.google.android.marvin.talkbackoverlay"))
        assertEquals(false, isTalkBackPackage("com.example.app"))
    }

    @Test
    fun `talkback reading combines the service list and touch exploration`() {
        assertEquals(
            "On (touch exploration active)",
            text(talkBackText(listOf("com.google.android.marvin.talkback"), true)),
        )
        assertEquals("On", text(talkBackText(listOf("com.google.android.marvin.talkback"), false)))
        assertEquals("Off", text(talkBackText(listOf("com.example.other"), true)))
    }

    @Test
    fun `layout direction reads as RTL or LTR`() {
        assertEquals("RTL", layoutDirectionText(View.LAYOUT_DIRECTION_RTL))
        assertEquals("LTR", layoutDirectionText(View.LAYOUT_DIRECTION_LTR))
    }

    @Test
    fun `force RTL reports the direction in effect and a pending request`() {
        assertEquals("LTR", text(forceRtlText(View.LAYOUT_DIRECTION_LTR, "0", "false", languageIsRtl = false)))
        assertEquals("LTR", text(forceRtlText(View.LAYOUT_DIRECTION_LTR, null, "", languageIsRtl = false)))
        assertEquals(
            "LTR · requested, not applied yet (applies after a restart)",
            text(forceRtlText(View.LAYOUT_DIRECTION_LTR, "1", "true", languageIsRtl = false)),
        )
        assertEquals("RTL · forced", text(forceRtlText(View.LAYOUT_DIRECTION_RTL, "1", "true", languageIsRtl = false)))
        // An RTL locale is RTL without any request.
        assertEquals("RTL", text(forceRtlText(View.LAYOUT_DIRECTION_RTL, "0", "false", languageIsRtl = true)))
    }

    @Test
    fun `force RTL off on a right-to-left device is pending`() {
        // The API 37 emulator's state: key 0, property true, en-US laid out right to left.
        assertEquals(
            "RTL · off, still forced by the property until a restart",
            text(forceRtlText(View.LAYOUT_DIRECTION_RTL, "0", "true", languageIsRtl = false)),
        )
        assertEquals(
            "RTL · off, not applied yet (applies after a restart)",
            text(forceRtlText(View.LAYOUT_DIRECTION_RTL, "0", "false", languageIsRtl = false)),
        )
    }

    @Test
    fun `color filter text follows ColorDisplayService`() {
        assertEquals("None", text(colorFilterText("null", "null")))
        assertEquals("None", text(colorFilterText(null, null)))
        assertEquals("None", text(colorFilterText("0", "11")))
        assertEquals("Grayscale · mode 0", text(colorFilterText("1", "0")))
        assertEquals("Red/Green (Protanopia) · mode 11", text(colorFilterText("1", "11")))
        assertEquals("Green/Red (Deuteranopia) · mode 12", text(colorFilterText("1", "12")))
        assertEquals("Blue/Yellow (Tritanopia) · mode 13", text(colorFilterText("1", "13")))
        assertEquals("Green/Red (Deuteranopia) · mode unset (12)", text(colorFilterText("1", "null")))
        assertEquals("Green/Red (Deuteranopia) · mode unset (12)", text(colorFilterText("1", null)))
        assertEquals("Green/Red (Deuteranopia) · mode unreadable (12)", text(colorFilterText("1", "abc")))
        // Android parses the stored string untrimmed, as Integer.parseInt: the Device Hub Pro fixtures
        // readings-probe-mode-empty / -mode-space-11 / -mode-overflow / -enabled-space-1 (API 37).
        assertEquals("Green/Red (Deuteranopia) · mode empty (12)", text(colorFilterText("1", "")))
        assertEquals("Green/Red (Deuteranopia) · mode unreadable (12)", text(colorFilterText("1", " 11")))
        assertEquals("Green/Red (Deuteranopia) · mode unreadable (12)", text(colorFilterText("1", "2147483659")))
        assertEquals("None", text(colorFilterText(" 1", null)))
        assertEquals("None", text(colorFilterText("", "11")))
        assertEquals("Red/Green (Protanopia) · mode 11", text(colorFilterText("+1", "+11")))
        assertEquals(Reading.Value("Mode -2147483648", muted = true), colorFilterText("1", "-2147483648"))
        assertEquals("Simulated Deuteranopia · mode 2", text(colorFilterText("1", "2")))
        assertEquals(Reading.Value("Mode 99", muted = true), colorFilterText("1", "99"))
        assertEquals(Reading.Value("Mode -1", muted = true), colorFilterText("1", "-1"))
        assertEquals(Reading.Value("Mode 21", muted = true), colorFilterText("1", "21"))
    }

    @Test
    fun `accessibility section lists the three Device Hub Pro rows`() {
        val section = buildSections(FakeCapabilities()).first { it.id == "accessibility" }
        assertEquals(
            listOf(
                "accessibility.talkBack",
                "accessibility.colorFilter",
                "accessibility.increaseContrast",
            ),
            section.rows.map { it.id },
        )
    }

    private fun text(reading: Reading): String = (reading as Reading.Value).text
}
