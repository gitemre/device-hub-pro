package com.devicehubpro.verifier

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.database.ContentObserver
import android.hardware.Sensor
import android.hardware.display.DisplayManager
import android.net.ConnectivityManager
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.provider.Settings
import android.provider.Telephony
import android.telephony.PhoneStateListener
import android.telephony.TelephonyManager
import android.util.Log
import android.view.View
import android.view.WindowManager
import android.view.accessibility.AccessibilityManager
import android.widget.Button
import android.widget.TextView
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import com.devicehubpro.verifier.ui.RowsAdapter

class MainActivity : AppCompatActivity() {

    private lateinit var adapter: RowsAdapter
    private lateinit var status: TextView
    private lateinit var permissions: Button

    private val handler = Handler(Looper.getMainLooper())
    private val capabilities by lazy { AndroidCapabilities(this) }
    private val locationTracker by lazy { LocationTracker(this) }
    private val sensorValues by lazy { AndroidSensorValues(this) }
    private val telephonyState = TelephonyState()
    private val pauseTracker = PauseTracker()
    private var lastTickElapsed = 0L
    private var lastTickWall = 0L
    private val telephonyManager by lazy {
        getSystemService(TELEPHONY_SERVICE) as? TelephonyManager
    }
    private val sections by lazy {
        buildSections(
            capabilities,
            location = locationTracker,
            sensors = sensorValues,
            telephony = telephonyState,
            pause = pauseTracker,
        )
    }
    private val readings = mutableMapOf<String, Reading>()
    private val lastChanged = mutableMapOf<String, Long>()
    private val flashing = mutableSetOf<String>()
    private var started = false
    private var sourcesRegistered = false

    private val requiredPermissions = buildList {
        add(Manifest.permission.ACCESS_FINE_LOCATION)
        add(Manifest.permission.READ_PHONE_STATE)
        add(Manifest.permission.READ_PHONE_NUMBERS)
        add(Manifest.permission.READ_CALL_LOG)
        add(Manifest.permission.RECEIVE_SMS)
        add(Manifest.permission.BODY_SENSORS)
        if (Build.VERSION.SDK_INT >= 31) add(Manifest.permission.BLUETOOTH_CONNECT)
    }

