package com.devicehubpro.verifier

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.TimeZone

class LanguageTimeReadingsTest {

    @Test
    fun `the language list reads with its direction`() {
        assertEquals("tr-TR, de-DE, en-US · LTR", text(languageText("tr-TR,de-DE,en-US", false)))
        assertEquals("ar-EG · RTL", text(languageText("ar-EG", true)))
        assertEquals("Unreadable", text(languageText("", false)))
        assertTrue(readingMuted(languageText("", false)))
    }

    @Test
    fun `the clock reads in its zone with its offset from network time`() {
        val istanbul = TimeZone.getTimeZone("Europe/Istanbul")
        // 2026-09-26 13:08:45 in Istanbul (UTC+3).
        val wall = 1_790_417_325_000L
        assertEquals(
            "Sat 26 Sep 13:08 · 1 h ahead of network time",
            text(dateTimeText(wall, istanbul, wall - 3_600_000)),
        )
        assertEquals("Sat 26 Sep 13:08 · no network time", text(dateTimeText(wall, istanbul, null)))
        assertEquals("in step with network time", offsetText(9_000))
        assertEquals("1 day 1 h ahead of network time", offsetText(90_000_000))
        assertEquals("5 min behind network time", offsetText(-300_000))
    }

    @Test
    fun `the zone reads with its GMT offset`() {
        assertEquals("Asia/Tokyo · GMT+09:00", text(timeZoneText("Asia/Tokyo", 32_400_000)))
        assertEquals("America/St_Johns · GMT-02:30", text(timeZoneText("America/St_Johns", -9_000_000)))
        assertEquals("Etc/UTC · GMT", text(timeZoneText("Etc/UTC", 0)))
    }

    @Test
    fun `the 24-hour row names what decided it`() {
        assertEquals("24-hour (time_12_24 = 24)", text(timeFormatText(true, "24")))
        assertEquals("12-hour (time_12_24 = 12)", text(timeFormatText(false, "12")))
        assertEquals("12-hour (language default)", text(timeFormatText(false, null)))
        assertEquals("24-hour (language default)", text(timeFormatText(true, "null")))
    }

    @Test
    fun `automatic switches read on when their key is unset`() {
        assertEquals("On", text(toggleReading(null, whenUnset = true)))
        assertEquals("Off", text(toggleReading("0", whenUnset = true)))
    }

    @Test
    fun `the section lists the verifier's seven rows in order`() {
        val section = buildSections(FakeCapabilities()).first { it.id == "languageTime" }
        assertEquals(
            listOf(
                "languageTime.language",
                "languageTime.forceRtl",
                "languageTime.autoTime",
                "languageTime.dateTime",
                "languageTime.autoTimeZone",
                "languageTime.timeZone",
                "languageTime.timeFormat24",
            ),
            section.rows.map { it.id },
        )
        assertEquals(RowKind.KEY, section.rows.first { it.id == "languageTime.autoTime" }.kind)
        assertEquals(RowKind.DIRECT, section.rows.first { it.id == "languageTime.timeZone" }.kind)
    }

    private fun text(reading: Reading): String = (reading as Reading.Value).text
}
