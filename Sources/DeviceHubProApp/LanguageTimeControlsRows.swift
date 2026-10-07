import SwiftUI
import DeviceHubProKit

// The Language & time group's rows (`ControlsView.rowView` passes each its
// title). They read and write through `controlsPanel.languageTime`
// (`LanguageTimeController`); what they show comes from `LanguageTimeRowModels`.

// MARK: - Language

struct DeviceLanguageRow: View {
    @Environment(DeviceWorkspace.self) private var workspace
    let title: String

    private var languageTime: LanguageTimeController { workspace.controlsPanel.languageTime }

    var body: some View {
        let current = languageTime.readings?.locales
        return VStack(spacing: 0) {
            DHSearchablePopupRow(
                title: title,
                glyph: "globe",
                help: dhHelp(languageApplyNote, "The system language list. The first language is the primary one."),
                valueText: languageValueText(current),
                pinnedTitle: "Suggested",
                pinned: presets,
                allTitle: "All languages",
                all: languageTime.deviceLocales,
                selectedID: current?.first?.id,
                titleFor: { DeviceLocaleNames.nativeName($0) },
                detailFor: { languageDetail($0) },
                matches: { languageTime.languageSearch.matches($0, query: $1) },
                actions: actions,
                isLoading: languageTime.isLoadingDeviceLocales,
                searchPrompt: DHSearchPrompt.languages,
                onOpen: { Task { await languageTime.loadDeviceLocales() } },
                onSelect: { locale in Task { await languageTime.setDeviceLanguage(locale) } }
            )
            .disabled(current == nil)
            if let caption = languageCaption(current: current) {
                DHCaptionRow(caption)
            }
        }
    }

    private var presets: [DeviceLocale] {
        DeviceLocalePresets.resolved(against: languageTime.deviceLocales.isEmpty ? nil : languageTime.deviceLocales)
    }

    private var actions: [DHPopupAction] {
        guard let original = languageTime.restorableOriginal else { return [] }
        return [
            DHPopupAction(id: "restore", title: "Restore \(DeviceLocaleList.tags(original))") {
                Task { await languageTime.restoreDeviceLanguages() }
            },
        ]
    }
}

// MARK: - Clock

struct DateTimeRow: View {
    @Environment(DeviceWorkspace.self) private var workspace
    let title: String

    @State private var isPopoverPresented = false
    @State private var draft = Date()
    @State private var pendingChange: ClockChange?

    private var languageTime: LanguageTimeController { workspace.controlsPanel.languageTime }

    /// A clock change waiting for the physical-device confirmation.
    private enum ClockChange: Identifiable {
        case date(Date)
        case macTime

        var id: String {
            switch self {
            case .date(let date): return "date-\(date.timeIntervalSince1970)"
            case .macTime: return "mac"
            }
        }
    }

