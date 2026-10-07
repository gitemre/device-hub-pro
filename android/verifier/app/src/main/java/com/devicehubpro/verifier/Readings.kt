package com.devicehubpro.verifier

import android.content.Context
import android.content.pm.PackageManager
import android.provider.Settings
import androidx.core.content.ContextCompat
import java.lang.reflect.Method
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

fun global(context: Context, key: String): String? =
    Settings.Global.getString(context.contentResolver, key)

fun secure(context: Context, key: String): String? =
    Settings.Secure.getString(context.contentResolver, key)

fun system(context: Context, key: String): String? =
    Settings.System.getString(context.contentResolver, key)

fun hasPermission(context: Context, permission: String): Boolean =
    ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED

/**
 * Runs a command as this app (`getprop`, `cmd`) and returns its trimmed output, or null when it
 * fails, times out or is not allowed. Blocks for up to [timeoutMs]: rows read it through
 * [BackgroundCommand], never on the main thread.
 */
fun shellOutput(vararg command: String, timeoutMs: Long = 500): String? = try {
    val process = ProcessBuilder(*command).redirectErrorStream(true).start()
    if (!process.waitFor(timeoutMs, TimeUnit.MILLISECONDS)) {
        process.destroy()
        null
    } else {
        val output = process.inputStream.bufferedReader().readText().trim()
        output.takeIf { process.exitValue() == 0 }
    }
} catch (exception: Exception) {
    null
}

/**
 * A command a row shows, run off the main thread: rows are read on the main thread every
 * second, and a process spawn can block it for up to its timeout. [latest] returns the last
 * answer at once (null until the first) and starts one new run when none is going. A command
 * that never answered is not run again: apps may not run most `cmd` services, and retrying
 * would spawn a doomed process every tick.
 */
class BackgroundCommand(
    private val executor: Executor = commandExecutor,
    private val run: () -> String?,
) {
    constructor(vararg command: String) : this(run = { shellOutput(*command) })

    @Volatile
    var output: String? = null
        private set

    /** True once the command failed without ever answering. */
    @Volatile
    var failed = false
        private set

    private val running = AtomicBoolean(false)

    fun latest(): String? {
        if (!failed && running.compareAndSet(false, true)) {
            executor.execute {
                val result = try {
                    run()
                } catch (exception: Exception) {
                    null
                }
                if (result != null) {
                    output = result
                } else if (output == null) {
                    failed = true
                }
                running.set(false)
            }
        }
        return output
    }

    companion object {
        private val commandExecutor: Executor = Executors.newSingleThreadExecutor { task ->
            Thread(task, "verifier-commands").apply { isDaemon = true }
        }
    }
}

/** `SystemProperties.get`, resolved once; null where the hidden API is blocked. */
private val systemPropertiesGet: Method? by lazy {
    try {
        Class.forName("android.os.SystemProperties").getMethod("get", String::class.java)
    } catch (exception: Exception) {
        null
    }
}

private val getpropCommands = ConcurrentHashMap<String, BackgroundCommand>()

/**
 * A system property as every app process sees it (`debug.layout`, `debug.force_rtl`):
 * `SystemProperties.get`, else `getprop` off the main thread. Empty means unset.
 */
fun systemProperty(name: String): String? = try {
    systemPropertiesGet?.invoke(null, name) as? String
} catch (exception: Exception) {
    null
} ?: getpropCommands.computeIfAbsent(name) { BackgroundCommand("getprop", it) }.latest()

/** A boolean system property: true/1 on, false/0/unset off, anything else unreadable. */
fun propertyToggle(raw: String?): Boolean? = when (raw?.trim()?.lowercase()) {
    "true", "1" -> true
    "false", "0", "" -> false
    else -> null
}

/** Device Hub Pro's SettingsToggleReading semantics: null is an unset key (off by default). */
fun toggleReading(raw: String?, whenUnset: Boolean = false): Reading =
    when (raw?.trim()?.lowercase()) {
        "1", "true" -> Reading.Value("On")
        "0", "false" -> Reading.Value("Off")
        null, "null" -> Reading.Value(if (whenUnset) "On" else "Off")
        else -> Reading.Value("Unreadable", muted = true)
    }

fun keyReading(raw: String?): Reading =
    Reading.Value(raw?.trim()?.takeIf { it.isNotEmpty() && it != "null" } ?: "Unset")

fun readingText(reading: Reading): String = when (reading) {
    is Reading.Value -> reading.text
    Reading.NeedsPermission -> "Permission required — tap to grant"
    Reading.Unsupported -> "Not on this device"
    is Reading.Failed -> reading.text
}

fun readingMuted(reading: Reading): Boolean = when (reading) {
    is Reading.Value -> reading.muted
    Reading.NeedsPermission -> false
    Reading.Unsupported, is Reading.Failed -> true
}

fun formatTime(millis: Long): String =
    SimpleDateFormat("HH:mm:ss", Locale.US).format(Date(millis))

fun readKey(context: Context, namespace: String, key: String): String? = when (namespace) {
    "system" -> system(context, key)
    "secure" -> secure(context, key)
    else -> global(context, key)
}

/**
 * A KEY row: only the settings value is readable; the effect is drawn by SystemUI (or applied by a
 * system service apps cannot query — [detail] says which). [whenUnset] is the value an unset key
 * stands for.
 */
fun keyToggleRow(
    id: String,
    title: String,
    source: String,
    namespace: String,
    key: String,
    whenUnset: Boolean = false,
    detail: String = "Key value only — the effect is drawn by SystemUI ($namespace $key)",
): VerifierRow = VerifierRow(
    id = id,
    title = title,
    source = source,
    kind = RowKind.KEY,
    detail = detail,
    read = { context -> toggleReading(readKey(context, namespace, key), whenUnset) },
)
