import Foundation
import Observation
import DeviceHubProKit

/// The emulator's extended controls on the Controls tab: the virtual
/// sensors (the selected sensor, its last reading, the typed draft and the
/// reading poll), telephony (an incoming call, an SMS, the device's phone
/// number), VM pause and the fingerprint sensor.
///
/// One long-lived instance, owned by `DeviceWorkspace` as `extras`; the
/// views read it there. It acts on the
/// shared `ActiveDeviceContext`'s port and reports through `StatusCenter`.
/// The session hubs drive it: `attach()` when an emulator session starts,
/// `stopPolling()` and `detach()` when it ends. The typed drafts survive a
/// device switch.
@MainActor
@Observable
final class EmulatorExtrasController {
    private let context: ActiveDeviceContext
    private let status: StatusCenter

    init(context: ActiveDeviceContext, status: StatusCenter) {
        self.context = context
        self.status = status
    }

    var selectedSensor: SensorKind = .acceleration
    var sensorReadings: [SensorKind: [Float]] = [:]
    var sensorDraft: [String] = ["0", "0", "0"]
    var callNumber = ""
    var smsFrom = ""
    var smsText = ""
    var emulatorPhoneNumber = ""
    var isVmPaused = false
    var fingerprintTouchId = "0"
    private(set) var sensorPollTask: Task<Void, Never>?

    /// Sends one sensor's values to the emulator; tests replace it with a
    /// recording sink so nothing reaches an emulator.
    @ObservationIgnored
    var sensorSink: @Sendable (Int, SensorKind, [Float]) async -> Bool = { port, kind, values in
        await EmulatorSensors.set(port: port, kind: kind, values: values)
    }

    /// Telephony senders; tests replace them with recording sinks so nothing
    /// reaches an emulator.
    @ObservationIgnored
    var callSender: @Sendable (Int, String) async -> Bool = { port, number in
        await EmulatorTelephony.placeCall(port: port, number: number)
    }
    @ObservationIgnored
    var smsSender: @Sendable (Int, String, String) async -> Bool = { port, from, text in
        await EmulatorTelephony.sendSMS(port: port, from: from, text: text)
    }
    @ObservationIgnored
    var phoneNumberSender: @Sendable (Int, String) async -> Bool = { port, number in
        await EmulatorTelephony.setPhoneNumber(port: port, number: number)
    }

    func selectSensor(_ kind: SensorKind) {
        selectedSensor = kind
        primedSensor = kind
        sensorDraft = (sensorReadings[kind] ?? Array(repeating: 0, count: kind.axisLabels.count))
            .map { String(format: "%.3f", $0) }
        Task { await refreshSensor() }
    }

    /// The sensor whose draft was last filled from the device. The poll only
    /// refreshes the draft while it has not been primed for the selected
    /// sensor, so a value the user is typing is never overwritten — Refresh
    /// and a sensor switch replace it explicitly.
    private(set) var primedSensor: SensorKind?

    /// Refreshes the "Reading" row from the device. The draft is left
    /// alone unless this is the first reading for the selected sensor.
    func refreshSensor() async {
        guard let port = activePort else { return }
        guard let values = await EmulatorSensors.reading(port: port, kind: selectedSensor) else { return }
        sensorReadings[selectedSensor] = values
        if primedSensor != selectedSensor {
            primedSensor = selectedSensor
            sensorDraft = values.map { String(format: "%.3f", $0) }
        }
    }

    /// Fills the draft with the device's current reading (the Refresh action).
    func refreshSensorDraft() async {
        guard let port = requirePort() else { return }
        guard let values = await EmulatorSensors.reading(port: port, kind: selectedSensor) else { return }
        sensorReadings[selectedSensor] = values
        sensorDraft = values.map { String(format: "%.3f", $0) }
    }

    func applySensorValues() async {
        guard requirePort() != nil else { return }
        let values = sensorDraft
            .compactMap { Double($0.replacingOccurrences(of: ",", with: ".")) }
            .map(Float.init)
        guard values.count == selectedSensor.axisLabels.count else {
            errorMessage = "Enter \(selectedSensor.axisLabels.count) numeric value(s)."
            return
        }
        await send(values)
    }

    /// One preset button: its values go to the device at once and fill the
    /// draft, with no separate Apply.
    func applyPreset(_ preset: SensorPreset) async {
        guard requirePort() != nil else { return }
        await send(preset.values)
    }

    /// A slider moved one axis: sent at once, like a preset.
    func setAxis(_ index: Int, to value: Float) async {
        guard requirePort() != nil else { return }
        var values = currentDraftValues()
        guard values.indices.contains(index) else { return }
        values[index] = value
        await send(values)
    }

    /// Pulls every typed value into the official range (a field's Return);
    /// text that is not a number is left for Apply to refuse.
    func clampDraft() {
        let kind = selectedSensor
        sensorDraft = sensorDraft.map { text in
            guard let value = Double(text.replacingOccurrences(of: ",", with: ".")) else { return text }
            return String(format: "%.3f", kind.range.clamp(Float(value)))
        }
    }

    /// The draft as numbers (an unparsable field counts as the reading, or 0).
    func currentDraftValues() -> [Float] {
        let reading = sensorReadings[selectedSensor] ?? []
        return sensorDraft.enumerated().map { index, text in
            Double(text.replacingOccurrences(of: ",", with: "."))
                .map(Float.init) ?? (reading.indices.contains(index) ? reading[index] : 0)
        }
    }

