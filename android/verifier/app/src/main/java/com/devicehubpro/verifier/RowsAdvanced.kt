package com.devicehubpro.verifier

class PauseTracker {
    private var gapMillis = 0L

    fun recordGap(gap: Long) {
        if (gap > gapMillis) gapMillis = gap
    }

    fun reset() {
        gapMillis = 0L
    }

    fun read(): Reading =
        if (gapMillis >= 3_000) {
            Reading.Value("Pause detected: no ticks for ${gapMillis / 1000} s")
        } else {
            Reading.Value("Running · no pause detected yet", muted = true)
        }
}

fun advancedSection(caps: Capabilities, pause: PauseTracker): RowSection = RowSection(
    id = "advanced",
    title = "Advanced",
    applicable = caps.isEmulator,
    rows = listOf(
        VerifierRow(
            id = "advanced.fingerprint",
            title = "Fingerprint",
            source = "Advanced ▸ Fingerprint · gRPC sendFingerprint",
            kind = RowKind.INTERACTIVE,
            detail = "Enroll a fingerprint in Settings ▸ Security, tap Test, then send a touch from Device Hub Pro.",
            actions = if (caps.biometricState == BiometricState.READY) {
                listOf(
                    RowAction("Test fingerprint") { activity ->
                        FingerprintPrompt.start(activity)
                    }
                )
            } else {
                emptyList()
            },
            read = { context -> FingerprintPrompt.reading(context, caps) },
        ),
        VerifierRow(
            id = "advanced.vmState",
            title = "Emulator state",
            source = "Advanced ▸ Emulator state · gRPC setVmState",
            kind = RowKind.NOTE,
            detail = "Pause freezes the guest; the verifier reports a detected pause after resume when the clocks show a gap, and otherwise says the pause shows as a frozen screen.",
            read = { _ -> pause.read() },
        ),
    ),
)
