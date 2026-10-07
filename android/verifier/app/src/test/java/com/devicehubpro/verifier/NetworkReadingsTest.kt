package com.devicehubpro.verifier

import android.net.ConnectivityManager
import android.net.wifi.WifiManager
import org.junit.Assert.assertEquals
import org.junit.Test

class NetworkReadingsTest {

    @Test
    fun `wifi states read as words`() {
        assertEquals("On", wifiStateText(WifiManager.WIFI_STATE_ENABLED))
        assertEquals("Off", wifiStateText(WifiManager.WIFI_STATE_DISABLED))
        assertEquals("Turning on", wifiStateText(WifiManager.WIFI_STATE_ENABLING))
        assertEquals("Turning off", wifiStateText(WifiManager.WIFI_STATE_DISABLING))
        assertEquals("Unknown", wifiStateText(99))
    }

    @Test
    fun `data saver states read as words`() {
        assertEquals("On", dataSaverText(ConnectivityManager.RESTRICT_BACKGROUND_STATUS_ENABLED))
        assertEquals("On (allowlisted)", dataSaverText(ConnectivityManager.RESTRICT_BACKGROUND_STATUS_WHITELISTED))
        assertEquals("Off", dataSaverText(ConnectivityManager.RESTRICT_BACKGROUND_STATUS_DISABLED))
        assertEquals("Unknown", dataSaverText(99))
    }

    @Test
    fun `network section lists the six Device Hub Pro rows in order`() {
        val section = buildSections(FakeCapabilities()).first { it.id == "network" }
        assertEquals(
            listOf(
                "network.wifi",
                "network.bluetooth",
                "network.airplane",
                "network.mobileData",
                "network.dataSaver",
            ),
            section.rows.map { it.id },
        )
        assertEquals(RowKind.DIRECT, section.rows.first { it.id == "network.wifi" }.kind)
    }

    @Test
    fun `on off text marks an unknown state`() {
        assertEquals(Reading.Value("On"), onOffText(true))
        assertEquals(Reading.Value("Off"), onOffText(false))
        assertEquals(true, readingMuted(onOffText(null)))
    }
}
