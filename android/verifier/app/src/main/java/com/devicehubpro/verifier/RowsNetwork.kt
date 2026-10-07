package com.devicehubpro.verifier

import android.Manifest
import android.bluetooth.BluetoothManager
import android.content.Context
import android.net.ConnectivityManager
import android.net.wifi.WifiManager
import android.os.Build
import android.telephony.TelephonyManager

fun networkSection(caps: Capabilities): RowSection = RowSection(
    id = "network",
    title = "Network",
    rows = listOf(
        VerifierRow(
            id = "network.wifi",
            title = "Wi-Fi",
            source = "Network ▸ Wi-Fi · svc wifi",
            kind = RowKind.DIRECT,
            read = { context -> wifiReading(context) },
        ),
        VerifierRow(
            id = "network.bluetooth",
            title = "Bluetooth",
            source = "Network ▸ Bluetooth · svc bluetooth",
            kind = RowKind.DIRECT,
            permission = if (Build.VERSION.SDK_INT >= 31) Manifest.permission.BLUETOOTH_CONNECT else null,
            read = { context -> bluetoothReading(context) },
        ),
        VerifierRow(
            id = "network.airplane",
            title = "Airplane mode",
            source = "Network ▸ Airplane mode · cmd connectivity airplane-mode",
            kind = RowKind.DIRECT,
            read = { context -> toggleReading(global(context, "airplane_mode_on")) },
        ),
        VerifierRow(
            id = "network.mobileData",
            title = "Mobile data",
            source = "Network ▸ Mobile data · svc data",
            kind = RowKind.DIRECT,
            permission = Manifest.permission.READ_PHONE_STATE,
            read = { context -> mobileDataReading(context) },
        ),
        VerifierRow(
            id = "network.dataSaver",
            title = "Data Saver",
            source = "Network ▸ Data Saver · cmd netpolicy set restrict-background",
            kind = RowKind.DIRECT,
            read = { context -> dataSaverReading(context) },
        ),
    ),
)

fun wifiStateText(state: Int): String = when (state) {
    WifiManager.WIFI_STATE_ENABLED -> "On"
    WifiManager.WIFI_STATE_DISABLED -> "Off"
    WifiManager.WIFI_STATE_ENABLING -> "Turning on"
    WifiManager.WIFI_STATE_DISABLING -> "Turning off"
    else -> "Unknown"
}

fun wifiReading(context: Context): Reading {
    val manager = context.getSystemService(Context.WIFI_SERVICE) as? WifiManager
        ?: return Reading.Unsupported
    @Suppress("DEPRECATION")
    return Reading.Value(wifiStateText(manager.wifiState))
}

fun bluetoothReading(context: Context): Reading {
    val manager = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
    val adapter = manager?.adapter ?: return Reading.Unsupported
    return try {
        Reading.Value(if (adapter.isEnabled) "On" else "Off")
    } catch (exception: SecurityException) {
        Reading.NeedsPermission
    }
}

fun mobileDataReading(context: Context): Reading {
    val telephony = context.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager
        ?: return Reading.Unsupported
    return try {
        Reading.Value(if (telephony.isDataEnabled) "On" else "Off")
    } catch (exception: SecurityException) {
        // isDataEnabled needs READ_PHONE_STATE; the key is the documented fallback.
        toggleReading(global(context, "mobile_data"))
    }
}

fun dataSaverText(status: Int): String = when (status) {
    ConnectivityManager.RESTRICT_BACKGROUND_STATUS_ENABLED -> "On"
    ConnectivityManager.RESTRICT_BACKGROUND_STATUS_WHITELISTED -> "On (allowlisted)"
    ConnectivityManager.RESTRICT_BACKGROUND_STATUS_DISABLED -> "Off"
    else -> "Unknown"
}

fun onOffText(enabled: Boolean?): Reading = when (enabled) {
    true -> Reading.Value("On")
    false -> Reading.Value("Off")
    null -> Reading.Value("Unreadable", muted = true)
}

fun dataSaverReading(context: Context): Reading {
    val manager = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
        ?: return Reading.Unsupported
    return Reading.Value(dataSaverText(manager.restrictBackgroundStatus))
}
