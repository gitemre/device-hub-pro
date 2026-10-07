package com.devicehubpro.verifier

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class RegistryTest {

    @Test
    fun `row ids are unique and rows are complete`() {
        val rows = buildSections(FakeCapabilities()).flatMap { it.rows }
        assertTrue(rows.isNotEmpty())
        assertEquals(rows.size, rows.map { it.id }.toSet().size)
        rows.forEach { row ->
            assertTrue(row.id.isNotBlank())
            assertTrue(row.title.isNotBlank())
            assertTrue(row.source.isNotBlank())
        }
    }

    @Test
    fun `the debug section carries the three developer toggles`() {
        val debug = buildSections(FakeCapabilities()).first { it.id == "debug" }
        assertEquals(
            listOf("debug.showTaps", "debug.backgroundANRs"),
            debug.rows.map { it.id },
        )
        assertTrue(debug.rows.all { it.kind == RowKind.KEY })
    }
}
