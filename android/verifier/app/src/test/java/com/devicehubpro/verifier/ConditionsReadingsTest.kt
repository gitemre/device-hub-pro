package com.devicehubpro.verifier

import android.telephony.ServiceState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.Executor

class ConditionsReadingsTest {

    // MARK: - Sections

    @Test
    fun `network conditions rows mirror the Device Hub Pro group and hide on phones`() {
        val section = buildSections(FakeCapabilities()).first { it.id == "networkConditions" }
        assertEquals(
            listOf(
                "networkConditions.dataPath",
                "networkConditions.connectionLatency",
                "networkConditions.meteredMobileData",
            ),
            section.rows.map { it.id },
        )
        assertTrue(section.rows.all { it.kind == RowKind.DIRECT })
        val phone = buildSections(FakeCapabilities(isEmulator = false)).first { it.id == "networkConditions" }
        assertFalse(phone.applicable)
    }

    @Test
    fun `app conditions rows show on every device`() {
        val section = buildSections(FakeCapabilities(isEmulator = false)).first { it.id == "appConditions" }
        assertTrue(section.applicable)
        assertEquals(
            listOf(
                "appConditions.trimMemory",
                "appConditions.killProcess",
            ),
            section.rows.map { it.id },
        )
    }

    // MARK: - Network conditions

    @Test
    fun `the data path names the transport and whether the emulator shapes it`() {
        assertEquals("Mobile data", transportText(NetworkCapabilitiesView(cellular = true, wifi = false)))
        assertEquals("Wi-Fi", transportText(NetworkCapabilitiesView(cellular = false, wifi = true)))
        assertEquals("No network", transportText(null))
        assertEquals(Reading.Value("Mobile data · shaped by the emulator"), dataPathText("Mobile data"))
        assertEquals(Reading.Value("Wi-Fi · not shaped"), dataPathText("Wi-Fi"))
    }

    @Test
    fun `latency reads the median of three connects rounded to 10 ms`() {
        assertEquals(null, medianMillis(emptyList()))
        assertEquals(41L, medianMillis(listOf(130, 41, 39)))
        assertEquals(Reading.Value("≈ 560 ms to connect"), latencyText(555, null, "Mobile data"))
        assertEquals(Reading.Value("≈ 40 ms to connect · Wi-Fi, not shaped"), latencyText(41, null, "Wi-Fi"))
        assertEquals(Reading.Value("Measuring…", muted = true), latencyText(null, null, "Wi-Fi"))
        assertEquals(Reading.Value("Connect failed: timeout", muted = true), latencyText(null, "timeout", "Wi-Fi"))
    }

    @Test
    fun `the latency probe connects at most once per interval`() {
        var now = 0L
        var connects = 0
        val direct = Executor { it.run() }
        val probe = ConnectLatencyProbe(executor = direct, clock = { now }, intervalMs = 3_000) {
            connects += 1
            listOf(600L, 580L, 560L)[connects - 1]
        }
        assertEquals(Reading.Value("≈ 600 ms to connect"), probe.reading("Mobile data"))
        now = 1_000
        probe.reading("Mobile data")
        assertEquals(1, connects)
        now = 3_000
        probe.reading("Mobile data")
        now = 6_000
        assertEquals(Reading.Value("≈ 580 ms to connect"), probe.reading("Mobile data"))
        assertEquals(3, connects)
    }

    @Test
    fun `the meter reads as words`() {
        assertEquals(
            Reading.Value("Off (temporarily not metered) · isActiveNetworkMetered = true"),
            meteredText(temporarilyNotMetered = true, activeMetered = true, cellular = true),
        )
        assertEquals(
            Reading.Value("On (metered) · isActiveNetworkMetered = true"),
            meteredText(temporarilyNotMetered = false, activeMetered = true, cellular = true),
        )
        assertTrue((meteredText(null, activeMetered = false, cellular = false) as Reading.Value).muted)
    }

    // MARK: - App conditions

    @Test
    fun `trim memory names the level and the recorded one`() {
        assertEquals("UI_HIDDEN", trimLevelName(20))
        assertEquals("COMPLETE", trimLevelName(80))
        assertEquals(
            Reading.Value("No onTrimMemory in this process yet · lastTrimLevel 0", muted = true),
            trimMemoryText(null, 0L, 0),
        )
        val reading = trimMemoryText(10, 1_000L, 10) as Reading.Value
        assertTrue(reading.text.startsWith("RUNNING_LOW (10) at "))
        assertTrue(reading.text.endsWith(" · lastTrimLevel 10"))
    }

    @Test
    fun `exit records say what ended the process`() {
        // What getDescription() returns for am kill: the subreason, then AMS's description.
        val record = ExitRecord(REASON_USER_REQUESTED, "[KILL BACKGROUND] kill background", 1_000L, 3310)
        assertTrue(isBackgroundKill(record))
        assertFalse(isBackgroundKill(record.copy(description = "[FORCE STOP] stop com.example due to from pid 1")))
        assertFalse(isBackgroundKill(record.copy(reason = 4)))
        val kill = exitText(record, "Killed in the background", "No background kill recorded", restored = true) as Reading.Value
        assertTrue(kill.text.startsWith("Killed in the background ([KILL BACKGROUND] kill background) at "))
        assertTrue(kill.text.endsWith(" · pid 3310 · activity restored from saved state"))
        assertEquals(
            Reading.Value("No background kill recorded", muted = true),
            exitText(null, "Killed in the background", "No background kill recorded", restored = false),
        )
    }

    @Test
    fun `only the first activity of a process counts as restored`() {
        // A live process's rotation brings saved state too; the first activity decides.
        val restore = ProcessRestore
        restore.onActivityCreated(hasSavedState = false)
        restore.onActivityCreated(hasSavedState = true)
        assertFalse(restore.restoredFromSavedState)
    }
}
