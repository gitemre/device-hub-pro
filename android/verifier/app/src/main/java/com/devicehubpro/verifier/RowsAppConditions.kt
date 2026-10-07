package com.devicehubpro.verifier

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build

/**
 * The App conditions rows, observed by the verifier about itself: pick
 * `com.devicehubpro.verifier` as Device Hub Pro's Target app, send the verifier to the background, act,
 * then reopen it. The trim level is recorded by [VerifierApplication.onTrimMemory]; kills by
 * Android's exit records, read once per process (they only change when a process of
 * this package dies).
 */
fun appConditionsSection(): RowSection = RowSection(
    id = "appConditions",
    title = "App conditions",
    rows = listOf(
        VerifierRow(
            id = "appConditions.trimMemory",
            title = "Simulate low memory",
            source = "App conditions ▸ Simulate low memory · am send-trim-memory",
            kind = RowKind.DIRECT,
            detail = "The last onTrimMemory this process received (the Application's callback) and " +
                "ActivityManager.getMyMemoryState().lastTrimLevel. Simulate low memory sends " +
                "RUNNING_CRITICAL (15) to an app in front and COMPLETE (80) to one in the background; " +
                "leaving the app also sends UI_HIDDEN (20). A frozen background app gets the call when it resumes.",
            read = { context -> trimMemoryReading(context) },
        ),
        VerifierRow(
            id = "appConditions.killProcess",
            title = "Kill process",
            source = "App conditions ▸ Kill process · am kill",
            kind = RowKind.DIRECT,
            detail = "The newest USER_REQUESTED exit record (getHistoricalProcessExitReasons, Android " +
                "11+) and whether this activity came back from saved state after the process died. " +
                "Leave the verifier (Home), kill it, then reopen it from Recents.",
            read = { context -> killReading(context) },
        ),
    ),
)

// MARK: - Trim memory

fun trimLevelName(level: Int): String = when (level) {
    5 -> "RUNNING_MODERATE"
    10 -> "RUNNING_LOW"
    15 -> "RUNNING_CRITICAL"
    20 -> "UI_HIDDEN"
    40 -> "BACKGROUND"
    60 -> "MODERATE"
    80 -> "COMPLETE"
    else -> "level"
}

fun trimMemoryText(lastLevel: Int?, lastAt: Long, recordedLevel: Int?): Reading {
    val recorded = recordedLevel?.let { " · lastTrimLevel $it" } ?: ""
    return if (lastLevel == null || lastAt == 0L) {
        Reading.Value("No onTrimMemory in this process yet$recorded", muted = true)
    } else {
        Reading.Value("${trimLevelName(lastLevel)} ($lastLevel) at ${formatTime(lastAt)}$recorded")
    }
}

fun trimMemoryReading(context: Context): Reading {
    val recorded = try {
        ActivityManager.RunningAppProcessInfo().also { ActivityManager.getMyMemoryState(it) }.lastTrimLevel
    } catch (exception: Exception) {
        null
    }
    return trimMemoryText(TrimLog.lastLevel, TrimLog.lastAt, recorded)
}

/** What [VerifierApplication.onTrimMemory] saw in this process. */
object TrimLog {
    @Volatile var lastLevel: Int? = null
    @Volatile var lastAt: Long = 0L

    fun record(level: Int, at: Long) {
        lastLevel = level
        lastAt = at
    }
}

// MARK: - Process exits

/** One `ApplicationExitInfo`, apart from the framework class (unit-testable). */
data class ExitRecord(val reason: Int, val description: String?, val timestamp: Long, val pid: Int)

/**
 * Whether this process's first activity came back from saved state: the process was recreated
 * after it died (a rotation in a live process also brings saved state, but not to the first
 * activity of the process).
 */
object ProcessRestore {
    @Volatile var restoredFromSavedState = false
        private set

    @Volatile private var activityCreated = false

    fun onActivityCreated(hasSavedState: Boolean) {
        if (!activityCreated && hasSavedState) restoredFromSavedState = true
        activityCreated = true
    }
}

/**
 * `am kill` records USER_REQUESTED / SUBREASON_KILL_BACKGROUND with the description "kill
 * background"; `ApplicationExitInfo.getDescription()` prefixes the subreason, so apps read
 * "[KILL BACKGROUND] kill background".
 */
fun isBackgroundKill(record: ExitRecord): Boolean =
    record.reason == REASON_USER_REQUESTED && record.description?.contains("kill background") == true

const val REASON_USER_REQUESTED = 10

/** This package's exit records, newest first, read once per process. */
private object ExitRecords {
    @Volatile private var cached: List<ExitRecord>? = null

    fun get(context: Context): List<ExitRecord>? {
        if (Build.VERSION.SDK_INT < 30) return null
        cached?.let { return it }
        val manager = context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager ?: return null
        val records = manager.getHistoricalProcessExitReasons(null, 0, 10).map { info: ApplicationExitInfo ->
            ExitRecord(info.reason, info.description, info.timestamp, info.pid)
        }
        cached = records
        return records
    }
}

fun exitText(record: ExitRecord?, label: String, none: String, restored: Boolean): Reading {
    val restoredText = if (restored) " · activity restored from saved state" else ""
    return if (record == null) {
        Reading.Value("$none$restoredText", muted = !restored)
    } else {
        val description = record.description?.let { " ($it)" } ?: ""
        Reading.Value("$label$description at ${formatTime(record.timestamp)} · pid ${record.pid}$restoredText")
    }
}

fun killReading(context: Context): Reading {
    val records = ExitRecords.get(context) ?: return Reading.Unsupported
    return exitText(
        records.firstOrNull(::isBackgroundKill),
        label = "Killed in the background",
        none = "No background kill recorded",
        restored = ProcessRestore.restoredFromSavedState,
    )
}
