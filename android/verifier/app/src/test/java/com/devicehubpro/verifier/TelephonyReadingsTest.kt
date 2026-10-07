package com.devicehubpro.verifier

import android.telephony.TelephonyManager
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class TelephonyReadingsTest {

    @Test
    fun `call states read as words`() {
        assertEquals("Idle", callStateText(TelephonyManager.CALL_STATE_IDLE))
        assertEquals("Ringing", callStateText(TelephonyManager.CALL_STATE_RINGING))
        assertEquals("Off-hook", callStateText(TelephonyManager.CALL_STATE_OFFHOOK))
    }

    @Test
    fun `a ringing call shows the number`() {
        val reading = callReading(TelephonyManager.CALL_STATE_RINGING, "5551234", null, 0L)
        assertEquals("Ringing · 5551234", (reading as Reading.Value).text)
    }

    @Test
    fun `an idle call with history shows the last one`() {
        val reading = callReading(TelephonyManager.CALL_STATE_IDLE, null, "5551234", 1_000L)
        val text = (reading as Reading.Value).text
        assertTrue(text.startsWith("Idle · last call 5551234 at "))
    }

    @Test
    fun `no sms yet is muted`() {
        val reading = smsReading(null, null, 0L)
        assertEquals("No SMS yet", (reading as Reading.Value).text)
        assertTrue(reading.muted)
    }

    @Test
    fun `an sms shows sender, snippet and time`() {
        val text = (smsReading("5551234", "hello verifier", 1_000L) as Reading.Value).text
        assertTrue(text.startsWith("5551234 · hello verifier · "))
    }

    @Test
    fun `a blank phone number is unreadable`() {
        assertEquals("Unreadable", (phoneNumberText("  ") as Reading.Value).text)
        assertEquals("5551234", (phoneNumberText("5551234") as Reading.Value).text)
    }

    @Test
    fun `the telephony section is emulator gated and lists the three rows`() {
        val emulator = buildSections(FakeCapabilities(isEmulator = true, hasTelephony = true))
            .first { it.id == "telephony" }
        assertEquals(
            listOf("telephony.incomingCall", "telephony.incomingSms", "telephony.phoneNumber"),
            emulator.rows.map { it.id },
        )
        val phone = buildSections(FakeCapabilities(isEmulator = false))
            .first { it.id == "telephony" }
        assertTrue(!phone.applicable)
    }
}
