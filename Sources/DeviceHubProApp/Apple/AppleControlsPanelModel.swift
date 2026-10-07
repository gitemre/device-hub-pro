import Foundation
import DeviceHubProKit

// The Controls panel for a simulator (Device Hub S20–S25): Device
// Hub's own three unlabelled cards, then Device Hub Pro's groups below them
// (`appleSimulatorGroupRows`: Biometrics, Language & time, App conditions, with
// the memory warning) and plain rows (`appleSimulatorPlainRows`). Orientation
// and the Clipboard row are the Device menu's and the stage's; the runtime that
// cannot change the colour filter does not show it. Every settings row is also a
// Device menu item. A physical iPhone keeps the grouped panel
// (`appleControlsGroupRows`) its own rows are listed in.

extension ControlsRow {
    /// The platforms a row is offered on: the keys of its `controls-rows.json`
    /// entry (`ControlsRowManifestTests` compares them).
    var platforms: Set<DevicePlatform> {
        var platforms: Set<DevicePlatform> = []
        if !Self.iosOnly.contains(self) { platforms.insert(.android) }
        if Self.appleRows.contains(self) { platforms.insert(.apple) }
        return platforms
    }

    /// The rows a physical iPhone can offer, each where its CoreDevice
    /// feature is listed: the manifest's `ios.targets` with `device`
    /// (`ControlsRowManifestTests` compares them). Every other iOS row
    /// reaches a simulator only.
    static let appleDeviceRows: Set<ControlsRow> = [
        .appearance, .liquidGlass, .textSize, .reduceMotion, .showBorders, .reduceTransparency,
        .talkBack, .colorFilter, .increaseContrast, .location,
    ]

    /// The rows the Device Hub simulator panel and the physical panel show
    /// that Android does not have.
    static let iosOnly: Set<ControlsRow> = [
        .liquidGlass, .reduceTransparency, .audioOutput, .audioInput,
        .biometricsEnrolled, .biometricsMatch, .permissions, .permissionsAccess, .pushNotification,
        .launchApp, .terminateApp, .memoryWarning, .addRootCertificate, .resetKeychain,
        .resetDefaults,
    ]

    /// The rows a physical iPhone's panel offers below its cards that do not
    /// depend on its CoreDevice capability list: the links and the app the
    /// allowed `device process` shapes act on (`applePhysicalGroupRows`).
    static let applePhysicalExtraRows: Set<ControlsRow> = Set(applePhysicalGroupRows.flatMap(\.rows) + applePhysicalPlainRows)

    /// Every row a simulator's panel can show, in its card order
    /// (`appleSimulatorCardRows`), then the physical panel's rows a simulator
    /// does not show.
    static let appleRows: [ControlsRow] = {
        var rows = appleSimulatorCardRows.flatMap { $0 }
        for row in appleControlsGroupRows.flatMap(\.rows) where !rows.contains(row) { rows.append(row) }
        let added = (appleSimulatorGroupRows + applePhysicalGroupRows).flatMap(\.rows) + applePhysicalPlainRows + appleSimulatorPlainRows + appleSimulatorTrailingRows
        for row in added where !rows.contains(row) { rows.append(row) }
        return rows
    }()

    /// The simulator control behind a row; nil for a row that only picks
    /// what others act on.
    var appleControl: AppleControl? {
        switch self {
        case .appearance: .appearance
        case .liquidGlass: .liquidGlass
        case .textSize: .textSize
        case .reduceMotion: .reduceMotion
        case .showBorders: .showBorders
        case .reduceTransparency: .reduceTransparency
        case .sound, .audioOutput, .audioInput: .volume
        case .talkBack: .voiceOver
        case .colorFilter: .colorFilter
        case .increaseContrast: .increaseContrast
        case .location: .location
        case .biometricsEnrolled, .biometricsMatch: .biometrics
        case .permissions, .permissionsAccess: .permissions
        case .pushNotification: .push
        case .linkURL: .openURL
        case .deviceLanguage: .language
        case .timeFormat24: .timeFormat24
        case .timeZone: .timeZone
        case .cleanStatusBar: .statusBar
        default: nil
        }
    }
}

