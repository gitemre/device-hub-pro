package com.devicehubpro.verifier

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ReadingsTest {

    @Test
    fun `toggle reads 1 and true as On`() {
        assertEquals("On", text(toggleReading("1")))
        assertEquals("On", text(toggleReading("true")))
        assertEquals("On", text(toggleReading(" TRUE ")))
    }

    @Test
    fun `toggle reads 0 and false as Off`() {
        assertEquals("Off", text(toggleReading("0")))
        assertEquals("Off", text(toggleReading("false")))
    }

    @Test
    fun `unset keys follow the caller default`() {
        assertEquals("Off", text(toggleReading(null)))
        assertEquals("Off", text(toggleReading("null")))
        assertEquals("On", text(toggleReading(null, whenUnset = true)))
    }

    @Test
    fun `garbage reads as a muted Unreadable`() {
        val reading = toggleReading("banana")
        assertEquals("Unreadable", text(reading))
        assertTrue(readingMuted(reading))
    }

    @Test
    fun `key reading trims and maps blank and null to Unset`() {
        assertEquals("1", text(keyReading(" 1 ")))
        assertEquals("Unset", text(keyReading(null)))
        assertEquals("Unset", text(keyReading("null")))
        assertEquals("Unset", text(keyReading("   ")))
    }

    @Test
    fun `readingText and readingMuted render every state`() {
        assertEquals("On", readingText(Reading.Value("On")))
        assertEquals("Permission required — tap to grant", readingText(Reading.NeedsPermission))
        assertEquals("Not on this device", readingText(Reading.Unsupported))
        assertEquals("boom", readingText(Reading.Failed("boom")))
        assertFalse(readingMuted(Reading.NeedsPermission))
        assertFalse(readingMuted(Reading.Value("On")))
        assertTrue(readingMuted(Reading.Value("Unreadable", muted = true)))
        assertTrue(readingMuted(Reading.Unsupported))
        assertTrue(readingMuted(Reading.Failed("boom")))
    }

    @Test
    fun `time formatting is HH mm ss`() {
        assertTrue(Regex("""\d{2}:\d{2}:\d{2}""").matches(formatTime(0)))
    }

    private fun text(reading: Reading): String = (reading as Reading.Value).text

    /** Runs queued tasks only when told to, like a busy background thread. */
    private class QueuedExecutor : java.util.concurrent.Executor {
        val tasks = ArrayDeque<Runnable>()
        override fun execute(command: Runnable) {
            tasks.addLast(command)
        }
        fun runAll() {
            while (tasks.isNotEmpty()) tasks.removeFirst().run()
        }
    }

    @Test
    fun `a background command never blocks the caller and runs one at a time`() {
        val executor = QueuedExecutor()
        var runs = 0
        val command = BackgroundCommand(executor) {
            runs += 1
            "enabled"
        }

        assertEquals(null, command.latest())
        assertEquals(null, command.latest())
        assertEquals("one run while one is pending", 1, executor.tasks.size)
        assertEquals(0, runs)

        executor.runAll()
        assertEquals("enabled", command.latest())
        assertEquals(1, runs)
        assertEquals("the next read refreshes it", 1, executor.tasks.size)
    }

    @Test
    fun `a command that never answered is not spawned again`() {
        val executor = QueuedExecutor()
        var runs = 0
        val command = BackgroundCommand(executor) {
            runs += 1
            null
        }
        command.latest()
        executor.runAll()
        assertTrue(command.failed)

        assertEquals(null, command.latest())
        assertEquals(0, executor.tasks.size)
        assertEquals(1, runs)
    }

    @Test
    fun `a command that answered keeps its last answer through a failure`() {
        val executor = QueuedExecutor()
        var answer: String? = "disabled"
        val command = BackgroundCommand(executor) { answer }
        command.latest()
        executor.runAll()

        answer = null
        command.latest()
        executor.runAll()
        assertFalse(command.failed)
        assertEquals("disabled", command.latest())
    }
}

