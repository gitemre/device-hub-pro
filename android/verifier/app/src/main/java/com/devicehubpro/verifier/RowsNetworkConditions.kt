package com.devicehubpro.verifier

import android.Manifest
import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Build
import android.os.SystemClock
import android.telephony.NetworkRegistrationInfo
import android.telephony.ServiceState
import android.telephony.TelephonyManager
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * The Network conditions rows: what apps see of the guest's tc shaping (speed and latency, on
 * whichever interface the default route uses) and of the emulator's meter. Every row here
 * reads together with the Data path row (Device Hub Pro's caption under Speed).
 */
fun networkConditionsSection(caps: Capabilities, latency: ConnectLatencyProbe): RowSection = RowSection(
    id = "networkConditions",
    title = "Network conditions",
    applicable = caps.isEmulator,
    rows = listOf(
        VerifierRow(
            id = "networkConditions.dataPath",
            title = "Data path",
            source = "Network conditions ▸ Speed caption (data path) · svc wifi / svc data",
            kind = RowKind.DIRECT,
            detail = "The transport of ConnectivityManager's active network. Speed and latency " +
                "shape whichever transport that is.",
            read = { context -> dataPathReading(context) },
        ),
        VerifierRow(
            id = "networkConditions.connectionLatency",
            title = "Connection latency",
            source = "Network conditions ▸ Connection latency · tc netem delay (guest, both directions)",
            kind = RowKind.DIRECT,
            detail = "Median time of the last three TCP connects to 8.8.8.8:53, one every 3 s off the " +
                "main thread. An IPv4 literal avoids DNS. A connect is one round trip: " +
                "about 40 ms without a delay; at least the minimum with one.",
            read = { context -> latency.reading(transportName(context)) },
        ),
        VerifierRow(
            id = "networkConditions.meteredMobileData",
            title = "Metered mobile data",
            source = "Network conditions ▸ Metered mobile data · emu gsm meter",
            kind = RowKind.DIRECT,
            detail = "NET_CAPABILITY_TEMPORARILY_NOT_METERED on the mobile network, next to " +
                "isActiveNetworkMetered(), which gsm meter off does not change.",
            read = { context -> meteredReading(context) },
        ),
    ),
)

// MARK: - Data path

fun transportText(caps: NetworkCapabilitiesView?): String = when {
    caps == null -> "No network"
    caps.cellular -> "Mobile data"
    caps.wifi -> "Wi-Fi"
    caps.ethernet -> "Ethernet"
    else -> "Other"
}

/** The transports and flags the rows read, apart from the framework class (unit-testable). */
data class NetworkCapabilitiesView(
    val cellular: Boolean,
    val wifi: Boolean,
    val ethernet: Boolean = false,
    val temporarilyNotMetered: Boolean? = null,
    val notSuspended: Boolean? = null,
)

private fun connectivity(context: Context): ConnectivityManager? =
    context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager

private fun view(capabilities: NetworkCapabilities?): NetworkCapabilitiesView? = capabilities?.let {
    NetworkCapabilitiesView(
        cellular = it.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR),
        wifi = it.hasTransport(NetworkCapabilities.TRANSPORT_WIFI),
        ethernet = it.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET),
        temporarilyNotMetered = if (Build.VERSION.SDK_INT >= 30) {
            it.hasCapability(NetworkCapabilities.NET_CAPABILITY_TEMPORARILY_NOT_METERED)
        } else {
            null
        },
        notSuspended = if (Build.VERSION.SDK_INT >= 28) {
            it.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_SUSPENDED)
        } else {
            null
        },
    )
}

fun transportName(context: Context): String {
    val manager = connectivity(context) ?: return "No network"
    return transportText(view(manager.activeNetwork?.let { manager.getNetworkCapabilities(it) }))
}

fun dataPathText(transport: String): Reading = when (transport) {
    "Mobile data" -> Reading.Value("Mobile data · shaped by the emulator")
    "No network" -> Reading.Value("No network", muted = true)
    else -> Reading.Value("$transport · not shaped")
}

