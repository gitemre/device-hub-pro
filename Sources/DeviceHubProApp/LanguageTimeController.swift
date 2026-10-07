import Foundation
import Observation
import DeviceHubProKit

/// The Controls panel's Language & time group: the system language list, one
/// app's own language, the time zone, the device clock, the two automatic
/// switches and the 24-hour format.
///
/// Owned by `DeviceControlsController` (`controlsPanel.languageTime`), which
/// runs `refresh()` inside its two-second poll and `detach()`es it when the
/// mirrored device changes. What the device can do is probed once per device
/// (`LanguageTimeSupport`); each row is hidden when its mechanism is missing.
/// Every write shows its value at once, holds the write fence so a poll
/// cannot flip it back, is read back from where Android applies it (the Kit
/// throws when the device did not take it), and rolls back on failure.
@MainActor
@Observable
final class LanguageTimeController {
    let adbClient: AdbClient?
    private let context: ActiveDeviceContext
    let status: StatusCenter

    init(adbClient: AdbClient?, context: ActiveDeviceContext, status: StatusCenter) {
        self.adbClient = adbClient
        self.context = context
        self.status = status
    }

    /// What the mirrored device supports; nil until its probe answers.
    private(set) var support: LanguageTimeSupport?
    private(set) var supportSerial: String?
    /// The latest poll's readings; nil until the device answers, and after a
    /// failed read (the rows show unknown rather than a stale value).
    var readings: LanguageTimeReadings?
    /// The Mac's clock at the middle of the read that produced `readings`.
    private(set) var readingsHostDate: Date?
    /// Hides the rows after 3 consecutive failed reads (the `AppearanceProbe`
    /// rule) and brings them back on the next answer.
    private(set) var readProbe = SettingsProbe()
    private(set) var writeFence = SettingsWriteFence()

    /// The languages the device offers, sorted by name; empty until read.
    private(set) var deviceLocales: [DeviceLocale] = [] {
        didSet { languageSearch = LanguageSearchIndex(deviceLocales) }
    }
    /// The language pickers' search keys, built once per list.
    private(set) var languageSearch = LanguageSearchIndex([])
    private(set) var isLoadingDeviceLocales = false
    /// Per serial: the language list in place before the panel first changed
    /// it, which the Language row can put back. Kept across device switches.
    private(set) var originalLocales: [String: [DeviceLocale]] = [:]
    /// The AVD each per-serial record below was taken on, when it was known:
    /// a serial is reused by the next emulator, whose own languages and zone
    /// state these records are not.
    private var recordAvds: [String: String] = [:]

    /// Per serial: the detector's zone state before the panel first picked a
    /// zone (nil inside when the device has no such state), so turning
    /// Automatic time zone back on can put it back.
    private var zoneStatesBeforeManualZone: [String: TimeZoneDetectorState?] = [:]

    // MARK: - Rows

    private var answered: Bool { support != nil && readProbe.isAvailable }

    var showsLanguageRow: Bool { answered && support?.canSetDeviceLanguage == true }
    var showsDateTimeRow: Bool { answered && support?.alarmSetTime == true }
    var showsTimeZoneRow: Bool { answered && support?.alarmSetTimeZone == true }
    var showsTimeFormatRow: Bool { answered }

    /// Whether the mirrored device is an emulator (it has a gRPC port).
    var isEmulator: Bool { context.port != nil }

    /// The list the Language row can restore on this device, when the panel
    /// changed it and the device can write it back.
    var restorableOriginal: [DeviceLocale]? {
        guard let serial = context.serial, recordsAreCurrent(serial: serial),
              let original = originalLocales[serial], let support else { return nil }
        let current = readings?.locales ?? []
        guard !(DeviceLocaleList.sameLanguages(current, original)
                && original == (readings?.restorableLocales ?? current))
        else { return nil }
        return canWrite(original, support: support) ? original : nil
    }

    /// Whether `list` can be written on this device: the helper writes any list,
    /// the command one listed language.
    private func canWrite(_ list: [DeviceLocale], support: LanguageTimeSupport) -> Bool {
        (try? DeviceLocaleWritePlan.plan(target: list, current: readings?.locales, support: support)) != nil
    }