/// A simulator's cards, Device Hub's (measured on Device Hub 27.0 with an
/// iOS 26.5 and an iOS 27.0 simulator, 2026-09-29): appearance and the
/// accessibility switches; Location; Sound with its Output and Input.
/// Color Filter sits after Liquid Glass where the runtime can change it
/// (iOS 27: devicectl fails on iOS 26.5, and Device Hub does not list the row
/// there); Liquid Glass is a Clear / Tinted popup on iOS 26 and a slider on
/// iOS 27 (`AppleControlsRowView`).
let appleSimulatorCardRows: [[ControlsRow]] = [
    [
        .appearance, .liquidGlass, .colorFilter, .textSize, .reduceMotion, .increaseContrast,
        .showBorders, .reduceTransparency, .talkBack,
    ],
    [.location],
    [.sound, .audioOutput, .audioInput],
]

/// The collapsible groups Device Hub Pro adds below Device Hub's cards (an addition
/// beyond DH, the parity audit, 2026-09-30), in the Android panel's wording
/// (`ControlsGroupID` titles) and, like Android's QA groups, collapsed by default.
enum AppleGroupID: String, CaseIterable, Identifiable, Hashable, Sendable {
    case biometrics
    case languageAndTime
    case appConditions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .biometrics: "Biometrics"
        case .languageAndTime: ControlsGroupID.languageAndTime.title
        case .appConditions: ControlsGroupID.appConditions.title
        }
    }

    var defaultExpanded: Bool { false }
}

struct AppleGroup: Equatable, Identifiable {
    let id: AppleGroupID
    let rows: [ControlsRow]
}

/// A simulator's added groups with every row they can hold, in display order.
let appleSimulatorGroupRows: [AppleGroup] = [
    AppleGroup(id: .biometrics, rows: [.biometricsEnrolled, .biometricsMatch]),
    AppleGroup(id: .languageAndTime, rows: [.deviceLanguage, .timeFormat24, .timeZone]),
    AppleGroup(id: .appConditions, rows: [
        .targetApp, .permissions, .permissionsAccess, .pushNotification, .launchApp, .terminateApp,
        .memoryWarning,
    ]),
]

/// The plain rows after the groups, in a card of their own (no disclosure):
/// Root certificate and Keychain, the Link URL row, then Clean status bar where
/// the runtime takes a status bar override.
let appleSimulatorPlainRows: [ControlsRow] = [.addRootCertificate, .resetKeychain, .linkURL, .cleanStatusBar]

/// The rows after the plain rows, in a card of their own: Reset to Defaults,
/// the simulator panel's counterpart of Android's Reset conditions.
let appleSimulatorTrailingRows: [ControlsRow] = [.resetDefaults]

/// The simulator's plain rows whose control is offered on `family`.
func appleSimulatorPlainRows(
    route: (AppleControl) -> AppleControlRoute,
    family: ControlsFamily = .iPhone
) -> [ControlsRow] {
    appleSimulatorPlainRows.filter { row in
        guard row.availability(on: family).isVisible else { return false }
        guard let control = row.appleControl else { return true }
        return route(control).isOffered
    }
}

/// The Liquid Glass opacity of a freshly created iOS 27 simulator, measured
/// 2026-09-30 with `devicectl device info appearance` on iPhone 17 Pro, iOS 27.0
/// (24A434), CoreDevice 642.16: `liquidGlassOpacity` 0.5.
let appleLiquidGlassDefaultOpacity = 0.5

/// What Reset to Defaults puts back, in the order it does.
enum AppleResetStep: CaseIterable, Equatable, Sendable {
    case appearance, textSize, largerAccessibilitySizes, reduceMotion, increaseContrast, showBorders, reduceTransparency
    case voiceOver, colorFilter, liquidGlass, liquidGlassOpacity, statusBar, location

