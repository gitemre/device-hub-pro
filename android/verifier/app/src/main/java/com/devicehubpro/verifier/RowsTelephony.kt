package com.devicehubpro.verifier

import android.Manifest
import android.content.Context
import android.telephony.TelephonyManager

class TelephonyState {
    @Volatile var callState: Int = TelephonyManager.CALL_STATE_IDLE
    @Volatile var ringingNumber: String? = null
    @Volatile var lastCallNumber: String? = null
    @Volatile var lastCallAt: Long = 0L
    @Volatile var lastSmsFrom: String? = null
    @Volatile var lastSmsBody: String? = null
    @Volatile var lastSmsAt: Long = 0L
}

fun telephonySection(caps: Capabilities, state: TelephonyState): RowSection = RowSection(
    id = "telephony",
    title = "Telephony",
    applicable = caps.isEmulator && caps.hasTelephony,
    rows = listOf(
        VerifierRow(
            id = "telephony.incomingCall",
            title = "Incoming call",
            source = "Telephony ▸ Incoming call · gRPC sendPhone",
            kind = RowKind.DIRECT,
            permission = Manifest.permission.READ_PHONE_STATE,
            read = { _ ->
                callReading(state.callState, state.ringingNumber, state.lastCallNumber, state.lastCallAt)
            },
        ),
        VerifierRow(
            id = "telephony.incomingSms",
            title = "Incoming SMS",
            source = "Telephony ▸ Incoming SMS · gRPC sendSms",
            kind = RowKind.DIRECT,
            permission = Manifest.permission.RECEIVE_SMS,
            read = { _ -> smsReading(state.lastSmsFrom, state.lastSmsBody, state.lastSmsAt) },
        ),
        VerifierRow(
            id = "telephony.phoneNumber",
            title = "Phone number",
            source = "Telephony ▸ Phone number · gRPC setPhoneNumber",
            kind = RowKind.DIRECT,
            permission = Manifest.permission.READ_PHONE_NUMBERS,
            read = { context -> line1NumberReading(context) },
        ),
    ),
)

fun callStateText(state: Int): String = when (state) {
    TelephonyManager.CALL_STATE_IDLE -> "Idle"
    TelephonyManager.CALL_STATE_RINGING -> "Ringing"
    TelephonyManager.CALL_STATE_OFFHOOK -> "Off-hook"
    else -> "Unknown ($state)"
}

fun callReading(state: Int, ringingNumber: String?, lastNumber: String?, lastAt: Long): Reading =
    when (state) {
        TelephonyManager.CALL_STATE_RINGING ->
            Reading.Value(ringingNumber?.let { "Ringing · $it" } ?: "Ringing")
        TelephonyManager.CALL_STATE_OFFHOOK -> Reading.Value("Off-hook")
        else -> if (lastAt != 0L) {
            Reading.Value("Idle · last call ${lastNumber ?: "unknown number"} at ${formatTime(lastAt)}")
        } else {
            Reading.Value("Idle · no call yet")
        }
    }

fun smsReading(from: String?, body: String?, at: Long): Reading =
    if (at == 0L) {
        Reading.Value("No SMS yet", muted = true)
    } else {
        Reading.Value("${from ?: "Unknown sender"} · ${body?.take(40) ?: ""} · ${formatTime(at)}")
    }

fun phoneNumberText(number: String?): Reading =
    Reading.Value(number?.takeIf { it.isNotBlank() } ?: "Unreadable", muted = number.isNullOrBlank())

fun line1NumberReading(context: Context): Reading {
    val telephony = context.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager
        ?: return Reading.Unsupported
    return try {
        phoneNumberText(telephony.line1Number)
    } catch (exception: SecurityException) {
        Reading.NeedsPermission
    }
}
