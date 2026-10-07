import DeviceHubProKit

/// The Controls panel's row-availability probes: one per settings command,
/// one per developer toggle, restarted when the panel moves to another
/// device, and the `shows*` answers the panel renders from.
///
/// Each probe hides its row after 3 consecutive command failures and clears
/// on any answer (the `AppearanceProbe` rule); an answered but
/// unrepresentable value never counts as a failure.
///
/// `DeviceControlsController` keeps one as `probes` (adopted in S17): its
/// poll calls `prepare(for:)` before its reads and records each read as it
/// applies it, and its `shows*` members answer from here. This replaced
/// `AppModel`'s nine `*Probe` fields, `toggleProbes`, `recordToggleProbes`
/// and three `*ProbeSerial` resets; the three serials always moved together
/// (each was set to the polled serial at the same point), so one serial
/// stands for them here.
struct SettingsProbeSet: Equatable, Sendable {
    /// The serial the probes last ran against; nil before the first poll.
    private(set) var serial: String?
    /// `cmd uimode night` command failures (the Appearance row).
    private(set) var appearance = AppearanceProbe()
    private(set) var fontScale = SettingsProbe()
    private(set) var reduceMotion = SettingsProbe()
    private(set) var increaseContrast = SettingsProbe()
    private(set) var showBorders = SettingsProbe()
    private(set) var talkBack = SettingsProbe()
    private(set) var sound = SettingsProbe()
    private(set) var dataSaver = SettingsProbe()
    /// Per-row probes for the developer toggles; a namespace read's
    /// `answered` flag feeds every row it covers. A toggle with no entry is
    /// available.
    private(set) var toggles: [DeviceToggle: SettingsProbe] = [:]

    init() {}

    // MARK: - Device

    /// Points the probes at `serial`. Moving to another device starts every
    /// failure count over; true when it moved, which also makes the poll
    /// read the TalkBack package from scratch.
    mutating func prepare(for serial: String) -> Bool {
        guard self.serial != serial else { return false }
        self.serial = serial
        fontScale.reset()
        reduceMotion.reset()
        increaseContrast.reset()
        showBorders.reset()
        talkBack.reset()
        sound.reset()
        toggles.removeAll()
        appearance.reset()
        dataSaver.reset()
        return true
    }

    // MARK: - Recording reads

    /// The `settings list global` read: Reduce Motion, Show Borders and the
    /// global developer toggles.
    mutating func recordGlobalRead(answered: Bool) {
        reduceMotion.record(answered: answered)
        showBorders.record(answered: answered)
        recordToggles(namespace: "global", answered: answered)
    }

    /// The `settings list system` read: Text Size and the system toggles.
    mutating func recordSystemRead(answered: Bool) {
        fontScale.record(answered: answered)
        recordToggles(namespace: "system", answered: answered)
    }

    /// The `settings list secure` read: Increase Contrast and the secure
    /// toggles.
    mutating func recordSecureRead(answered: Bool) {
        increaseContrast.record(answered: answered)
        recordToggles(namespace: "secure", answered: answered)
    }

    /// The media volume read (the Sound row).
    mutating func recordVolumeRead(answered: Bool) {
        sound.record(answered: answered)
    }

    /// The installed-package read behind the TalkBack row.
    mutating func recordTalkBackPackageRead(answered: Bool) {
        talkBack.record(answered: answered)
    }

    /// The appearance read: only the command failing counts toward hiding
    /// the row.
    mutating func recordAppearanceRead(_ result: Result<AppearanceReading, Error>) {
        appearance.record(result)
    }

    /// The `cmd netpolicy` read: an answered read, even an unrepresentable
    /// one, proves the command exists and keeps the row.
    mutating func recordDataSaverRead(answered: Bool) {
        dataSaver.record(answered: answered)
    }

    /// Feeds one namespace read to every developer toggle it covers.
    mutating func recordToggles(namespace: String, answered: Bool) {
        for toggle in DeviceToggle.allCases where toggle.namespace == namespace {
            var probe = toggles[toggle] ?? SettingsProbe()
            probe.record(answered: answered)
            toggles[toggle] = probe
        }
    }

    // MARK: - Rows

    /// Whether the Controls inspector shows the Appearance row. Hidden only
    /// for a device whose appearance command itself keeps failing.
    var showsAppearanceSection: Bool { appearance.isAvailable }

    var showsTextSizeRow: Bool { fontScale.isAvailable }
    var showsReduceMotionRow: Bool { reduceMotion.isAvailable }
    var showsIncreaseContrastRow: Bool { increaseContrast.isAvailable }
    var showsShowBordersRow: Bool { showBorders.isAvailable }

    /// Shown only while the installed-package list reports TalkBack and the
    /// probe has not tripped (a device without TalkBack never shows the row).
    func showsTalkBackRow(talkBackPackage: String?) -> Bool {
        talkBack.isAvailable && talkBackPackage != nil
    }

    var showsSoundRow: Bool { sound.isAvailable }

    /// Whether a developer-toggle row is shown: hidden while its namespace
    /// read keeps failing, or while the device reports the toggle
    /// unsupported.
    func showsToggle(_ toggle: DeviceToggle, unsupportedToggles: Set<DeviceToggle>) -> Bool {
        (toggles[toggle] ?? SettingsProbe()).isAvailable
            && !unsupportedToggles.contains(toggle)
    }

    var showsDataSaverRow: Bool { dataSaver.isAvailable }
}
