package com.devicehubpro.verifier

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AdvancedReadingsTest {

    @Test
    fun `fingerprint states read honestly`() {
        assertEquals(
            "Not on this device",
            readingText(fingerprintText(BiometricState.UNSUPPORTED, null, 0L)),
        )
        assertEquals(
            "No fingerprint enrolled",
            (fingerprintText(BiometricState.NONE_ENROLLED, null, 0L) as Reading.Value).text,
        )
        val succeeded = fingerprintText(BiometricState.READY, "Succeeded", 1_000L) as Reading.Value
        assertTrue(succeeded.text.startsWith("Succeeded · "))
    }

    @Test
    fun `pause tracking keeps the largest gap`() {
        val tracker = PauseTracker()
        assertEquals("Running · no pause detected yet", (tracker.read() as Reading.Value).text)
        tracker.recordGap(5_000)
        tracker.recordGap(3_000)
        assertEquals("Pause detected: no ticks for 5 s", (tracker.read() as Reading.Value).text)
    }

    @Test
    fun `the advanced section is emulator gated and lists both rows`() {
        val section = buildSections(FakeCapabilities(isEmulator = true)).first { it.id == "advanced" }
        assertEquals(
            listOf("advanced.fingerprint", "advanced.vmState"),
            section.rows.map { it.id },
        )
        assertEquals(RowKind.INTERACTIVE, section.rows[0].kind)
        assertEquals(RowKind.NOTE, section.rows[1].kind)
    }

    @Test
    fun `the fingerprint action is offered only when biometrics are ready`() {
        val ready = advancedSection(FakeCapabilities(biometricState = BiometricState.READY), PauseTracker())
        val none = advancedSection(FakeCapabilities(biometricState = BiometricState.NONE_ENROLLED), PauseTracker())
        val unsupported = advancedSection(FakeCapabilities(biometricState = BiometricState.UNSUPPORTED), PauseTracker())
        assertTrue(ready.rows.first().actions.isNotEmpty())
        assertTrue(none.rows.first().actions.isEmpty())
        assertTrue(unsupported.rows.first().actions.isEmpty())
    }

    @Test
    fun `the fingerprint detail does not depend on the enrollment snapshot`() {
        val ready = advancedSection(FakeCapabilities(biometricState = BiometricState.READY), PauseTracker())
        val none = advancedSection(FakeCapabilities(biometricState = BiometricState.NONE_ENROLLED), PauseTracker())
        assertEquals(ready.rows.first().detail, none.rows.first().detail)
    }
}
