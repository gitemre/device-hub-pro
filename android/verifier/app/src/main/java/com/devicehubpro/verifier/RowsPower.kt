package com.devicehubpro.verifier

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.os.PowerManager
import androidx.core.content.ContextCompat

fun powerSection(): RowSection = RowSection(
    id = "power",
    title = "Power & battery",
    rows = listOf(
        VerifierRow(
            id = "power.battery",
            title = "Battery",
            source = "Power & battery ▸ Battery · gRPC setBattery",
            kind = RowKind.DIRECT,
            read = { context -> batteryReading(context) },
        ),
        VerifierRow(
            id = "power.charging",
            title = "Charging",
            source = "Power & battery ▸ Charging · gRPC setBattery",
            kind = RowKind.DIRECT,
            read = { context -> chargingReading(context) },
        ),
        VerifierRow(
            id = "power.batterySaver",
            title = "Battery saver",
            source = "Power & battery ▸ Battery saver · cmd power set-mode",
            kind = RowKind.DIRECT,
            detail = "PowerManager.isPowerSaveMode. Android refuses battery saver while a charger " +
                "is connected, so turn Charging off first.",
            read = { context -> batterySaverReading(context) },
        ),
    ),
)

fun batteryText(percent: Int): Reading =
    if (percent in 0..100) Reading.Value("$percent %") else Reading.Value("Unreadable", muted = true)

fun batteryReading(context: Context): Reading {
    val intent = batteryIntent(context) ?: return Reading.Unsupported
    val level = intent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
    val scale = intent.getIntExtra(BatteryManager.EXTRA_SCALE, 100)
    if (level < 0 || scale <= 0) return Reading.Value("Unreadable", muted = true)
    return batteryText(level * 100 / scale)
}

fun chargingText(status: Int): String = when (status) {
    BatteryManager.BATTERY_STATUS_CHARGING -> "Charging"
    BatteryManager.BATTERY_STATUS_FULL -> "Full"
    BatteryManager.BATTERY_STATUS_DISCHARGING -> "Not charging"
    BatteryManager.BATTERY_STATUS_NOT_CHARGING -> "Not charging"
    else -> "Unknown"
}

fun chargingReading(context: Context): Reading {
    val intent = batteryIntent(context) ?: return Reading.Unsupported
    return Reading.Value(chargingText(intent.getIntExtra(BatteryManager.EXTRA_STATUS, -1)))
}

/** The sticky battery broadcast, used for both the level and the charging status. */
private fun batteryIntent(context: Context): Intent? =
    ContextCompat.registerReceiver(
        context,
        null,
        IntentFilter(Intent.ACTION_BATTERY_CHANGED),
        ContextCompat.RECEIVER_NOT_EXPORTED,
    )

fun batterySaverText(powerSave: Boolean, plugged: Boolean?): Reading = when {
    powerSave -> Reading.Value("On")
    plugged == true -> Reading.Value("Off (charging — Android refuses battery saver)")
    else -> Reading.Value("Off")
}

fun batterySaverReading(context: Context): Reading {
    val manager = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
        ?: return Reading.Unsupported
    val plugged = batteryIntent(context)?.let { it.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) != 0 }
    return batterySaverText(manager.isPowerSaveMode, plugged)
}
