package com.devicehubpro.verifier

import android.content.Context

fun formFactorSection(caps: Capabilities): RowSection = RowSection(
    id = "formFactor",
    title = "Form factor",
    applicable = caps.isEmulator,
    rows = listOf(
        VerifierRow(
            id = "formFactor.window",
            title = "Preset",
            source = "Form factor ▸ Preset · gRPC resize",
            kind = RowKind.DIRECT,
            detail = "The window size the applied preset produced.",
            read = { context -> windowReading(context) },
        ),
    ),
)

fun windowText(widthDp: Int, heightDp: Int, densityDpi: Int, smallestWidthDp: Int): String =
    "${widthDp}×${heightDp} dp · $densityDpi dpi · sw${smallestWidthDp}dp"

fun windowReading(context: Context): Reading {
    val configuration = context.resources.configuration
    return Reading.Value(
        windowText(
            widthDp = configuration.screenWidthDp,
            heightDp = configuration.screenHeightDp,
            densityDpi = configuration.densityDpi,
            smallestWidthDp = configuration.smallestScreenWidthDp,
        )
    )
}
