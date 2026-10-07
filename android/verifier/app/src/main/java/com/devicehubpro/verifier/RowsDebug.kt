package com.devicehubpro.verifier

fun debugSection(): RowSection = RowSection(
    id = "debug",
    title = "Debug",
    rows = listOf(
        keyToggleRow(
            id = "debug.showTaps",
            title = "Show taps",
            source = "Debug ▸ Show taps · system show_touches",
            namespace = "system",
            key = "show_touches",
        ),
        keyToggleRow(
            id = "debug.backgroundANRs",
            title = "Show background ANRs",
            source = "Debug ▸ Show background ANRs · secure anr_show_background",
            namespace = "secure",
            key = "anr_show_background",
        ),
    ),
)
