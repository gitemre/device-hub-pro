package com.devicehubpro.verifier

fun statusBarSection(): RowSection = RowSection(
    id = "statusBar",
    title = "Status bar",
    rows = listOf(
        VerifierRow(
            id = "statusBar.demoMode",
            title = "Demo mode",
            source = "Clean status bar · global sysui_demo_allowed, sysui_tuner_demo_on",
            kind = RowKind.KEY,
            detail = "Key values only — SystemUI draws the demo status bar and apps cannot read its state " +
                "(dumpsys DemoModeController needs DUMP). On Android 12+ SystemUI enters demo mode when " +
                "sysui_tuner_demo_on turns 1 (even while sysui_demo_allowed is 0, when it then ignores the " +
                "demo commands) and leaves it when the key turns 0; demo mode another tool started with the " +
                "broadcast alone leaves the key at 0, so this row says Off. The demo clock, battery and " +
                "signal never reach apps: the Battery, Charging and Date & time rows keep the real values.",
            read = { context ->
                demoModeText(global(context, "sysui_demo_allowed"), global(context, "sysui_tuner_demo_on"))
            },
        ),
    ),
)

/** SystemUI reads both keys with getInt(key, 0) != 0; neither is in Settings.java, so apps may read them. */
fun demoModeText(allowed: String?, on: String?): Reading {
    fun flag(raw: String?): Boolean? = when (val value = raw?.trim()) {
        null, "", "null" -> false
        else -> value.toIntOrNull()?.let { it != 0 }
    }
    val isAllowed = flag(allowed) ?: return Reading.Value("Unreadable", muted = true)
    val isOn = flag(on) ?: return Reading.Value("Unreadable", muted = true)
    return Reading.Value(
        when {
            isOn && isAllowed -> "On (sysui_tuner_demo_on = 1)"
            isOn -> "On (sysui_tuner_demo_on = 1) · commands blocked (sysui_demo_allowed = 0)"
            isAllowed -> "Off · allowed (sysui_demo_allowed = 1)"
            else -> "Off"
        },
    )
}
