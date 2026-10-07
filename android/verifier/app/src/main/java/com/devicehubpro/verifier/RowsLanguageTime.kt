package com.devicehubpro.verifier

import android.app.LocaleManager
import android.content.Context
import android.content.res.Configuration
import android.content.res.Resources
import android.os.Build
import android.os.LocaleList
import android.os.SystemClock
import android.text.TextUtils
import android.text.format.DateFormat
import android.view.View
import androidx.annotation.RequiresApi
import java.text.SimpleDateFormat
import java.time.DateTimeException
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import kotlin.math.abs

fun languageTimeSection(): RowSection = RowSection(
    id = "languageTime",
    title = "Language & time",
    rows = listOf(
        VerifierRow(
            id = "languageTime.language",
            title = "Language",
            source = "Language & time ▸ Language · cmd locale set-device-locale / app_process helper",
            kind = RowKind.DIRECT,
            detail = "The system language list (LocaleManager.getSystemLocales on Android 13+, which a " +
                "per-app language cannot mask; the system resources before) and its layout direction.",
            read = { context -> systemLanguageReading(context) },
        ),
        VerifierRow(
            id = "languageTime.forceRtl",
            title = "Force RTL",
            source = "Language & time ▸ Force RTL · global and property debug.force_rtl",
            kind = RowKind.DIRECT,
            detail = "The layout direction this app runs with, then the stored request. Device Hub Pro " +
                "pushes the languages again so Android recomputes the direction at once (Android 8+); " +
                "a direction that does not follow the request yet (on or off) changes at the next restart.",
            read = { context -> forceRtlReading(context) },
        ),
        keyToggleRow(
            id = "languageTime.autoTime",
            title = "Automatic date & time",
            source = "Language & time ▸ Date & time (turns automatic time off) · global auto_time",
            namespace = "global",
            key = "auto_time",
            whenUnset = true,
            detail = "Key value only — the time detector (a system API) applies it; the Date & time row " +
                "shows the clock moving back to network time.",
        ),
        VerifierRow(
            id = "languageTime.dateTime",
            title = "Date & time",
            source = "Language & time ▸ Date & time · cmd alarm set-time",
            kind = RowKind.DIRECT,
            detail = "The wall clock this app reads, and on Android 13+ its offset from network time " +
                "(SystemClock.currentNetworkTimeClock).",
            read = { _ -> dateTimeReading() },
        ),
        keyToggleRow(
            id = "languageTime.autoTimeZone",
            title = "Automatic time zone",
            source = "Language & time ▸ Time zone (turns automatic time zone off; Automatic turns it on) · global auto_time_zone",
            namespace = "global",
            key = "auto_time_zone",
            whenUnset = true,
            detail = "Key value only — the time zone detector (a system API) applies it; the Time zone " +
                "row shows the zone moving to the network's.",
        ),
        VerifierRow(
            id = "languageTime.timeZone",
            title = "Time zone",
            source = "Language & time ▸ Time zone · cmd alarm set-timezone",
            kind = RowKind.DIRECT,
            detail = "TimeZone.getDefault(), which the system updates in every app on a zone change.",
            read = { _ -> timeZoneReading() },
        ),
        VerifierRow(
            id = "languageTime.timeFormat24",
            title = "24-hour time",
            source = "Language & time ▸ 24-hour time · system time_12_24",
            kind = RowKind.DIRECT,
            detail = "DateFormat.is24HourFormat against the system language (what the status bar " +
                "uses); the status bar itself follows at the next minute.",
            read = { context -> timeFormatReading(context) },
        ),
    ),
)

/** `tr-TR, de-DE, en-US · LTR`. */
fun languageText(tags: String, rightToLeft: Boolean): Reading {
    val list = tags.split(',').map { it.trim() }.filter { it.isNotEmpty() }
    if (list.isEmpty()) return Reading.Value("Unreadable", muted = true)
    return Reading.Value("${list.joinToString(", ")} · ${if (rightToLeft) "RTL" else "LTR"}")
}

fun isRightToLeft(locales: LocaleList): Boolean =
    !locales.isEmpty && TextUtils.getLayoutDirectionFromLocale(locales[0]) == View.LAYOUT_DIRECTION_RTL