    /// Clamps to the official range, sends, and on success records the
    /// reading and the draft.
    private func send(_ requested: [Float]) async {
        guard let port = requirePort() else { return }
        let kind = selectedSensor
        let values = kind.clamped(requested)
        if await sensorSink(port, kind, values) {
            sensorReadings[kind] = values
            if kind == selectedSensor {
                sensorDraft = values.map { String(format: "%.3f", $0) }
            }
            flashStatus("\(kind.label) updated")
        } else {
            errorMessage = "The emulator rejected the sensor value."
        }
    }

    /// Device ▸ Shake on an emulator: jolts the virtual accelerometer
    /// (`ShakeMotion`) and puts the reading it found back. The Sensors sheet's
    /// own acceleration value is left alone.
    func shake() async {
        guard let port = requirePort() else { return }
        let rest = await EmulatorSensors.reading(port: port, kind: .acceleration)
        for values in ShakeMotion.samples(rest: rest) {
            guard await EmulatorSensors.set(port: port, kind: .acceleration, values: values) else {
                errorMessage = "The emulator rejected the shake."
                return
            }
            try? await Task.sleep(for: .milliseconds(ShakeMotion.intervalMilliseconds))
        }
        sensorReadings[.acceleration] = ShakeMotion.samples(rest: rest).last
        flashStatus("Shook the emulator")
    }

    /// Whether the call went through (the sheet closes only then).
    @discardableResult
    func placeIncomingCall() async -> Bool {
        guard !callNumber.isEmpty, let port = requirePort() else { return false }
        if await callSender(port, callNumber) {
            flashStatus("Incoming call from \(callNumber)")
            return true
        }
        errorMessage = "The emulator rejected the call."
        return false
    }

    /// Whether the SMS was delivered (the sheet closes only then).
    @discardableResult
    func sendSMS() async -> Bool {
        guard !smsFrom.isEmpty, !smsText.isEmpty, let port = requirePort() else { return false }
        if await smsSender(port, smsFrom, smsText) {
            flashStatus("SMS delivered to the device")
            return true
        }
        errorMessage = "The emulator rejected the SMS."
        return false
    }

    /// Whether the number was set (the sheet closes only then).
    @discardableResult
    func applyEmulatorPhoneNumber() async -> Bool {
        guard !emulatorPhoneNumber.isEmpty, let port = requirePort() else { return false }
        if await phoneNumberSender(port, emulatorPhoneNumber) {
            flashStatus("Phone number set")
            return true
        }
        errorMessage = "The emulator rejected the phone number."
        return false
    }

    func toggleVmPause() async {
        guard let port = requirePort() else { return }
        let running = isVmPaused
        if await EmulatorDeviceControls.setRunning(port: port, running) {
            isVmPaused = !running
            flashStatus(running ? "Emulator resumed" : "Emulator paused")
        } else {
            errorMessage = running
                ? "The emulator did not resume."
                : "The emulator did not pause."
        }
    }

    func touchFingerprint() async {
        guard let port = requirePort() else { return }
        let touchId = Int32(fingerprintTouchId) ?? 0
        let touched = await EmulatorDeviceControls.sendFingerprint(port: port, touching: true, touchId: touchId)
        // Best effort: the sleep only holds the finger on the sensor.
        try? await Task.sleep(for: .milliseconds(250))
        // The lift is sent even after a failed touch, so no finger stays down.
        let lifted = await EmulatorDeviceControls.sendFingerprint(port: port, touching: false, touchId: touchId)
        if touched && lifted {
            flashStatus("Fingerprint \(touchId) touched")
        } else {
            errorMessage = "The emulator rejected the fingerprint touch."
        }
    }

    /// Starts the sensor reading poll for the active emulator session;
    /// without a port it only cancels the previous poll.
    func attach() {
        sensorPollTask?.cancel()
        guard activePort != nil else { return }

        sensorPollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshSensor()
                try? await Task.sleep(for: .milliseconds(1500))
            }
        }
    }

    /// Cancels the sensor reading poll.
    func stopPolling() {
        sensorPollTask?.cancel()
        sensorPollTask = nil
    }

    /// Forgets the per-device state: the VM pause, the sensor readings and
    /// the sensor the draft was primed from. The typed drafts (telephony,
    /// sensor values, fingerprint) and the selected sensor survive a device
    /// switch.
    func detach() {
        isVmPaused = false
        sensorReadings = [:]
        primedSensor = nil
    }

    // MARK: Status and device

    /// The active emulator's gRPC port; nil for a physical device and while
    /// nothing is mirrored, which makes every action a no-op.
    private var activePort: Int? { context.port }

    private var errorMessage: String? {
        get { status.errorMessage }
        set { status.errorMessage = newValue }
    }

    /// The active port for a user's action; without one the action says so
    /// instead of doing nothing.
    private func requirePort() -> Int? {
        guard let port = activePort else {
            flashStatus("The emulator\u{2019}s controls aren\u{2019}t connected yet.")
            return nil
        }
        return port
    }

    private func flashStatus(_ message: String) {
        status.flash(message)
    }
}