    // MARK: - Poll

    /// Reads the rows (and, once per device, what the device supports). A
    /// read that overlapped a write, or finished after the mirrored device
    /// changed, applies nothing.
    func refresh() async {
        guard let adbClient, let serial = context.serial else { return }
        let generation = context.controlsGeneration
        if supportSerial != serial {
            guard let probed = try? await adbClient.languageTimeSupport(serial: serial) else { return }
            guard isCurrent(serial: serial, generation: generation) else { return }
            support = probed
            supportSerial = serial
            deviceLocales = probed.deviceLocales
        }
        guard let support, writeFence.isIdle else { return }
        let ticket = writeFence.pollTicket
        let started = Date()
        let read = try? await adbClient.languageTimeReadings(serial: serial, support: support)
        let finished = Date()
        guard isCurrent(serial: serial, generation: generation) else { return }
        readProbe.record(answered: read != nil)
        guard writeFence.admits(pollStartedAt: ticket) else { return }
        readings = read
        readingsHostDate = read == nil ? nil : started.addingTimeInterval(finished.timeIntervalSince(started) / 2)
    }

    private func isCurrent(serial: String, generation: UInt64) -> Bool {
        !Task.isCancelled && sameDevice(serial: serial, generation: generation)
    }

    /// Whether the mirrored device still is the one a write started on (a
    /// cancelled write still rolls its rows back when it is).
    private func sameDevice(serial: String, generation: UInt64) -> Bool {
        context.serial == serial && context.controlsGeneration == generation
    }

    /// Whether the per-serial records of `serial` belong to the emulator
    /// that answers there now: unknown on either side counts as the same.
    private func recordsAreCurrent(serial: String) -> Bool {
        guard let recorded = recordAvds[serial], let now = context.avdName else { return true }
        return recorded == now
    }

    /// Drops what an earlier emulator on `serial` left, and notes the AVD
    /// the records taken from now on belong to.
    private func claimRecords(serial: String) {
        if !recordsAreCurrent(serial: serial) {
            originalLocales[serial] = nil
            zoneStatesBeforeManualZone[serial] = nil
            recordAvds[serial] = nil
        }
        if recordAvds[serial] == nil, let avd = context.avdName { recordAvds[serial] = avd }
    }

    /// The emulator on `serial` exited: what was recorded for it ended with it.
    func emulatorExited(serial: String) {
        originalLocales[serial] = nil
        zoneStatesBeforeManualZone[serial] = nil
        recordAvds[serial] = nil
    }

    /// One fresh read after a write, applied whatever the fence says (the
    /// write owns the rows), unless the mirrored device changed meanwhile.
    private func reconcile(serial: String, generation: UInt64) async {
        guard let adbClient, let support else { return }
        let started = Date()
        guard let read = try? await adbClient.languageTimeReadings(serial: serial, support: support),
              sameDevice(serial: serial, generation: generation)
        else { return }
        readings = read
        readingsHostDate = started.addingTimeInterval(Date().timeIntervalSince(started) / 2)
    }

    /// Forgets the device: its support, readings and pickers. The captured
    /// original languages survive, keyed by serial.
    func detach() {
        support = nil
        supportSerial = nil
        readings = nil
        readingsHostDate = nil
        readProbe.reset()
        deviceLocales = []
        isLoadingDeviceLocales = false
    }

    // MARK: - Language

    /// Loads the device's language list for the picker when the probe could
    /// not list it (`cmd locale list-device-locales` is API 36.1+): the
    /// helper reads the framework's own list.
    func loadDeviceLocales() async {
        guard deviceLocales.isEmpty, !isLoadingDeviceLocales,
              let adbClient, let serial = context.serial, let support
        else { return }
        isLoadingDeviceLocales = true
        defer { isLoadingDeviceLocales = false }
        do {
            let locales = try await adbClient.supportedDeviceLocales(serial: serial, support: support)
            guard context.serial == serial else { return }
            deviceLocales = locales
        } catch {
            if !error.isCancellation { status.errorMessage = "\(error)" }
        }
    }

