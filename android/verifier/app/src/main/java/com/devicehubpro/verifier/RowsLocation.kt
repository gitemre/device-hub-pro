package com.devicehubpro.verifier

import android.Manifest
import android.content.Context
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import java.util.Locale

fun locationSection(caps: Capabilities, location: LocationValues): RowSection = RowSection(
    id = "location",
    title = "Location",
    applicable = caps.isEmulator && caps.hasLocation,
    rows = listOf(
        VerifierRow(
            id = "location.lastFix",
            title = "Location",
            source = "Location ▸ Location · gRPC setLocation",
            kind = RowKind.DIRECT,
            detail = "The GPS provider's last fix, kept live while the panel is open.",
            permission = Manifest.permission.ACCESS_FINE_LOCATION,
            read = { _ -> location.reading() },
        ),
    ),
)

interface LocationValues {
    fun reading(): Reading

    object None : LocationValues {
        override fun reading(): Reading = locationText(null, null, null, null)
    }
}

/** Keeps a GPS request while the panel is visible so injected fixes actually land. */
class LocationTracker(context: Context) : LocationValues, LocationListener {

    private val manager = context.getSystemService(Context.LOCATION_SERVICE) as? LocationManager

    @Volatile
    private var latest: Location? = null

    private var started = false

    fun start() {
        val manager = manager ?: return
        if (started) return
        latest = current()
        try {
            manager.requestLocationUpdates(LocationManager.GPS_PROVIDER, 1_000L, 0f, this)
            started = true
        } catch (exception: SecurityException) {
            // The row shows NeedsPermission; refreshRows retries once the grant lands.
        }
    }

    fun stop() {
        try {
            manager?.removeUpdates(this)
        } catch (exception: Exception) {
            // Nothing to remove.
        }
        started = false
    }

    override fun onLocationChanged(location: Location) {
        latest = location
    }

    override fun reading(): Reading =
        locationText(latest?.latitude, latest?.longitude, latest?.accuracy, latest?.time)

    private fun current(): Location? = try {
        manager?.getLastKnownLocation(LocationManager.GPS_PROVIDER)
    } catch (exception: SecurityException) {
        null
    } catch (exception: IllegalArgumentException) {
        null
    }
}

fun locationText(latitude: Double?, longitude: Double?, accuracy: Float?, at: Long?): Reading =
    if (latitude == null || longitude == null) {
        Reading.Value("No fix yet", muted = true)
    } else {
        val accuracyText = accuracy?.let { String.format(Locale.US, " ± %.0f m", it) } ?: ""
        val timeText = at?.let { " · ${formatTime(it)}" } ?: ""
        Reading.Value(
            String.format(Locale.US, "%.5f, %.5f%s%s", latitude, longitude, accuracyText, timeText)
        )
    }