    /// The alert's item.
    var title: String {
        switch self {
        case .appearance: "appearance: Light"
        case .textSize: "text size: Large (default)"
        case .largerAccessibilitySizes: "Larger Accessibility Sizes off"
        case .reduceMotion: "Reduce Motion off"
        case .increaseContrast: "Increase Contrast off"
        case .showBorders: "Show Borders off"
        case .reduceTransparency: "Reduce Transparency off"
        case .voiceOver: "VoiceOver off"
        case .colorFilter: "Color Filter off"
        case .liquidGlass: "Liquid Glass: Clear"
        case .liquidGlassOpacity: "Liquid Glass: 50 % (default)"
        case .statusBar: "status bar override off"
        case .location: "location: None"
        }
    }
}

/// The steps Reset to Defaults takes for this simulator: the ones whose
/// control the route offers and whose value is not the default already (a
/// value not read yet counts as changed). Liquid Glass is put back only where
/// the runtime lists the Clear and Tinted looks (iOS 26, Clear); on iOS 27,
/// where it is a slider, the default is the opacity a freshly created iOS 27
/// simulator reports (`appleLiquidGlassDefaultOpacity`).
func appleResetSteps(
    route: (AppleControl) -> AppleControlRoute,
    state: AppleControlsState,
    colorFilterSupported: Bool,
    statusBarActive: Bool?,
    location: AppleLocationChoice?
) -> [AppleResetStep] {
    func offered(_ control: AppleControl) -> Bool { route(control).isOffered }
    var steps: [AppleResetStep] = []
    if offered(.appearance), state.dark != false { steps.append(.appearance) }
    if offered(.textSize), state.textSize != .large { steps.append(.textSize) }
    // A text size of the accessibility range turns Larger Accessibility Sizes on and
    // Large leaves it on; only devicectl can turn it off (measured 2026-09-30).
    // (Reduce Motion is a devicectl-only control: offered means devicectl is there.)
    if offered(.reduceMotion), state.largerAccessibilitySizes == true {
        steps.append(.largerAccessibilitySizes)
    }
    if offered(.reduceMotion), state.reduceMotion != false { steps.append(.reduceMotion) }
    if offered(.increaseContrast), state.increaseContrast != false { steps.append(.increaseContrast) }
    if offered(.showBorders), state.showBorders != false { steps.append(.showBorders) }
    if offered(.reduceTransparency), state.reduceTransparency != false { steps.append(.reduceTransparency) }
    if offered(.voiceOver), state.voiceOver != false { steps.append(.voiceOver) }
    if colorFilterSupported, offered(.colorFilter) {
        if case .some(nil) = state.colorFilter {} else { steps.append(.colorFilter) }
    }
    if offered(.liquidGlass), state.supportedLooks.count > 1, state.lookAndFeel != .clear { steps.append(.liquidGlass) }
    if offered(.liquidGlass), state.supportedLooks.count <= 1, let opacity = state.liquidGlassOpacity,
       abs(opacity - appleLiquidGlassDefaultOpacity) > 0.005 {
        steps.append(.liquidGlassOpacity)
    }
    if statusBarActive == true { steps.append(.statusBar) }
    if location != nil { steps.append(.location) }
    return steps
}

/// A physical iPhone's plain row after its groups: the Link URL row.
let applePhysicalPlainRows: [ControlsRow] = [.linkURL]

/// A physical iPhone's added groups: only what the allowed `device process`
/// shapes reach (`openURL`, `launch`, `terminate`); never orientation or the
/// memory warning (measured not to work).
let applePhysicalGroupRows: [AppleGroup] = [
    AppleGroup(id: .appConditions, rows: [.targetApp, .launchApp, .terminateApp]),
]