fun dataPathReading(context: Context): Reading {
    if (connectivity(context) == null) return Reading.Unsupported
    return dataPathText(transportName(context))
}

/** The mobile network's capabilities, whether or not it is the default network. */
private fun cellularCapabilities(context: Context): NetworkCapabilitiesView? {
    val manager = connectivity(context) ?: return null
    @Suppress("DEPRECATION")
    val networks: Array<Network> = manager.allNetworks
    return networks.asSequence()
        .mapNotNull { view(manager.getNetworkCapabilities(it)) }
        .firstOrNull { it.cellular }
}

// MARK: - Latency

/**
 * Measures TCP connect times to an IPv4 literal on a background thread, at most one connect
 * every [intervalMs]; [reading] returns the median of the last three at once.
 */
class ConnectLatencyProbe(
    private val executor: Executor = latencyExecutor,
    private val clock: () -> Long = { SystemClock.elapsedRealtime() },
    private val intervalMs: Long = 3_000,
    private val connect: () -> Long = { measureConnectMillis() },
) {
    private val samples = ArrayDeque<Long>()
    private val running = AtomicBoolean(false)

    @Volatile
    private var lastStart = Long.MIN_VALUE / 2

    @Volatile
    private var failure: String? = null

    fun reading(transport: String): Reading {
        val now = clock()
        if (now - lastStart >= intervalMs && running.compareAndSet(false, true)) {
            lastStart = now
            executor.execute {
                try {
                    val millis = connect()
                    synchronized(samples) {
                        samples.addLast(millis)
                        while (samples.size > 3) samples.removeFirst()
                    }
                    failure = null
                } catch (exception: Exception) {
                    failure = exception.message ?: exception.javaClass.simpleName
                } finally {
                    running.set(false)
                }
            }
        }
        val median = synchronized(samples) { medianMillis(samples.toList()) }
        return latencyText(median, failure, transport)
    }

    companion object {
        private val latencyExecutor: Executor = Executors.newSingleThreadExecutor { task ->
            Thread(task, "verifier-latency").apply { isDaemon = true }
        }
    }
}

fun medianMillis(samples: List<Long>): Long? {
    if (samples.isEmpty()) return null
    val sorted = samples.sorted()
    return sorted[sorted.size / 2]
}

/** `≈ 450 ms · Mobile data`, rounded to 10 ms so jitter does not flash the row every tick. */
fun latencyText(medianMillis: Long?, failure: String?, transport: String): Reading = when {
    medianMillis != null -> {
        val rounded = (medianMillis + 5) / 10 * 10
        val suffix = if (transport == "Mobile data") "" else " · $transport, not shaped"
        Reading.Value("≈ $rounded ms to connect$suffix")
    }
    failure != null -> Reading.Value("Connect failed: $failure", muted = true)
    else -> Reading.Value("Measuring…", muted = true)
}

/** One TCP connect to 8.8.8.8:53 (no DNS lookup), in elapsed-realtime milliseconds. */
fun measureConnectMillis(host: String = "8.8.8.8", port: Int = 53, timeoutMs: Int = 10_000): Long {
    val start = SystemClock.elapsedRealtime()
    Socket().use { it.connect(InetSocketAddress(host, port), timeoutMs) }
    return SystemClock.elapsedRealtime() - start
}

// MARK: - Meter

fun meteredText(temporarilyNotMetered: Boolean?, activeMetered: Boolean, cellular: Boolean): Reading = when {
    !cellular -> Reading.Value("No mobile network · connect mobile data to read it", muted = true)
    temporarilyNotMetered == null -> Reading.Value("Needs Android 11", muted = true)
    temporarilyNotMetered ->
        Reading.Value("Off (temporarily not metered) · isActiveNetworkMetered = $activeMetered")
    else -> Reading.Value("On (metered) · isActiveNetworkMetered = $activeMetered")
}

fun meteredReading(context: Context): Reading {
    val manager = connectivity(context) ?: return Reading.Unsupported
    val cellular = cellularCapabilities(context)
    return meteredText(cellular?.temporarilyNotMetered, manager.isActiveNetworkMetered, cellular != null)
}
