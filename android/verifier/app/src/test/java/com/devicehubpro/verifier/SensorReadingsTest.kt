package com.devicehubpro.verifier

import android.hardware.Sensor
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SensorReadingsTest {

    @Test
    fun `matching prefers the sensor type and falls back to the name`() {
        val sensors = listOf(
            SensorInfo(Sensor.TYPE_LIGHT, "Goldfish Light"),
            SensorInfo(Sensor.TYPE_ORIENTATION + 100, "Goldfish Orientation"),
        )
        assertEquals(
            "Goldfish Light",
            matchSensor(SensorKind.LIGHT, sensors)?.name,
        )
        assertEquals(
            "Goldfish Orientation",
            matchSensor(SensorKind.ORIENTATION, sensors)?.name,
        )
        assertEquals(null, matchSensor(SensorKind.PRESSURE, sensors))
    }

    @Test
    fun `three-axis values render with labels and a unit`() {
        val reading = sensorValuesText(SensorKind.ACCELERATION, floatArrayOf(1f, -2.5f, 0.25f))
        assertEquals("x 1.00 · y -2.50 · z 0.25 m/s²", (reading as Reading.Value).text)
    }

    @Test
    fun `single-axis values render with the unit`() {
        val reading = sensorValuesText(SensorKind.LIGHT, floatArrayOf(12f))
        assertEquals("value 12.00 lx", (reading as Reading.Value).text)
    }

    @Test
    fun `missing values read as muted`() {
        val reading = sensorValuesText(SensorKind.LIGHT, null)
        assertTrue((reading as Reading.Value).muted)
    }

    @Test
    fun `the sensors section is emulator gated and lists the ten kinds`() {
        val section = buildSections(FakeCapabilities(isEmulator = true)).first { it.id == "sensors" }
        assertEquals(10, section.rows.size)
        assertEquals("Sensors", section.title)
        val phone = buildSections(FakeCapabilities(isEmulator = false)).first { it.id == "sensors" }
        assertTrue(!phone.applicable)
    }

    @Test
    fun `orientation falls back to the derived value when no native sensor exists`() {
        val caps = FakeCapabilities(
            sensors = setOf(Sensor.TYPE_ACCELEROMETER, Sensor.TYPE_MAGNETIC_FIELD),
        )
        val values = FakeSensorValues(
            acceleration = floatArrayOf(0f, 9.8f, 0f),
            magnetic = floatArrayOf(0f, 5f, -48f),
            orientation = floatArrayOf(0.1f, 0.2f, 0.3f),
            sensors = listOf(
                SensorInfo(Sensor.TYPE_ACCELEROMETER, "Fake Accelerometer"),
                SensorInfo(Sensor.TYPE_MAGNETIC_FIELD, "Fake Magnetic"),
            ),
        )
        assertEquals(
            "x 0.10 · y 0.20 · z 0.30 °",
            (sensorReading(SensorKind.ORIENTATION, caps, values) as Reading.Value).text,
        )
    }

    @Test
    fun `a sensor with no native reading reads as unsupported when nothing matches`() {
        val reading = sensorReading(SensorKind.PRESSURE, FakeCapabilities(), FakeSensorValues())
        assertEquals(Reading.Unsupported, reading)
    }

    @Test
    fun `a matched sensor reads through the matched type`() {
        val caps = FakeCapabilities(sensors = setOf(Sensor.TYPE_LIGHT))
        val values = FakeSensorValues(
            light = floatArrayOf(12f),
            sensors = listOf(SensorInfo(Sensor.TYPE_LIGHT, "Fake Light")),
        )
        assertEquals("value 12.00 lx", (sensorReading(SensorKind.LIGHT, caps, values) as Reading.Value).text)
    }
}

private class FakeSensorValues(
    private val acceleration: FloatArray? = null,
    private val magnetic: FloatArray? = null,
    private val orientation: FloatArray? = null,
    private val light: FloatArray? = null,
    private val sensors: List<SensorInfo> = emptyList(),
) : SensorValues {
    override fun value(type: Int): FloatArray? = when (type) {
        android.hardware.Sensor.TYPE_ACCELEROMETER -> acceleration
        android.hardware.Sensor.TYPE_MAGNETIC_FIELD -> magnetic
        android.hardware.Sensor.TYPE_LIGHT -> light
        else -> null
    }

    override fun sensors(): List<SensorInfo> = sensors

    override fun orientationDegrees(): FloatArray? = orientation
}