/// The simulator's added groups: rows whose control is offered (a row that
/// picks or acts through simctl alone has no control and stays), the biometric
/// rows only for a device that has one (`supportsBiometrics` nil: not read
/// yet, offered); a group without rows is dropped.
func appleSimulatorGroups(
    route: (AppleControl) -> AppleControlRoute,
    supportsBiometrics: Bool?,
    family: ControlsFamily = .iPhone
) -> [AppleGroup] {
    appleSimulatorGroupRows.compactMap { group in
        let rows = group.rows.filter { row in
            guard row.availability(on: family).isVisible else { return false }
            if group.id == .biometrics, supportsBiometrics == false { return false }
            guard let control = row.appleControl else { return true }
            return route(control).isOffered
        }
        return rows.isEmpty ? nil : AppleGroup(id: group.id, rows: rows)
    }
}

/// A physical iPhone's Face ID / Touch ID / Optic ID title for the Biometrics group.
func appleBiometricGroupTitle(_ type: String?) -> String { type ?? "Face ID" }

/// A physical iPhone's groups with every row they can hold, in display order:
/// Device Hub's settings card first (Display & sound, Accessibility,
/// Location), then the clipboard. The panel offers the ones the phone's
/// CoreDevice capability list has.
let appleControlsGroupRows: [ControlsGroup] = [
    ControlsGroup(id: .displayAndSound, rows: [
        .appearance, .liquidGlass, .textSize, .reduceMotion, .showBorders, .reduceTransparency, .sound,
    ]),
    ControlsGroup(id: .accessibility, rows: [.talkBack, .colorFilter, .increaseContrast]),
    ControlsGroup(id: .location, rows: [.location]),
]

/// The physical panel's groups for a phone whose controls route as `route`
/// says: rows whose control is not offered are left out, and a group without
/// rows is dropped.
func appleControlsGroups(
    route: (AppleControl) -> AppleControlRoute,
    family: ControlsFamily = .iPhone
) -> [ControlsGroup] {
    appleControlsGroupRows.compactMap { group in
        let rows = group.rows.filter { row in
            guard row.availability(on: family).isVisible else { return false }
            guard let control = row.appleControl else { return false }
            return route(control).isOffered
        }
        return rows.isEmpty ? nil : ControlsGroup(id: group.id, rows: rows)
    }
}

/// The simulator panel's cards: the rows whose control is offered, a card
/// without rows dropped. `colorFilterSupported` is whether the runtime can
/// change the colour filter (iOS 27 and later); Output and Input follow
/// Sound's route.
func appleSimulatorCards(
    route: (AppleControl) -> AppleControlRoute,
    colorFilterSupported: Bool,
    family: ControlsFamily = .iPhone
) -> [[ControlsRow]] {
    appleSimulatorCardRows.compactMap { card in
        let rows = card.filter { row in
            guard row.availability(on: family).isVisible else { return false }
            if row == .colorFilter, !colorFilterSupported { return false }
            guard let control = row.appleControl else { return false }
            return route(control).isOffered
        }
        return rows.isEmpty ? nil : rows
    }
}

/// Whether a simulator's runtime can change the colour filter: iOS 27 and
/// later. devicectl answers the iOS 26.5 runtime with an error (measured on
/// an iOS 26.5 simulator, CoreDevice 642.16: "Failed to set the device's
/// appearance"), and Device Hub lists no Color Filter row there either.
func appleColorFilterSupported(osVersion: String?) -> Bool {
    guard let major = osVersion?.split(separator: ".").first.flatMap({ Int($0) }) else { return false }
    return major >= 27
}

