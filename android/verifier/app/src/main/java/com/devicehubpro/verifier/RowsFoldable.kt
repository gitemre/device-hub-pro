package com.devicehubpro.verifier

import android.hardware.Sensor
import java.util.Locale

/**
 * Device Hub Pro's PostureKind: labels and hinge ranges as the foldable AVDs define them
 * (`hw.sensor.hinge_angles_posture_definitions=0-30, 30-150, 150-180`).
 */
enum class Posture(val label: String) {
    CLOSED("Closed"),
    HALF_OPENED("Half"),
    OPENED("Opened"),
    UNKNOWN("Unknown"),
}

fun postureFor(hingeDegrees: Float?): Posture = when {
    hingeDegrees == null -> Posture.UNKNOWN
    hingeDegrees < 30f -> Posture.CLOSED
    hingeDegrees < 150f -> Posture.HALF_OPENED
    else -> Posture.OPENED
}

fun hingeText(degrees: Float?): Reading =
    if (degrees == null) {
        Reading.Value("No reading yet", muted = true)
    } else {
        Reading.Value(String.format(Locale.US, "%.1f°", degrees))
    }

fun foldableSection(caps: Capabilities, values: SensorValues): RowSection = RowSection(
    id = "foldable",
    title = "Foldable",
    applicable = caps.isEmulator && caps.hasSensor(Sensor.TYPE_HINGE_ANGLE),
    rows = listOf(
        VerifierRow(
            id = "foldable.posture",
            title = "Posture",
            source = "Stage fold strip · gRPC posture",
            kind = RowKind.DIRECT,
            detail = "Derived from the hinge angle: Closed below 30°, Half to 150°, Opened above.",
            read = { _ ->
                val degrees = values.value(Sensor.TYPE_HINGE_ANGLE)?.firstOrNull()
                Reading.Value(postureFor(degrees).label)
            },
        ),
        VerifierRow(
            id = "foldable.hinge",
            title = "Hinge angle",
            source = "Stage fold strip · gRPC hinge",
            kind = RowKind.DIRECT,
            read = { _ -> hingeText(values.value(Sensor.TYPE_HINGE_ANGLE)?.firstOrNull()) },
        ),
    ),
)
