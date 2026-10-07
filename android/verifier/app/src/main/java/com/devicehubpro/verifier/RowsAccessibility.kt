package com.devicehubpro.verifier

import android.accessibilityservice.AccessibilityServiceInfo
import android.content.Context
import android.icu.util.ULocale
import android.os.Build
import android.view.View
import android.view.accessibility.AccessibilityManager

fun accessibilitySection(): RowSection = RowSection(
    id = "accessibility",
    title = "Accessibility",
    rows = listOf(
        VerifierRow(
            id = "accessibility.talkBack",
            title = "TalkBack",
            source = "Accessibility ▸ TalkBack · enabled_accessibility_services",
            kind = RowKind.DIRECT,
            detail = "Enabled accessibility services plus touch exploration state.",
            read = { context -> talkBackReading(context) },
        ),
        VerifierRow(
            id = "accessibility.colorFilter",
            title = "Color Filter",
            source = "Accessibility ▸ Color correction · secure accessibility_display_daltonizer_enabled and accessibility_display_daltonizer",
            kind = RowKind.KEY,
            detail = "Key values only — SurfaceFlinger draws the filter at composition, which apps cannot read (screenshots leave it out too).",
            read = { context ->
                colorFilterText(
                    secure(context, "accessibility_display_daltonizer_enabled"),
                    secure(context, "accessibility_display_daltonizer"),
                )
            },
        ),
        keyToggleRow(
            id = "accessibility.increaseContrast",
            title = "Increase Contrast",
            source = "Accessibility ▸ Increase Contrast · secure high_text_contrast_enabled",
            namespace = "secure",
            key = "high_text_contrast_enabled",
        ),
    ),
)

/**
 * A secure key as Android reads it (`Settings.Secure.getIntForUser`): `Integer.parseInt` of the
 * stored string as it is, untrimmed, or null when that throws or the key is unset (the caller then
 * uses the key's default). Kotlin's `toIntOrNull` takes the same text: an optional sign, then
 * `Character.digit` digits, within `Int`.
 */
fun settingInt(raw: String?): Int? = raw?.toIntOrNull()

/** Why a key fell back to its default: unset, empty, or a value `Integer.parseInt` refuses. */
private fun defaultReason(raw: String?): String = when {
    raw == null || raw == "null" -> "unset"
    raw.isEmpty() -> "empty"
    else -> "unreadable"
}

/**
 * Device Hub Pro's Color Filter labels, by the mode ColorDisplayService applies: the switch is on when
 * the enabled key parses to a non-zero integer, and an unset or unparseable mode is 12
 * (`getIntForUser(…, 12)`). Modes 1–3 come from Developer options ▸ Simulate color space; any
 * other mode is one Settings does not offer.
 */
fun colorFilterText(enabled: String?, mode: String?): Reading {
    if ((settingInt(enabled) ?: 0) == 0) return Reading.Value("None")
    val parsed = settingInt(mode)
    val value = parsed ?: 12
    val suffix = if (parsed != null) " · mode $value" else " · mode ${defaultReason(mode)} (12)"
    return when (value) {
        0 -> Reading.Value("Grayscale$suffix")
        11 -> Reading.Value("Red/Green (Protanopia)$suffix")
        12 -> Reading.Value("Green/Red (Deuteranopia)$suffix")
        13 -> Reading.Value("Blue/Yellow (Tritanopia)$suffix")
        1 -> Reading.Value("Simulated Protanopia$suffix")
        2 -> Reading.Value("Simulated Deuteranopia$suffix")
        3 -> Reading.Value("Simulated Tritanopia$suffix")
        else -> Reading.Value("Mode $value", muted = true)
    }
}

fun isTalkBackPackage(packageName: String): Boolean =
    packageName == "com.google.android.marvin.talkback" || packageName.endsWith(".talkback")

fun talkBackText(packages: List<String>, touchExploration: Boolean): Reading {
    val talksBack = packages.any(::isTalkBackPackage)
    return Reading.Value(
        when {
            talksBack && touchExploration -> "On (touch exploration active)"
            talksBack -> "On"
            else -> "Off"
        }
    )
}

fun talkBackReading(context: Context): Reading {
    val manager = context.getSystemService(Context.ACCESSIBILITY_SERVICE) as? AccessibilityManager
        ?: return Reading.Unsupported
    val packages = manager
        .getEnabledAccessibilityServiceList(AccessibilityServiceInfo.FEEDBACK_ALL_MASK)
        .mapNotNull { service -> service.id?.substringBefore('/') }
    return talkBackText(packages, manager.isTouchExplorationEnabled)
}

fun layoutDirectionText(direction: Int): String =
    if (direction == View.LAYOUT_DIRECTION_RTL) "RTL" else "LTR"

/**
 * The direction in effect, then the request. The request is the Global key, which
 * Android copies into the `debug.force_rtl` property (read whenever a direction is
 * computed) at boot, so the direction the request leads to is RTL when the key is on
 * or the language is right to left. A direction that differs, either way, changes at
 * the next restart: the key requested RTL that did not apply, or the key is off while
 * the property still forces RTL. Device Hub Pro's Force RTL row reports the same.
 */
fun forceRtlText(direction: Int, key: String?, property: String?, languageIsRtl: Boolean): Reading {
    val effective = layoutDirectionText(direction)
    val requested = toggleReading(key) == Reading.Value("On")
    val isRtl = direction == View.LAYOUT_DIRECTION_RTL
    val expectsRtl = requested || languageIsRtl
    return Reading.Value(
        when {
            isRtl != expectsRtl && expectsRtl ->
                "$effective · requested, not applied yet (applies after a restart)"
            isRtl != expectsRtl ->
                if (propertyToggle(property) == true) {
                    "$effective · off, still forced by the property until a restart"
                } else {
                    "$effective · off, not applied yet (applies after a restart)"
                }
            requested -> "$effective · forced"
            else -> effective
        }
    )
}

fun forceRtlReading(context: Context): Reading {
    val configuration = context.resources.configuration
    val language = configuration.locales.takeIf { !it.isEmpty }?.get(0)
    return forceRtlText(
        direction = configuration.layoutDirection,
        key = global(context, "debug.force_rtl"),
        property = systemProperty("debug.force_rtl"),
        languageIsRtl = language != null && ULocale.forLocale(language).isRightToLeft,
    )
}