/// The rows a physical iPhone's panel leaves out and why, for the note under
/// the panel: the rows its CoreDevice capability list does not offer, the two
/// measured not to work on it (Orientation, Memory warning) and the ones that
/// only reach a simulator. Never silent (the honesty rule).
func applePhysicalHiddenRows(route: (AppleControl) -> AppleControlRoute) -> [(title: String, reason: String)] {
    let titled: [(AppleControl, String)] = [
        (.appearance, "Appearance"), (.liquidGlass, "Liquid Glass"), (.textSize, "Text Size"),
        (.reduceMotion, "Reduce Motion"), (.showBorders, "Show Borders"),
        (.reduceTransparency, "Reduce Transparency"), (.volume, "Sound"), (.voiceOver, "VoiceOver"),
        (.colorFilter, "Color Filter"), (.increaseContrast, "Increase Contrast"), (.location, "Location"),
        (.orientation, "Orientation"), (.biometrics, "Face ID / Touch ID"), (.memoryWarning, "Memory warning"),
        (.push, "Push notification"), (.permissions, "Permissions"), (.openURL, "Links"),
        (.language, "Language"), (.timeFormat24, "24-hour time"), (.timeZone, "Time zone"),
        (.statusBar, "Status bar"),
    ]
    return titled.compactMap { control, title in
        guard let reason = route(control).support.unavailableReason else { return nil }
        return (title, reason)
    }
}

/// Whether a simulator's runtime gets the Controls panel: the iOS runtimes
/// (iPhone and iPad) and tvOS, whose rows were measured on a tvOS 27.0
/// simulator (`ControlsFamily.appleTV`). watchOS and visionOS were not (no
/// runtime installed), so they get a card instead of rows that may not reach
/// them.
func appleControlsOffered(platform: String?) -> Bool {
    guard let platform, ["iOS", "tvOS"].contains(platform) else { return false }
    return ControlsFamily.simulator(platform: platform, productFamily: nil).hasControlsPanel
}

/// A group's expanded default on a physical iPhone's panel: DH's settings
/// card open. Kept under their own keys (`DHGroup` id `ios.<group>`), so a
/// phone's layout does not move an emulator's.
func appleGroupDefaultExpanded(_ id: ControlsGroupID) -> Bool {
    switch id {
    case .displayAndSound, .accessibility, .location: true
    default: false
    }
}

/// The caption a row's `RowSupport` puts under it; nil for a live row.
func appleSupportCaption(_ support: RowSupport) -> String? {
    switch support {
    case .live, .unavailable: nil
    case .relaunchApp: "Some changes end the app if it runs; apps read the new state when they open."
    case .respring: "Apps use it when they relaunch; the home screen and status bar after a respring."
    case .reboot: "Applies when Device Hub Pro starts or restarts this simulator."
    case .cosmetic: "Drawn in the status bar only: apps still read the simulator's real battery and network."
    }
}

// MARK: - Value texts

enum AppleControlsText {
    /// The twelve text sizes by iOS's names.
    static func textSizeName(_ size: SimulatorContentSize) -> String {
        switch size {
        case .extraSmall: "Extra Small"
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large (default)"
        case .extraLarge: "Extra Large"
        case .extraExtraLarge: "Extra Extra Large"
        case .extraExtraExtraLarge: "Extra Extra Extra Large"
        case .accessibilityMedium: "Accessibility Medium"
        case .accessibilityLarge: "Accessibility Large"
        case .accessibilityExtraLarge: "Accessibility Extra Large"
        case .accessibilityExtraExtraLarge: "Accessibility Extra Extra Large"
        case .accessibilityExtraExtraExtraLarge: "Accessibility Extra Extra Extra Large"
        case .unknown: "Unknown"
        case .unsupported: "Unsupported"
        }
    }

    static func poseName(_ pose: SimulatorDevicePose) -> String {
        switch pose {
        case .portrait: "Portrait"
        case .portraitUpsideDown: "Portrait Upside Down"
        case .landscapeLeft: "Landscape Left"
        case .landscapeRight: "Landscape Right"
        case .faceUp: "Face Up"
        case .faceDown: "Face Down"
        }
    }

    /// Device Hub's filter names: the popover's long form, the row's short one.
    static func colorFilterTitle(_ type: SimulatorColorFilterType?) -> String {
        switch type {
        case nil: "Off"
        case .grayscale?: "Grayscale"
        case .protanopia?: "Red/Green (Protanopia)"
        case .deuteranopia?: "Green/Red (Deuteranopia)"
        case .tritanopia?: "Blue/Yellow (Tritanopia)"
        }
    }

