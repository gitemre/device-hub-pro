package com.devicehubpro.verifier

import android.content.Context
import android.content.res.Configuration
import android.media.AudioManager
import java.util.Locale

fun displaySection(): RowSection = RowSection(
    id = "display",
    title = "Display & sound",
    rows = listOf(
        VerifierRow(
            id = "display.appearance",
            title = "Appearance",
            source = "Display & sound ▸ Appearance · cmd uimode night",
            kind = RowKind.DIRECT,
            detail = "The current night mode; the verifier's own theme flips with it.",
            read = { context -> appearanceReading(context) },
        ),
        VerifierRow(
            id = "display.textSize",
            title = "Text Size",
            source = "Display & sound ▸ Text Size · system font_scale",
            kind = RowKind.DIRECT,
            detail = "The verifier's own text scales with it.",
            read = { context -> textSizeReading(context) },
        ),
        VerifierRow(
            id = "display.reduceMotion",
            title = "Reduce Motion",
            source = "Display & sound ▸ Reduce Motion · window/transition/animator scales",
            kind = RowKind.KEY,
            detail = "All three scales at 0 means animations are off; the row highlight loses its animation too.",
            read = { context -> reduceMotionReading(context) },
        ),
        VerifierRow(
            id = "display.showBorders",
            title = "Show Borders",
            source = "Display & sound ▸ Show Borders · debug.layout property",
            kind = RowKind.DIRECT,
            detail = "The property every app's view root reads; while it is on, this app's own " +
                "rows draw their layout bounds too.",
            read = { _ -> showBordersText(systemProperty("debug.layout")) },
        ),
        VerifierRow(
            id = "display.sound",
            title = "Sound",
            source = "Display & sound ▸ Sound · cmd media_session volume",
            kind = RowKind.DIRECT,
            detail = "The music stream volume read through AudioManager.",
            read = { context -> soundReading(context) },
        ),
    ),
)

fun nightModeText(uiMode: Int): String = when (uiMode and Configuration.UI_MODE_NIGHT_MASK) {
    Configuration.UI_MODE_NIGHT_YES -> "Dark"
    Configuration.UI_MODE_NIGHT_NO -> "Light"
    else -> "System (unknown)"
}

fun appearanceReading(context: Context): Reading =
    Reading.Value(nightModeText(context.resources.configuration.uiMode))

fun fontScaleText(scale: Float): String =
    String.format(Locale.US, "%.2f×", scale)

fun textSizeReading(context: Context): Reading =
    Reading.Value(fontScaleText(context.resources.configuration.fontScale))

/** One animation scale; null is the framework's 1.0 default, garbage has no reading. */
fun animationScale(raw: String?): Double? {
    val text = raw?.trim()?.lowercase()
    if (text == null || text == "null") return 1.0
    val value = text.toDoubleOrNull()
    return if (value != null && value >= 0) value else null
}

fun reduceMotionText(window: String?, transition: String?, animator: String?): Reading {
    val scales = listOf(window, transition, animator).map(::animationScale)
    if (scales.any { it == null }) return Reading.Value("Unreadable", muted = true)
    val allZero = scales.all { it == 0.0 }
    return Reading.Value(if (allZero) "On (all animation scales are 0)" else "Off")
}

fun reduceMotionReading(context: Context): Reading = reduceMotionText(
    window = global(context, "window_animation_scale"),
    transition = global(context, "transition_animation_scale"),
    animator = global(context, "animator_duration_scale"),
)

/** The row-highlight fade, scaled by the platform animator scale; 0 means no fade. */
fun flashDurationFor(animatorScale: Double?): Long {
    val scale = animatorScale ?: 1.0
    if (scale <= 0.0) return 0L
    return (600.0 * scale).toLong()
}

fun showBordersText(property: String?): Reading = when (propertyToggle(property)) {
    true -> Reading.Value("On (debug.layout = ${property?.trim()})")
    false -> Reading.Value("Off")
    null -> Reading.Value("Unreadable", muted = true)
}

fun soundReading(context: Context): Reading {
    val manager = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
        ?: return Reading.Unsupported
    val current = manager.getStreamVolume(AudioManager.STREAM_MUSIC)
    val maximum = manager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
    return Reading.Value("$current / $maximum")
}
