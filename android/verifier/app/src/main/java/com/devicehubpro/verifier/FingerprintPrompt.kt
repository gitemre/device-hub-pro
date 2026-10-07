package com.devicehubpro.verifier

import android.app.Activity
import android.content.Context
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity

object FingerprintPrompt {

    private var lastResult: String? = null
    private var lastAt: Long = 0L

    fun start(activity: Activity) {
        val host = activity as? FragmentActivity ?: return
        val prompt = BiometricPrompt(
            host,
            ContextCompat.getMainExecutor(activity),
            object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                    record("Succeeded")
                }

                override fun onAuthenticationFailed() {
                    record("Not recognised")
                }

                override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                    record("Cancelled")
                }
            },
        )
        prompt.authenticate(
            BiometricPrompt.PromptInfo.Builder()
                .setTitle("Fingerprint test")
                .setNegativeButtonText("Cancel")
                .build()
        )
    }

    fun reading(context: Context, caps: Capabilities): Reading =
        fingerprintText(caps.biometricState, lastResult, lastAt)

    private fun record(result: String) {
        lastResult = result
        lastAt = System.currentTimeMillis()
    }
}

fun fingerprintText(biometric: BiometricState, lastResult: String?, lastAt: Long): Reading = when {
    lastAt != 0L -> Reading.Value("${lastResult ?: "Unknown"} · ${formatTime(lastAt)}")
    biometric == BiometricState.NONE_ENROLLED -> Reading.Value("No fingerprint enrolled", muted = true)
    biometric == BiometricState.UNSUPPORTED -> Reading.Unsupported
    else -> Reading.Value("Not tested yet", muted = true)
}