    /// Makes `locale` the device's only language.
    func setDeviceLanguage(_ locale: DeviceLocale) async {
        await writeDeviceLocales([locale], message: "Language set to \(DeviceLocaleNames.nativeName(locale))")
    }

    /// Puts back the list the device had before the panel first changed it.
    func restoreDeviceLanguages() async {
        guard let original = restorableOriginal else { return }
        await writeDeviceLocales(original, message: "Languages restored to \(DeviceLocaleList.tags(original))")
    }

    private func writeDeviceLocales(_ target: [DeviceLocale], message: String) async {
        guard let adbClient, let serial = context.serial, let support else { return }
        let generation = context.controlsGeneration
        claimRecords(serial: serial)
        beginWrite()
        defer { endWrite() }
        let avd = context.avdName
        if originalLocales[serial] == nil,
           let current = try? await adbClient.languageTimeReadings(serial: serial, support: support),
           let restorable = current.restorableLocales {
            originalLocales[serial] = restorable
            recordAvds[serial] = avd
        }
        guard sameDevice(serial: serial, generation: generation) else { return }
        let previous = readings
        readings?.locales = target
        do {
            _ = try await adbClient.setDeviceLocales(serial: serial, target, support: support)
            status.flash(message)
            await reconcile(serial: serial, generation: generation)
        } catch {
            if sameDevice(serial: serial, generation: generation) { readings = previous }
            if !error.isCancellation { status.errorMessage = "\(error)" }
        }
    }

    // MARK: - Time zone

    /// Picks a zone: Automatic time zone goes off first, like Settings.
    func setTimeZone(_ identifier: String) async {
        guard let adbClient, let serial = context.serial, let support else { return }
        let generation = context.controlsGeneration
        claimRecords(serial: serial)
        beginWrite()
        defer { endWrite() }
        if zoneStatesBeforeManualZone[serial] == nil {
            let state = support.timeZoneStateForTests
                ? (try? await adbClient.timeZoneDetectorState(serial: serial)) ?? nil
                : nil
            zoneStatesBeforeManualZone[serial] = .some(state)
        }
        guard sameDevice(serial: serial, generation: generation) else { return }
        let previous = readings
        readings?.timeZoneID = identifier
        readings?.autoTimeZone = false
        do {
            try await adbClient.setTimeZone(serial: serial, identifier: identifier, support: support)
            status.flash("Time zone set to \(identifier)")
            await reconcile(serial: serial, generation: generation)
        } catch {
            if sameDevice(serial: serial, generation: generation) { readings = previous }
            if !error.isCancellation { status.errorMessage = "\(error)" }
        }
    }

    /// Automatic time zone. Turning it back on after the panel picked a zone
    /// is the zone's reset: once the network zone is back, the "Time zone
    /// changed" notification Android 17 posts for that change is cleared and
    /// the detector's confidence restored, as they were before.
    func setAutomaticTimeZone(_ enabled: Bool) async {
        guard let adbClient, let serial = context.serial, let support else { return }
        let generation = context.controlsGeneration
        claimRecords(serial: serial)
        beginWrite()
        defer { endWrite() }
        let previous = readings
        let zoneBefore = readings?.timeZoneID
        readings?.autoTimeZone = enabled
        do {
            let outcome = try await adbClient.setAutomaticTimeZone(serial: serial, enabled: enabled, support: support)
            if enabled, let captured = zoneStatesBeforeManualZone[serial] {
                zoneStatesBeforeManualZone[serial] = nil
                await waitForZoneChange(serial: serial, generation: generation, from: zoneBefore)
                if readings?.timeZoneID != zoneBefore {
                    _ = try? await adbClient.clearTimeZoneChangeNotification(
                        serial: serial,
                        waitingUpTo: Self.timeZoneNotificationWait
                    )
                }
                if let captured, readings?.timeZoneID == captured.zoneID {
                    try? await adbClient.restoreTimeZoneDetectorState(serial: serial, captured)
                }
            }
            status.flash(automaticMessage("Automatic time zone", enabled: enabled, outcome: outcome))
            await reconcile(serial: serial, generation: generation)
        } catch {
            if sameDevice(serial: serial, generation: generation) { readings = previous }
            if !error.isCancellation { status.errorMessage = "\(error)" }
        }
    }

