package com.devicehubpro.verifier

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class LinksReadingsTest {

    @Test
    fun `the links row mirrors the Device Hub Pro URL row and show on every device`() {
        val section = buildSections(FakeCapabilities(isEmulator = false)).first { it.id == "links" }
        assertTrue(section.applicable)
        assertEquals(listOf("links.lastLink"), section.rows.map { it.id })
        assertEquals(listOf("Last link"), section.rows.map { it.title })
        assertTrue(section.rows.all { it.kind == RowKind.DIRECT })
        assertEquals("links", buildSections(FakeCapabilities()).last().id)
    }

    @Test
    fun `no link yet`() {
        assertEquals(Reading.Value("No link received in this process", muted = true), lastLinkText(null))
    }

    @Test
    fun `a browsable custom-scheme link through onNewIntent`() {
        val at = 1_758_800_000_000L
        val record = LinkRecord(
            data = "devicehubpro-verifier://link/check?q=a b&x=ü",
            categories = listOf("android.intent.category.BROWSABLE"),
            referrer = "android-app://com.android.shell",
            at = at,
            viaNewIntent = true,
        )
        assertEquals(
            Reading.Value(
                "devicehubpro-verifier://link/check?q=a b&x=ü · BROWSABLE · from com.android.shell · " +
                    "${formatTime(at)} · onNewIntent",
            ),
            lastLinkText(record),
        )
    }

    @Test
    fun `a link without a category at launch`() {
        val at = 1_758_800_000_000L
        val record = LinkRecord(
            data = "devicehubpro-verifier://internal/x",
            categories = emptyList(),
            referrer = null,
            at = at,
            viaNewIntent = false,
        )
        assertEquals(
            Reading.Value("devicehubpro-verifier://internal/x · no category · ${formatTime(at)}"),
            lastLinkText(record),
        )
    }

    @Test
    fun `referrers are shortened to the sending package`() {
        assertEquals("com.android.shell", referrerName("android-app://com.android.shell"))
        assertEquals("com.example.browser", referrerName("android-app://com.example.browser/https/example.com"))
        assertEquals("https://example.com/", referrerName("https://example.com/"))
        assertEquals(null, referrerName(null))
        assertEquals(null, referrerName(""))
    }
}