    var body: some View {
        let readings = languageTime.readings
        return VStack(spacing: 0) {
            DHRow(
                title,
                glyph: "calendar.badge.clock",
                help: "The device clock. Setting it turns automatic date & time off by itself (Android 9 and newer); Reset to automatic turns it back on and steps the clock back to network time."
            ) {
                HStack(spacing: 8) {
                    Text(deviceClockText(
                        deviceEpochSeconds: readings?.deviceEpochSeconds,
                        zoneIdentifier: readings?.timeZoneID,
                        offsetSeconds: readings?.utcOffsetSeconds
                    ))
                    .font(.system(size: ParityMetrics.controlsLabelFontSize))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    // The date is short; the title gives way first.
                    .fixedSize()
                    Button("Set…") {
                        draft = deviceNow ?? Date()
                        isPopoverPresented = true
                    }
                    .buttonStyle(.dhPanel)
                    .disabled(readings?.deviceEpochSeconds == nil)
                    .popover(isPresented: $isPopoverPresented, arrowEdge: .bottom) {
                        clockPopover
                    }
                    // Only while the time was set by hand.
                    if readings?.autoTime == false {
                        Button("Reset to automatic") {
                            Task { await languageTime.setAutomaticTime(true) }
                        }
                        .buttonStyle(.dhPanel)
                        .controlSize(.small)
                        .help("Turns automatic date & time back on")
                    }
                }
            }
            if let caption {
                DHCaptionRow(caption)
            }
        }
        .confirmationDialog(
            "Change the phone's clock?",
            isPresented: Binding(
                get: { pendingChange != nil },
                set: { if !$0 { pendingChange = nil } }
            ),
            presenting: pendingChange
        ) { change in
            Button("Change Clock", role: .destructive) { perform(change) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Moving the clock fires or delays alarms and can break sign-ins that check the time (TLS certificates, 2FA codes). Reset to automatic returns to network time.")
        }
    }

    /// The device's time now, extrapolated from the last poll.
    private var deviceNow: Date? {
        guard let readings = languageTime.readings,
              let device = readings.deviceEpochSeconds,
              let host = languageTime.readingsHostDate
        else { return nil }
        return Date(timeIntervalSince1970: device + Date().timeIntervalSince(host))
    }

    private var deviceTimeZone: TimeZone {
        let readings = languageTime.readings
        return readings?.timeZoneID.flatMap(TimeZone.init(identifier:))
            ?? readings?.utcOffsetSeconds.flatMap(TimeZone.init(secondsFromGMT:))
            ?? .current
    }

    /// How far the device's clock is from the Mac's (nil until it is read;
    /// that setting it turns Automatic date & time off is in the help).
    private var caption: String? {
        let readings = languageTime.readings
        guard let offset = clockOffsetSeconds(
            deviceEpochSeconds: readings?.deviceEpochSeconds,
            hostDate: languageTime.readingsHostDate
        ) else { return nil }
        let automatic = readings?.autoTime == false ? " Set by hand: Reset to automatic follows network time again." : ""
        return clockOffsetText(seconds: offset) + "." + automatic
    }

    private var clockPopover: some View {
        VStack(alignment: .leading, spacing: ParityMetrics.controlsClockPopoverSpacing) {
            DatePicker(
                "Device date and time",
                selection: $draft,
                displayedComponents: [.date, .hourAndMinute]
            )
            .labelsHidden()
            .datePickerStyle(.stepperField)
            .environment(\.timeZone, deviceTimeZone)
            HStack(spacing: ParityMetrics.controlsClockPopoverSpacing) {
                ForEach(ClockStep.allCases) { step in
                    Button(step.title) {
                        draft = draft.addingTimeInterval(step.seconds)
                    }
                    .buttonStyle(.dhPanel)
                }
            }
            HStack(spacing: ParityMetrics.controlsClockPopoverSpacing) {
                Button("Now (Mac Time)") { request(.macTime) }
                    .buttonStyle(.dhPanel)
                Spacer(minLength: 0)
                Button("Set") { request(.date(draft)) }
                    .buttonStyle(.dhPanel)
            }
            Text("Times are in the device's zone (\(deviceTimeZone.identifier)). Setting the clock turns automatic date & time off by itself.")
                .font(.system(size: ParityMetrics.controlsCaptionFontSize))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(ParityMetrics.controlsPopoverInset * 2)
        .frame(width: ParityMetrics.controlsClockPopoverWidth)
    }

    /// Applies at once on an emulator; a phone asks first.
    private func request(_ change: ClockChange) {
        isPopoverPresented = false
        if languageTime.isEmulator {
            perform(change)
        } else {
            pendingChange = change
        }
    }

    private func perform(_ change: ClockChange) {
        pendingChange = nil
        switch change {
        case .date(let date):
            Task { await languageTime.setDeviceClock(to: date) }
        case .macTime:
            Task { await languageTime.setDeviceClockToMacTime() }
        }
    }
}

// MARK: - Time zone

struct TimeZoneRow: View {
    @Environment(DeviceWorkspace.self) private var workspace
    let title: String

    private var languageTime: LanguageTimeController { workspace.controlsPanel.languageTime }

    var body: some View {
        let readings = languageTime.readings
        return VStack(spacing: 0) {
            DHSearchablePopupRow(
                title: title,
                glyph: "globe.europe.africa",
                help: dhHelp(
                    timeZoneHelpText(identifier: readings?.timeZoneID, offsetSeconds: readings?.utcOffsetSeconds),
                    "Choosing a zone turns automatic time zone off by itself, runs cmd alarm set-timezone (Android 9 and newer) and reads persist.sys.timezone back; a zone the device does not know is reported, not ignored. Automatic follows the network again (global auto_time_zone, confirmed by cmd time_zone_detector on Android 12 and newer); it also clears the \"Time zone changed\" notification Android 17 posts for a manual choice."
                ),
                // Short enough for the panel's value column: "Istanbul (auto)".
                valueText: readings?.autoTimeZone == true
                    ? timeZoneValueText(identifier: readings?.timeZoneID) + " (auto)"
                    : timeZoneValueText(identifier: readings?.timeZoneID),
                pinnedTitle: "Suggested",
                pinned: TimeZoneOptions.presets,
                allTitle: "All time zones",
                all: TimeZoneOptions.all,
                selectedID: readings?.timeZoneID,
                titleFor: { $0.id },
                detailFor: { timeZoneDetail($0.id) },
                matches: { timeZoneMatches($0.id, query: $1) },
                actions: [
                    DHPopupAction(
                        id: "automatic",
                        title: languageTime.isEmulator ? "Automatic (the Mac's zone)" : "Automatic",
                        isEnabled: readings?.autoTimeZone == false
                    ) {
                        Task { await languageTime.setAutomaticTimeZone(true) }
                    },
                ],
                searchPrompt: DHSearchPrompt.timeZones,
                onSelect: { zone in Task { await languageTime.setTimeZone(zone.id) } }
            )
            .disabled(readings == nil)
        }
    }
}

/// The Time zone picker's lists, built once.
enum TimeZoneOptions {
    static let presets = TimeZonePresets.identifiers.map(TimeZoneOption.init(id:))
    static let all = allTimeZoneIdentifiers().map(TimeZoneOption.init(id:))
}

// MARK: - 24-hour time

struct TimeFormatRow: View {
    @Environment(DeviceWorkspace.self) private var workspace
    let title: String

    private var languageTime: LanguageTimeController { workspace.controlsPanel.languageTime }

    var body: some View {
        let readings = languageTime.readings
        return VStack(spacing: 0) {
            DHPopupRow(
                title: title,
                glyph: "clock",
                help: dhHelp(
                    "The status bar clock follows at the next minute.",
                    "Writes system time_12_24 (12 or 24), or deletes it to follow the language. Apps read it through DateFormat.is24HourFormat."
                ),
                options: TimeFormatSetting.allCases,
                selection: readings?.timeFormat,
                placeholder: "Unknown",
                titleFor: { timeFormatTitle($0, locales: readings?.locales) },
                valueTitleFor: { timeFormatValueTitle($0) },
                onSelect: { setting in Task { await languageTime.setTimeFormat(setting) } }
            )
            .disabled(readings?.timeFormat == nil)
        }
    }
}