    /// How long the reset waits for Android's "Time zone changed" notification
    /// after the zone moved (API 37 posts it about a second later; older
    /// images post none, so this is the reset's worst-case extra time).
    static let timeZoneNotificationWait: Duration = .seconds(3)

    /// The pause between the reset's reads of the zone: 10 reads, so the reset
    /// waits about 5 s for the detector to move it. Tests shorten it.
    @ObservationIgnored var zoneChangePollInterval: Duration = .milliseconds(500)

    /// Waits (up to 10 reads) for the detector to move the zone away from `zone`.
    private func waitForZoneChange(serial: String, generation: UInt64, from zone: String?) async {
        for _ in 0..<10 {
            guard sameDevice(serial: serial, generation: generation) else { return }
            await reconcile(serial: serial, generation: generation)
            if readings?.timeZoneID != zone { return }
            try? await Task.sleep(for: zoneChangePollInterval)
        }
    }

    // MARK: - Clock

    /// Automatic date & time. Turning it on steps the clock back to network
    /// time at once.
    func setAutomaticTime(_ enabled: Bool) async {
        guard let adbClient, let serial = context.serial, let support else { return }
        let generation = context.controlsGeneration
        claimRecords(serial: serial)
        beginWrite()
        defer { endWrite() }
        let previous = readings
        readings?.autoTime = enabled
        do {
            let outcome = try await adbClient.setAutomaticTime(serial: serial, enabled: enabled, support: support)
            status.flash(automaticMessage("Automatic date & time", enabled: enabled, outcome: outcome))
            await reconcile(serial: serial, generation: generation)
        } catch {
            if sameDevice(serial: serial, generation: generation) { readings = previous }
            if !error.isCancellation { status.errorMessage = "\(error)" }
        }
    }

    /// Sets the device clock to `date` (Automatic date & time goes off first).
    func setDeviceClock(to date: Date) async {
        guard let adbClient, let serial = context.serial, let support else { return }
        let generation = context.controlsGeneration
        claimRecords(serial: serial)
        beginWrite()
        defer { endWrite() }
        let previous = readings
        readings?.autoTime = false
        do {
            try await adbClient.setDeviceClock(
                serial: serial,
                epochMilliseconds: Int64((date.timeIntervalSince1970 * 1000).rounded()),
                support: support
            )
            status.flash("Device clock set")
            await reconcile(serial: serial, generation: generation)
        } catch {
            if sameDevice(serial: serial, generation: generation) { readings = previous }
            if !error.isCancellation { status.errorMessage = "\(error)" }
        }
    }

    /// Sets the device clock to the Mac's time, read at the last moment.
    func setDeviceClockToMacTime() async {
        await setDeviceClock(to: Date())
    }

    // MARK: - 24-hour time

    func setTimeFormat(_ setting: TimeFormatSetting) async {
        guard let adbClient, let serial = context.serial else { return }
        let generation = context.controlsGeneration
        beginWrite()
        defer { endWrite() }
        let previous = readings
        readings?.timeFormat = setting
        do {
            try await adbClient.setTimeFormat(serial: serial, setting)
            status.flash("Time format set to \(timeFormatTitle(setting, locales: readings?.locales))")
            await reconcile(serial: serial, generation: generation)
        } catch {
            if sameDevice(serial: serial, generation: generation) { readings = previous }
            if !error.isCancellation { status.errorMessage = "\(error)" }
        }
    }

    // MARK: - Helpers

    private func beginWrite() {
        writeFence.beginWrite()
    }

    private func endWrite() {
        writeFence.endWrite()
    }

    private func automaticMessage(
        _ label: String,
        enabled: Bool,
        outcome: AdbClient.AutomaticSettingOutcome
    ) -> String {
        let base = "\(label) turned \(enabled ? "on" : "off")"
        return outcome == .appliedThroughDetector ? "\(base) (through the detector)" : base
    }
}
