package com.devicehubpro.verifier

import android.content.Context
import android.content.pm.PackageManager
import android.hardware.SensorManager
import android.os.Build
import androidx.biometric.BiometricManager

enum class BiometricState { READY, NONE_ENROLLED, UNSUPPORTED }

interface Capabilities {
    val isEmulator: Boolean
    val hasTelephony: Boolean
    val hasLocation: Boolean
    val biometricState: BiometricState
    fun hasSensor(type: Int): Boolean
}

class AndroidCapabilities(private val context: Context) : Capabilities {

    override val isEmulator: Boolean =
        Build.FINGERPRINT.contains("generic", ignoreCase = true) ||
            Build.HARDWARE.contains("goldfish", ignoreCase = true) ||
            Build.HARDWARE.contains("ranchu", ignoreCase = true) ||
            Build.PRODUCT.contains("sdk", ignoreCase = true)

    override val hasTelephony: Boolean =
        context.packageManager.hasSystemFeature(PackageManager.FEATURE_TELEPHONY)

    override val hasLocation: Boolean =
        context.packageManager.hasSystemFeature(PackageManager.FEATURE_LOCATION_GPS) ||
            context.packageManager.hasSystemFeature(PackageManager.FEATURE_LOCATION)

    override val biometricState: BiometricState
        get() = when (
            BiometricManager.from(context)
                .canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_WEAK)
        ) {
            BiometricManager.BIOMETRIC_SUCCESS -> BiometricState.READY
            BiometricManager.BIOMETRIC_ERROR_NONE_ENROLLED -> BiometricState.NONE_ENROLLED
            else -> BiometricState.UNSUPPORTED
        }

    override fun hasSensor(type: Int): Boolean =
        (context.getSystemService(Context.SENSOR_SERVICE) as? SensorManager)
            ?.getDefaultSensor(type) != null
}
