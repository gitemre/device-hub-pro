package com.devicehubpro.verifier

fun buildSections(
    caps: Capabilities,
    location: LocationValues = LocationValues.None,
    sensors: SensorValues = SensorValues.None,
    telephony: TelephonyState = TelephonyState(),
    pause: PauseTracker = PauseTracker(),
    latency: ConnectLatencyProbe = ConnectLatencyProbe(),
): List<RowSection> = listOf(
    networkSection(caps),
    powerSection(),
    locationSection(caps, location),
    sensorsSection(caps, sensors),
    telephonySection(caps, telephony),
    advancedSection(caps, pause),
    foldableSection(caps, sensors),
    formFactorSection(caps),
    displaySection(),
    accessibilitySection(),
    debugSection(),
    languageTimeSection(),
    statusBarSection(),
    networkConditionsSection(caps, latency),
    appConditionsSection(),
    linksSection(),
)
