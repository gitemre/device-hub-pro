package com.devicehubpro.verifier

class FakeCapabilities(
    override val isEmulator: Boolean = true,
    override val hasTelephony: Boolean = true,
    override val hasLocation: Boolean = true,
    override val biometricState: BiometricState = BiometricState.READY,
    private val sensors: Set<Int> = emptySet(),
) : Capabilities {
    override fun hasSensor(type: Int): Boolean = type in sensors
}