    static func colorFilterShortTitle(_ type: SimulatorColorFilterType?) -> String {
        switch type {
        case nil: "None"
        case .grayscale?: "Grayscale"
        case .protanopia?: "Protanopia"
        case .deuteranopia?: "Deuteranopia"
        case .tritanopia?: "Tritanopia"
        }
    }

    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded())) %"
    }

    /// The Language row's value: the language in its own words, and for a name
    /// too long for the row ("English (United States)" showed as
    /// "English…States)") the language with the region code ("English (US)").
    static func languageValueName(_ locale: DeviceLocale) -> String {
        let full = DeviceLocaleNames.nativeName(locale)
        guard full.count > 16, let region = locale.region else { return full }
        let language = Locale(identifier: locale.language).localizedString(forLanguageCode: locale.language)
            ?? locale.language
        return language.prefix(1).uppercased() + language.dropFirst() + " (\(region))"
    }
}

/// What the Location row set on a simulator (simctl has no read-back, so
/// Device Hub Pro keeps it and sets it again after a boot).
enum AppleLocationChoice: Equatable, Sendable {
    case coordinate(name: String?, latitude: Double, longitude: Double)
    case scenario(String)
    case route([SimulatorWaypoint], speed: Double)

    var title: String {
        switch self {
        case .coordinate(let name?, _, _): name
        case .coordinate(nil, let latitude, let longitude):
            String(format: "%.4f, %.4f", locale: Locale(identifier: "en_US_POSIX"), latitude, longitude)
        case .scenario(let name): name
        case .route(let points, _): "Route (\(points.count) points)"
        }
    }

    var change: AppleControlChange {
        switch self {
        case .coordinate(_, let latitude, let longitude): .location(latitude: latitude, longitude: longitude)
        case .scenario(let name): .locationScenario(name)
        case .route(let points, let speed): .locationRoute(points, speed: speed)
        }
    }
}

/// One entry of the Location popup: a saved place or a scenario.
struct AppleLocationOption: Identifiable, Equatable {
    enum Kind: Equatable {
        case place(SavedLocation)
        case scenario(String)
    }

    let kind: Kind

    var id: String {
        switch kind {
        case .place(let place): "place.\(place.id)"
        case .scenario(let name): "scenario.\(name)"
        }
    }

    var title: String {
        switch kind {
        case .place(let place): place.name
        case .scenario(let name): name
        }
    }

    var choice: AppleLocationChoice {
        switch kind {
        case .place(let place): .coordinate(name: place.name, latitude: place.latitude, longitude: place.longitude)
        case .scenario(let name): .scenario(name)
        }
    }
}

/// The iOS languages the Language row offers: the Mac's locale data with a
/// region (iOS writes `AppleLocale` as language_REGION), one per tag.
enum AppleLanguageOptions {
    static let all: [DeviceLocale] = {
        var seen = Set<String>()
        return Locale.availableIdentifiers
            .compactMap { identifier -> DeviceLocale? in
                let tag = identifier.replacingOccurrences(of: "_", with: "-")
                guard let locale = DeviceLocale(tag: tag), locale.region != nil, !locale.isPseudo,
                      seen.insert(locale.tag).inserted
                else { return nil }
                return locale
            }
            .sorted { DeviceLocaleNames.nativeName($0) < DeviceLocaleNames.nativeName($1) }
    }()
}

extension SimulatorPrivacyService {
    /// The Permissions row's value: the popover's title where it fits, else a
    /// short form (measured 2026-09-30: "Location (w…" hid which of the two
    /// location services was chosen, at the default inspector width).
    var valueTitle: String {
        switch self {
        case .contactsLimited: "Contacts ltd."
        case .location: "Loc. in use"
        case .locationAlways: "Loc. always"
        case .photosAdd: "Photos add"
        case .mediaLibrary: "Media library"
        case .motion: "Motion"
        default: title
        }
    }
}