    private val permissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
            refreshRows()
        }

    private val instantRefresh = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            refreshRows()
        }
    }

    private val accessibilityListener =
        AccessibilityManager.AccessibilityStateChangeListener { refreshRows() }

    private val displayListener = object : DisplayManager.DisplayListener {
        override fun onDisplayAdded(displayId: Int) {
            refreshRows()
        }

        override fun onDisplayRemoved(displayId: Int) {
            refreshRows()
        }

        override fun onDisplayChanged(displayId: Int) {
            refreshRows()
        }
    }

    private var phoneListenerAttached = false

    private val phoneListener = object : PhoneStateListener() {
        override fun onCallStateChanged(state: Int, phoneNumber: String?) {
            val previous = telephonyState.callState
            telephonyState.callState = state
            if (state == TelephonyManager.CALL_STATE_RINGING) {
                telephonyState.ringingNumber = phoneNumber
            }
            if (state == TelephonyManager.CALL_STATE_IDLE && previous != TelephonyManager.CALL_STATE_IDLE) {
                telephonyState.lastCallAt = System.currentTimeMillis()
                telephonyState.lastCallNumber = telephonyState.ringingNumber
                telephonyState.ringingNumber = null
            }
            refreshRows()
        }
    }

    private val smsReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            val message = intent
                ?.let { Telephony.Sms.Intents.getMessagesFromIntent(it) }
                ?.firstOrNull()
                ?: return
            telephonyState.lastSmsFrom = message.originatingAddress
            telephonyState.lastSmsBody = message.messageBody
            telephonyState.lastSmsAt = System.currentTimeMillis()
            refreshRows()
        }
    }

    private val tick = object : Runnable {
        override fun run() {
            trackPauseGap()
            refreshRows()
            handler.postDelayed(this, TICK_MS)
        }
    }

    private val settingsObserver = object : ContentObserver(handler) {
        override fun onChange(selfChange: Boolean) {
            refreshRows()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        ProcessRestore.onActivityCreated(hasSavedState = savedInstanceState != null)
        // A process recreated from Recents redelivers the old launch intent: not a new link.
        if (savedInstanceState == null) recordLink(intent, viaNewIntent = false)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        setContentView(R.layout.activity_main)

        status = findViewById(R.id.status)
        permissions = findViewById(R.id.permissions)
        permissions.setOnClickListener { requestAllMissingPermissions() }

        adapter = RowsAdapter(
            onAction = { action -> action.invoke(this) },
            onRowClick = { row -> row.permission?.let(::requestPermission) },
            flashDurationMillis = {
                flashDurationFor(animationScale(global(this, "animator_duration_scale")))
            },
        )
        findViewById<RecyclerView>(R.id.rows).apply {
            layoutManager = LinearLayoutManager(this@MainActivity)
            adapter = this@MainActivity.adapter
        }

        refreshRows()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        recordLink(intent, viaNewIntent = true)
        refreshRows()
    }

    /** Links ▸ Last link: VIEW intents only (install.sh's `am start -n` is not one). */
    private fun recordLink(intent: Intent?, viaNewIntent: Boolean) {
        if (intent?.action != Intent.ACTION_VIEW) return
        LinkLog.last = LinkRecord(
            data = intent.dataString,
            categories = intent.categories?.sorted() ?: emptyList(),
            referrer = referrer?.toString(),
            at = System.currentTimeMillis(),
            viaNewIntent = viaNewIntent,
        )
        Log.i(LINK_LOG_TAG, "link " + intent.dataString)
    }

    override fun onStart() {
        super.onStart()
        contentResolver.registerContentObserver(Settings.System.CONTENT_URI, true, settingsObserver)
        contentResolver.registerContentObserver(Settings.Global.CONTENT_URI, true, settingsObserver)
        contentResolver.registerContentObserver(Settings.Secure.CONTENT_URI, true, settingsObserver)
        ContextCompat.registerReceiver(
            this,
            instantRefresh,
            IntentFilter().apply {
                addAction(WifiManager.WIFI_STATE_CHANGED_ACTION)
                addAction(BluetoothAdapter.ACTION_STATE_CHANGED)
                addAction(Intent.ACTION_AIRPLANE_MODE_CHANGED)
                addAction(ConnectivityManager.ACTION_RESTRICT_BACKGROUND_CHANGED)
                addAction(Intent.ACTION_BATTERY_CHANGED)
                addAction(PowerManager.ACTION_POWER_SAVE_MODE_CHANGED)
                addAction(Intent.ACTION_CONFIGURATION_CHANGED)
                addAction(Intent.ACTION_LOCALE_CHANGED)
                addAction(Intent.ACTION_TIMEZONE_CHANGED)
                addAction(Intent.ACTION_TIME_CHANGED)
            },
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
        (getSystemService(ACCESSIBILITY_SERVICE) as? AccessibilityManager)
            ?.addAccessibilityStateChangeListener(accessibilityListener)
        if (hasPermission(this, Manifest.permission.ACCESS_FINE_LOCATION)) {
            locationTracker.start()
        }
        sensorValues.start(SensorKind.entries.map { it.type } + Sensor.TYPE_HINGE_ANGLE)
        attachPhoneListener()
        ContextCompat.registerReceiver(
            this,
            smsReceiver,
            IntentFilter(Telephony.Sms.Intents.SMS_RECEIVED_ACTION),
            ContextCompat.RECEIVER_EXPORTED,
        )
        (getSystemService(DISPLAY_SERVICE) as? DisplayManager)
            ?.registerDisplayListener(displayListener, handler)
        lastTickElapsed = SystemClock.elapsedRealtime()
        lastTickWall = System.currentTimeMillis()
        started = true
        sourcesRegistered = true
        handler.post(tick)
    }

    override fun onStop() {
        super.onStop()
        started = false
        if (sourcesRegistered) {
            unregisterReceiver(instantRefresh)
            unregisterReceiver(smsReceiver)
            contentResolver.unregisterContentObserver(settingsObserver)
            (getSystemService(ACCESSIBILITY_SERVICE) as? AccessibilityManager)
                ?.removeAccessibilityStateChangeListener(accessibilityListener)
            (getSystemService(DISPLAY_SERVICE) as? DisplayManager)
                ?.unregisterDisplayListener(displayListener)
            locationTracker.stop()
            sensorValues.stop()
            try {
                telephonyManager?.listen(phoneListener, PhoneStateListener.LISTEN_NONE)
            } catch (exception: SecurityException) {
                // The listener was never attached (permission missing) or already detached.
            }
            phoneListenerAttached = false
            sourcesRegistered = false
        }
        handler.removeCallbacksAndMessages(null)
    }

    private fun refreshRows() {
        val now = System.currentTimeMillis()
        val items = mutableListOf<RowsAdapter.Item>()
        for (section in sections.filter { it.applicable }) {
            items += RowsAdapter.Item.Header(section.title)
            for (row in section.rows) {
                val reading = safeRead(row)
                val previous = readings[row.id]
                if (previous != null && previous != reading) {
                    lastChanged[row.id] = now
                    flashing += row.id
                    handler.postDelayed({ flashing -= row.id; refreshRows() }, FLASH_MS)
                }
                readings[row.id] = reading
                items += RowsAdapter.Item.Row(row, reading, lastChanged[row.id], row.id in flashing)
            }
        }
        val hidden = sections.filterNot { it.applicable }.map { it.title }
        if (hidden.isNotEmpty()) {
            items += RowsAdapter.Item.Header("Hidden on this device: ${hidden.joinToString(", ")}")
        }
        if (adapter.items != items) {
            adapter.items = items
        }
        if (started && hasPermission(this, Manifest.permission.ACCESS_FINE_LOCATION)) {
            locationTracker.start()
        }
        if (started) {
            attachPhoneListener()
        }
        status.text = "Device Hub Pro Verifier · updated ${formatTime(now)} · every 1 s"
        val missing = requiredPermissions.filterNot { hasPermission(this, it) }
        permissions.visibility = if (missing.isEmpty()) View.GONE else View.VISIBLE
        permissions.text = "Grant missing permissions (${missing.size})"
    }

    private fun safeRead(row: VerifierRow): Reading = try {
        if (row.permission != null && !hasPermission(this, row.permission)) {
            Reading.NeedsPermission
        } else {
            row.read(this)
        }
    } catch (exception: Exception) {
        Reading.Failed(exception.message ?: "Read failed")
    }

    private fun trackPauseGap() {
        val elapsed = SystemClock.elapsedRealtime()
        val wall = System.currentTimeMillis()
        if (lastTickElapsed != 0L) {
            val gap = maxOf(elapsed - lastTickElapsed, wall - lastTickWall)
            if (gap >= PAUSE_GAP_MS) {
                pauseTracker.recordGap(gap)
            }
        }
        lastTickElapsed = elapsed
        lastTickWall = wall
    }

    private fun attachPhoneListener() {
        if (phoneListenerAttached || !hasPermission(this, Manifest.permission.READ_PHONE_STATE)) {
            return
        }
        try {
            telephonyManager?.listen(phoneListener, PhoneStateListener.LISTEN_CALL_STATE)
            phoneListenerAttached = true
        } catch (exception: SecurityException) {
            phoneListenerAttached = false
        }
    }

    private fun requestPermission(permission: String) {
        permissionLauncher.launch(arrayOf(permission))
    }

    private fun requestAllMissingPermissions() {
        val missing = requiredPermissions
            .filterNot { hasPermission(this, it) }
            .toTypedArray()
        if (missing.isNotEmpty()) {
            permissionLauncher.launch(missing)
        }
    }

    private companion object {
        const val TICK_MS = 1000L
        const val FLASH_MS = 600L
        const val PAUSE_GAP_MS = 3_000L
    }
}
