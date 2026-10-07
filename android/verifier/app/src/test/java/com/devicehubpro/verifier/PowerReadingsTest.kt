package com.devicehubpro.verifier

import android.os.BatteryManager
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PowerReadingsTest {

    @Test
    fun `battery percent renders with a percent sign`() {
        assertEquals("42 %", (batteryText(42) as Reading.Value).text)
    }

    @Test
    fun `impossible battery percent is muted and unreadable`() {
        val reading = batteryText(-1)
        assertEquals("Unreadable", (reading as Reading.Value).text)
        assertTrue(reading.muted)
    }

    @Test
    fun `charging states read as words`() {
        assertEquals("Charging", chargingText(BatteryManager.BATTERY_STATUS_CHARGING))
        assertEquals("Full", chargingText(BatteryManager.BATTERY_STATUS_FULL))
        assertEquals("Not charging", chargingText(BatteryManager.BATTERY_STATUS_DISCHARGING))
        assertEquals("Unknown", chargingText(99))
    }

    @Test
    fun `battery saver explains why it stays off on a charger`() {
        assertEquals("On", (batterySaverText(powerSave = true, plugged = true) as Reading.Value).text)
        assertEquals("Off", (batterySaverText(powerSave = false, plugged = false) as Reading.Value).text)
        assertEquals("Off", (batterySaverText(powerSave = false, plugged = null) as Reading.Value).text)
        assertEquals(
            "Off (charging — Android refuses battery saver)",
            (batterySaverText(powerSave = false, plugged = true) as Reading.Value).text,
        )
    }

    @Test
    fun `power section lists the three Device Hub Pro rows`() {
        val section = buildSections(FakeCapabilities()).first { it.id == "power" }
        assertEquals(
            listOf("power.battery", "power.charging", "power.batterySaver"),
            section.rows.map { it.id },
        )
    }
}