/** The system list: a per-app language changes this process's configuration and, with it,
 * Resources.getSystem(), so Android 13+ asks LocaleManager instead. */
fun systemLocales(context: Context): LocaleList =
    if (Build.VERSION.SDK_INT >= 33) {
        systemLocalesFromManager(context) ?: Resources.getSystem().configuration.locales
    } else {
        Resources.getSystem().configuration.locales
    }

@RequiresApi(33)
private fun systemLocalesFromManager(context: Context): LocaleList? =
    context.getSystemService(LocaleManager::class.java)?.systemLocales

fun systemLanguageReading(context: Context): Reading {
    val locales = systemLocales(context)
    return languageText(locales.toLanguageTags(), isRightToLeft(locales))
}

/**
 * `Sat 26 Sep 13:08 · 1 h ahead of network time`. Minutes only, so the row changes (and
 * flashes) when the clock or its offset really moves, not on every tick.
 */
fun dateTimeText(wallMillis: Long, zone: TimeZone, networkMillis: Long?): Reading {
    val format = SimpleDateFormat("EEE d MMM HH:mm", Locale.US).apply { timeZone = zone }
    val clock = format.format(Date(wallMillis))
    val offset = networkMillis?.let { offsetText(wallMillis - it) } ?: "no network time"
    return Reading.Value("$clock · $offset")
}

/**
 * How far the wall clock is from network time. Within a minute is in step: the emulator's
 * network time itself trails the wall clock by a few seconds.
 */
fun offsetText(deltaMillis: Long): String {
    val seconds = abs(deltaMillis) / 1000
    if (seconds < 60) return "in step with network time"
    val direction = if (deltaMillis > 0) "ahead of" else "behind"
    val days = seconds / 86_400
    val hours = (seconds % 86_400) / 3600
    val minutes = (seconds % 3600) / 60
    val parts = buildList {
        if (days > 0) add(if (days == 1L) "1 day" else "$days days")
        if (hours > 0) add("$hours h")
        if (minutes > 0 && days == 0L) add("$minutes min")
    }
    return "${parts.joinToString(" ")} $direction network time"
}

fun dateTimeReading(): Reading {
    val network = if (Build.VERSION.SDK_INT >= 33) networkTimeMillis() else null
    return dateTimeText(System.currentTimeMillis(), TimeZone.getDefault(), network)
}

@RequiresApi(33)
private fun networkTimeMillis(): Long? = try {
    SystemClock.currentNetworkTimeClock().millis()
} catch (exception: DateTimeException) {
    null
}

/** `Asia/Tokyo · GMT+09:00`. */
fun timeZoneText(id: String, offsetMillis: Int): Reading {
    val minutes = abs(offsetMillis) / 60_000
    val label = if (offsetMillis == 0) {
        "GMT"
    } else {
        String.format(Locale.US, "GMT%s%02d:%02d", if (offsetMillis < 0) "-" else "+", minutes / 60, minutes % 60)
    }
    return Reading.Value("$id · $label")
}

fun timeZoneReading(): Reading {
    val zone = TimeZone.getDefault()
    return timeZoneText(zone.id, zone.getOffset(System.currentTimeMillis()))
}

/** `24-hour (time_12_24 = 24)` or `12-hour (language default)`. */
fun timeFormatText(is24: Boolean, raw: String?): Reading {
    val format = if (is24) "24-hour" else "12-hour"
    val source = when (raw?.trim()) {
        "12", "24" -> "time_12_24 = ${raw.trim()}"
        null, "", "null" -> "language default"
        else -> "time_12_24 = ${raw.trim()}, unreadable"
    }
    return Reading.Value("$format ($source)")
}

/** DateFormat.is24HourFormat on a context that runs the system language, so a per-app
 * language cannot change the default it falls back to when the key is unset. */
fun timeFormatReading(context: Context): Reading {
    val configuration = Configuration(context.resources.configuration).apply { setLocales(systemLocales(context)) }
    val systemContext = context.createConfigurationContext(configuration)
    return timeFormatText(DateFormat.is24HourFormat(systemContext), system(context, "time_12_24"))
}
