package com.devicehubpro.verifier

import android.Manifest
import android.hardware.Sensor
import java.util.Locale

fun sensorsSection(caps: Capabilities, values: SensorValues): RowSection = RowSection(
    id = "sensors",
    title = "Sensors",
    applicable = caps.isEmulator,
    rows = SensorKind.entries.map { kind ->
        VerifierRow(
            id = "sensors.${kind.name.lowercase()}",
            title = kind.label,
            source = "Sensors ▸ ${kind.label} · gRPC setSensor",
            kind = RowKind.DIRECT,
            detail = if (kind == SensorKind.ORIENTATION) {
                "Native orientation sensor when exposed, otherwise derived from accelerometer + magnetic field."
            } else {
                null
            },
            permission = if (kind == SensorKind.HEART_RATE) Manifest.permission.BODY_SENSORS else null,
            read = { _ -> sensorReading(kind, caps, values) },
        )
    },
)

fun sensorValuesText(kind: SensorKind, values: FloatArray?): Reading {
    if (values == null || values.isEmpty()) {
        return Reading.Value("No reading yet", muted = true)
    }
    val labels = if (kind.axes == 3) listOf("x", "y", "z") else listOf("value")
    val parts = values.take(kind.axes).mapIndexed { index, value ->
        String.format(Locale.US, "%s %.2f", labels[index], value)
    }
    return Reading.Value(parts.joinToString(" · ") + " " + kind.unit)
}

fun sensorReading(
    kind: SensorKind,
    caps: Capabilities,
    values: SensorValues,
): Reading {
    val matched = matchSensor(kind, values.sensors())
    val nativeType = matched?.type ?: kind.type
    values.value(nativeType)?.let { return sensorValuesText(kind, it) }
    if (kind == SensorKind.ORIENTATION) {
        values.orientationDegrees()?.let { return sensorValuesText(kind, it) }
    }
    val available = matched != null ||
        caps.hasSensor(kind.type) ||
        (kind == SensorKind.ORIENTATION &&
            caps.hasSensor(Sensor.TYPE_ACCELEROMETER) &&
            caps.hasSensor(Sensor.TYPE_MAGNETIC_FIELD))
    return if (available) Reading.Value("No reading yet", muted = true) else Reading.Unsupported
}
