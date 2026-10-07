package com.devicehubpro.verifier

import android.content.res.Configuration
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DisplayReadingsTest {

    @Test
    fun `night mode reads as the current mode`() {
        assertEquals("Dark", nightModeText(Configuration.UI_MODE_NIGHT_YES))
        assertEquals("Light", nightModeText(Configuration.UI_MODE_NIGHT_NO))
        assertEquals("System (unknown)", nightModeText(0))
    }

    @Test
    fun `font scale renders as a multiplier`() {
        assertEquals("1.30×", fontScaleText(1.3f))
        assertEquals("1.00×", fontScaleText(1.0f))
    }

    @Test
    fun `animation scales follow Device Hub Pro semantics`() {
        assertEquals(1.0, animationScale(null))
        assertEquals(1.0, animationScale("null"))
        assertEquals(0.0, animationScale("0"))
        assertEquals(1.5, animationScale(" 1.5 "))
        assertNull(animationScale("banana"))
        assertNull(animationScale("-1"))
    }

    @Test
    fun `reduce motion folds the three scales`() {
        assertEquals("On (all animation scales are 0)", text(reduceMotionText("0", "0", "0")))
        assertEquals("Off", text(reduceMotionText("null", "null", "null")))
        assertEquals("Off", text(reduceMotionText("1", "0", "0")))
        assertEquals("Unreadable", text(reduceMotionText("banana", "0", "0")))
        assertTrue(readingMuted(reduceMotionText("banana", "0", "0")))
    }

    @Test
    fun `the flash duration follows the animator scale so Reduce Motion is observable`() {
        assertEquals(600L, flashDurationFor(1.0))
        assertEquals(600L, flashDurationFor(null))
        assertEquals(0L, flashDurationFor(0.0))
        assertEquals(300L, flashDurationFor(0.5))
        assertEquals(1200L, flashDurationFor(2.0))
        assertEquals(0L, flashDurationFor(-1.0))
    }

    @Test
    fun `display section lists the six Device Hub Pro rows in order`() {
        val section = buildSections(FakeCapabilities()).first { it.id == "display" }
        assertEquals(
            listOf(
                "display.appearance",
                "display.textSize",
                "display.reduceMotion",
                "display.showBorders",
                "display.sound",
            ),
            section.rows.map { it.id },
        )
        assertEquals(RowKind.KEY, section.rows.first { it.id == "display.reduceMotion" }.kind)
        // Show Borders observes the property apps read, not a settings key.
        assertEquals(RowKind.DIRECT, section.rows.first { it.id == "display.showBorders" }.kind)
    }

    @Test
    fun `show borders reads the debug layout property`() {
        assertEquals("On (debug.layout = true)", text(showBordersText("true")))
        assertEquals("Off", text(showBordersText("false")))
        assertEquals("Off", text(showBordersText("")))
        assertEquals("Unreadable", text(showBordersText(null)))
        assertEquals("Unreadable", text(showBordersText("maybe")))
    }

    @Test
    fun `boolean properties follow the platform parser`() {
        assertEquals(true, propertyToggle("true"))
        assertEquals(true, propertyToggle(" 1\n"))
        assertEquals(false, propertyToggle("false"))
        assertEquals(false, propertyToggle(""))
        assertEquals(null, propertyToggle(null))
        assertEquals(null, propertyToggle("yes"))
    }

    private fun text(reading: Reading): String = (reading as Reading.Value).text
}
