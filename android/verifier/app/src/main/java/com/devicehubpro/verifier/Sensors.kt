package com.devicehubpro.verifier

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager

enum class SensorKind(val type: Int, val label: String, val unit: String, val axes: Int) {
    ACCELERATION(Sensor.TYPE_ACCELEROMETER, "Acceleration", "m/s²", 3),
    GYROSCOPE(Sensor.TYPE_GYROSCOPE, "Gyroscope", "rad/s", 3),
    MAGNETIC_FIELD(Sensor.TYPE_MAGNETIC_FIELD, "Magnetic field", "μT", 3),
    ORIENTATION(Sensor.TYPE_ORIENTATION, "Orientation", "°", 3),
    TEMPERATURE(Sensor.TYPE_AMBIENT_TEMPERATURE, "Temperature", "°C", 1),
    PROXIMITY(Sensor.TYPE_PROXIMITY, "Proximity", "cm", 1),
    LIGHT(Sensor.TYPE_LIGHT, "Light", "lx", 1),
    PRESSURE(Sensor.TYPE_PRESSURE, "Pressure", "hPa", 1),
    HUMIDITY(Sensor.TYPE_RELATIVE_HUMIDITY, "Humidity", "%", 1),
    HEART_RATE(Sensor.TYPE_HEART_RATE, "Heart rate", "bpm", 1),
}

data class SensorInfo(val type: Int, val name: String)

fun matchSensor(kind: SensorKind, sensors: List<SensorInfo>): SensorInfo? =
    sensors.firstOrNull { it.type == kind.type }
        ?: sensors.firstOrNull { it.name.contains(kind.label, ignoreCase = true) }

interface SensorValues {
    fun value(type: Int): FloatArray?
    fun sensors(): List<SensorInfo> = emptyList()
    fun orientationDegrees(): FloatArray? = null

    object None : SensorValues {
        override fun value(type: Int): FloatArray? = null
    }
}

class AndroidSensorValues(context: Context) : SensorValues, SensorEventListener {

    private val manager = context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
    private val latest = mutableMapOf<Int, FloatArray>()

    fun start(types: List<Int>) {
        stop()
        for (type in types) {
            val sensor = manager.getDefaultSensor(type) ?: continue
            manager.registerListener(this, sensor, SensorManager.SENSOR_DELAY_UI)
        }
    }

    fun stop() {
        manager.unregisterListener(this)
    }

    override fun value(type: Int): FloatArray? = latest[type]

    override fun sensors(): List<SensorInfo> =
        manager.getSensorList(Sensor.TYPE_ALL).map { SensorInfo(it.type, it.name) }

    override fun orientationDegrees(): FloatArray? {
        val accelerometer = value(Sensor.TYPE_ACCELEROMETER) ?: return null
        val magnetic = value(Sensor.TYPE_MAGNETIC_FIELD) ?: return null
        val rotation = FloatArray(9)
        if (!SensorManager.getRotationMatrix(rotation, null, accelerometer, magnetic)) return null
        val orientation = FloatArray(3)
        SensorManager.getOrientation(rotation, orientation)
        return orientation
    }

    override fun onSensorChanged(event: SensorEvent) {
        latest[event.sensor.type] = event.values.copyOf()
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit
}
