package com.devicehubpro.verifier

import com.google.gson.JsonObject
import com.google.gson.JsonParser
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * The verifier against `controls-rows.json` (the repository root, schema 2), the manifest
 * shared with Device Hub Pro's Swift tests (ControlsRowManifestTests checks the same file against
 * ControlsRow, IOSVerifierRegistryTests its `ios` keys against the iOS verifier). Only the
 * rows with an `android` key are offered on Android; every verifier row must mirror one of
 * them, and a mirrored row carries the Controls label (the `android` override, else the
 * shared one) verbatim. `menuRows` lists what moved from the Controls panel to the Device menu
 * (2026-09-29: Sensors, Telephony, Emulator state, Fingerprint): they keep their `android` keys, so
 * the verifier rows that observe them stay mapped.
 */
class ControlsRowsManifestTest {

    private data class Entry(val row: String, val label: String?, val verifier: List<String>, val sameTitle: Boolean)

    private val manifest: JsonObject by lazy { JsonParser.parseString(manifestFile().readText()).asJsonObject }

    /** Every row name, whichever platforms it is offered on. */
    private val allRows: List<String> by lazy {
        manifest.getAsJsonArray("rows").map { it.asJsonObject.requiredString("row", "a manifest entry") }
    }

    /** The rows offered on Android (the Controls panel's and the Device menu's), read from their `android` key. */
    private val entries: List<Entry> by lazy {
        (manifest.getAsJsonArray("rows").toList() + manifest.getAsJsonArray("menuRows").toList()).mapNotNull { element ->
            val entry = element.asJsonObject
            val row = entry.requiredString("row", "a manifest entry")
            val android = entry.get("android")?.takeUnless { it.isJsonNull }?.asJsonObject ?: return@mapNotNull null
            val verifier = android.get("verifier")?.takeUnless { it.isJsonNull }?.asJsonArray
                ?: error("$row: android has no verifier list")
            val sameTitle = android.get("sameTitle")?.takeUnless { it.isJsonNull }?.asBoolean
                ?: error("$row: android has no sameTitle")
            Entry(
                row = row,
                label = android.stringOrNull("label") ?: entry.stringOrNull("label"),
                verifier = verifier.map { it.asString },
                sameTitle = sameTitle,
            )
        }
    }

    private val rows: Map<String, VerifierRow> by lazy {
        buildSections(FakeCapabilities()).flatMap { it.rows }.associateBy { it.id }
    }

    /** Gradle runs unit tests from the module directory; the manifest sits at the repository root above it. */
    private fun manifestFile(): File {
        var directory: File? = File("").absoluteFile
        while (directory != null) {
            val candidate = File(directory, "controls-rows.json")
            if (candidate.exists()) return candidate
            directory = directory.parentFile
        }
        error("controls-rows.json not found above ${File("").absolutePath}")
    }

    private fun JsonObject.stringOrNull(name: String): String? =
        get(name)?.takeUnless { it.isJsonNull }?.asString

    private fun JsonObject.requiredString(name: String, what: String): String =
        stringOrNull(name) ?: error("$what has no $name: $this")

    @Test
    fun `the manifest is schema 2`() {
        assertEquals(2, manifest.get("schema")?.asInt)
    }

    @Test
    fun `the manifest lists each Controls row once`() {
        assertTrue(allRows.isNotEmpty())
        assertEquals(allRows.size, allRows.toSet().size)
        assertTrue(entries.isNotEmpty())
    }

    @Test
    fun `every mapped verifier row exists`() {
        entries.forEach { entry ->
            entry.verifier.forEach { id ->
                assertTrue("${entry.row} maps to missing verifier row $id", id in rows)
            }
        }
    }

    @Test
    fun `every verifier row mirrors a Controls row`() {
        val mapped = entries.flatMap { it.verifier }.toSet()
        val stale = rows.keys - mapped
        assertTrue("verifier rows no Android Controls row maps to: $stale", stale.isEmpty())
    }

    @Test
    fun `mirrored rows use the Controls label verbatim`() {
        entries.filter { it.sameTitle }.forEach { entry ->
            assertEquals("${entry.row} has one verifier row", 1, entry.verifier.size)
            val row = rows.getValue(entry.verifier.single())
            assertEquals("${row.id} title", entry.label, row.title)
        }
    }
}
