import Foundation
import DeviceHubProKit

// Which Controls rows a device family can work (2026-10-01). The panels used to
// decide by platform alone (Android, iOS) and, for Android, by live probes:
// a Wear OS watch listed Status bar (it has none), a TV listed Battery and
// Show taps (it has neither a battery nor a touch screen) and an Apple TV
// simulator got no panel at all. One table, `ControlsRow.availability(on:)`,
// now says per family whether a row works; every Controls view hides what it
// marks `unsupported` or `hidden`, as Device Hub hides the rows a platform does
// not offer (parity audit, CT-FAM). The table's evidence is named beside
// each family; the parity audit lists what was measured and what was derived.

/// The device family a Controls panel is built for. Android families come from
/// the running system (`DeviceInfo.formFactor`, `ro.build.characteristics`),
/// never from the skin: the `wearos_small_round` AVD of this machine runs a
/// phone image and reads `emulator`, so it is handheld whatever it looks like.
enum ControlsFamily: String, CaseIterable, Hashable, Sendable {
    /// Phones, foldables and tablets.
    case androidHandheld
    case androidWear
    case androidTV
    case androidAutomotive
    case androidXR
    case androidDesktop
    case iPhone
    case iPad
    case appleTV
    case appleWatch
    case appleVision
    /// A physical iPhone or iPad (its rows come from its CoreDevice capability list).
    case physicalApple

    var platform: DevicePlatform {
        switch self {
        case .androidHandheld, .androidWear, .androidTV, .androidAutomotive, .androidXR, .androidDesktop:
            return .android
        case .iPhone, .iPad, .appleTV, .appleWatch, .appleVision, .physicalApple:
            return .apple
        }
    }

    var title: String {
        switch self {
        case .androidHandheld: "Android phone, foldable, tablet"
        case .androidWear: "Wear OS"
        case .androidTV: "Android TV"
        case .androidAutomotive: "Android Automotive"
        case .androidXR: "Android XR"
        case .androidDesktop: "Android desktop"
        case .iPhone: "iPhone simulator"
        case .iPad: "iPad simulator"
        case .appleTV: "Apple TV simulator"
        case .appleWatch: "Apple Watch simulator"
        case .appleVision: "Apple Vision simulator"
        case .physicalApple: "Physical iPhone / iPad"
        }
    }

    /// The Android family of a device class; handheld until the class is read.
    static func android(_ formFactor: SystemImage.FormFactor?) -> ControlsFamily {
        switch formFactor {
        case nil, .handheld?: .androidHandheld
        case .wear?: .androidWear
        case .tv?: .androidTV
        case .automotive?: .androidAutomotive
        case .desktop?: .androidDesktop
        case .xr?: .androidXR
        }
    }

    /// The family of a simulator: its runtime's platform and its device
    /// type's product family. A simulator of a platform the app has no row
    /// table for falls to its nearest one by name; an unknown one is an iPhone
    /// (the family the mechanisms were built on).
    static func simulator(platform: String?, productFamily: String?) -> ControlsFamily {
        switch platform {
        case "tvOS": return .appleTV
        case "watchOS": return .appleWatch
        case "visionOS", "xrOS": return .appleVision
        default: return productFamily == "iPad" ? .iPad : .iPhone
        }
    }

    /// Whether a device of the family turns between portrait and landscape:
    /// phones, foldables, tablets, iPhone and iPad. A TV, a watch, a car and
    /// a headset keep their orientation, so the stage offers no Rotate.
    var rotates: Bool {
        switch self {
        case .androidHandheld, .iPhone, .iPad, .physicalApple: true
        case .androidWear, .androidTV, .androidAutomotive, .androidXR, .androidDesktop,
             .appleTV, .appleWatch, .appleVision: false
        }
    }

    /// Whether the family takes remote-control buttons (D-pad, Select, Back,
    /// Home, Play/Pause) instead of touch.
    var hasRemote: Bool { self == .androidTV || self == .appleTV }

    /// Whether the family gets a Controls panel. Apple Watch and Apple Vision
    /// simulators do not: no watchOS or visionOS runtime was installed to
    /// measure a mechanism on, so their panel stays the placeholder.
    var hasControlsPanel: Bool {
        switch self {
        case .appleWatch, .appleVision: false
        default: true
        }
    }
}

/// Whether one Controls row works on a family.
enum ControlsRowAvailability: Equatable {
    case available
    /// The family's platform has no such row (an Android row on an Apple
    /// device, and the reverse).
    case hidden
    /// The platform has the row but this family cannot do it; the reason
    /// names the evidence.
    case unsupported(String)

    var isVisible: Bool { self == .available }

    var reason: String? {
        if case .unsupported(let reason) = self { return reason }
        return nil
    }
}

extension ControlsRow {
    func availability(on family: ControlsFamily) -> ControlsRowAvailability {
        guard platforms.contains(family.platform) else { return .hidden }
        switch family.platform {
        case .android:
            if let reason = Self.androidUnsupported(self, family) { return .unsupported(reason) }
            return .available
        case .apple:
            return Self.appleAvailability(self, family)
        }
    }

    // MARK: - Android

    // Evidence, `SDK profile`: the device definitions `avdmanager` ships in
    // `sdklib.core.jar` (`com/android/sdklib/devices/{tv,wear,automotive,desktop,xr}.xml`,
    // read 2026-10-01): `status-bar` false on all 3 TV and all 3 Wear profiles,
    // true on the 8 automotive and 4 desktop ones; `power-type` plugged-in on
    // all TV and all automotive profiles; `screen-type` notouch on all TV
    // profiles and on 3 of 4 XR ones. `Derived` rows follow from the platform
    // (no such setting in Android TV's or Wear OS's Settings), and were not
    // run on a real Wear OS or TV image: none is installed here.
    private static func androidUnsupported(_ row: ControlsRow, _ family: ControlsFamily) -> String? {
        switch family {
        case .androidHandheld, .androidDesktop:
            // Desktop images have a status bar, a touch screen and (probe) a battery.
            return nil
        case .androidWear:
            if statusBarRows.contains(row) { return "Wear OS has no status bar (SDK profile: status-bar false)." }
            switch row {
            case .appearance: return "Wear OS is always dark: its Settings have no Light / Dark choice (derived)."
            case .dataSaver: return "Wear OS Settings has no Data Saver (derived)."
            default: return nil
            }
        case .androidTV:
            if statusBarRows.contains(row) { return "Android TV has no status bar (SDK profile: status-bar false)." }
            switch row {
            case .battery, .charging, .batterySaver:
                return "A TV is plugged in: no battery (SDK profile: power-type plugged-in)."
            case .showTaps:
                return "A TV has no touch screen (SDK profile: screen-type notouch)."
            case .airplaneMode: return "Android TV has no airplane mode (derived)."
            case .mobileData, .meteredMobileData:
                return "Android TV has no cellular connection (derived)."
            case .dataSaver: return "Android TV Settings has no Data Saver (derived)."
            default: return nil
            }
        case .androidAutomotive:
            switch row {
            case .battery, .charging, .batterySaver:
                return "A car's head unit is powered by the vehicle: no battery (SDK profile: power-type plugged-in)."
            case .airplaneMode: return "Android Automotive has no airplane mode (derived)."
            default: return nil
            }
        case .androidXR:
            switch row {
            case .showTaps:
                return "An XR headset takes no touches (SDK profile: screen-type notouch on 3 of 4 profiles)."
            default: return nil
            }
        case .iPhone, .iPad, .appleTV, .appleWatch, .appleVision, .physicalApple:
            return nil
        }
    }

    private static let statusBarRows: Set<ControlsRow> = [.cleanStatusBar]

    // MARK: - Apple

    private static func appleAvailability(_ row: ControlsRow, _ family: ControlsFamily) -> ControlsRowAvailability {
        switch family {
        case .iPhone, .iPad:
            // The mechanisms were measured on iPhone and iPad simulators (iOS 26.5 and 27.0);
            // the iPad differs only in its biometrics, which `supportsBiometrics` already gates.
            return .available
        case .physicalApple:
            // A phone offers what its CoreDevice capability list has (`appleDeviceRows`) and the
            // process shapes the client allows (`applePhysicalExtraRows`).
            if appleDeviceRows.contains(row) || applePhysicalExtraRows.contains(row) { return .available }
            return .unsupported("Not reachable on a physical device through the allowed CoreDevice commands.")
        case .appleTV:
            if appleTVRows.contains(row) { return .available }
            return .unsupported(appleTVReason(row))
        case .appleWatch:
            return .unsupported("Not measured: no watchOS runtime is installed, so no Controls mechanism was tried on an Apple Watch simulator.")
        case .appleVision:
            return .unsupported("Not measured: no visionOS runtime is installed, so no Controls mechanism was tried on an Apple Vision simulator.")
        default:
            return .hidden
        }
    }

    /// An Apple TV simulator's rows. Device Hub 27.0's own tvOS panel lists
    /// Appearance, Increase Contrast, Location and Sound (parity audit,
    /// 2026-09-28); the rest are the simctl rows that answered on a tvOS 27.0
    /// simulator (2026-10-01, private device set, `Apple TV 4K (3rd generation)`):
    /// `location set|clear`, `privacy grant|reset`, `keychain reset` and
    /// `spawn defaults write` (Language) exit 0, `push` reaches the notification
    /// service. Appearance and Increase Contrast go through devicectl only:
    /// simctl answers both `Runtime does not support …` there.
    static let appleTVRows: Set<ControlsRow> = [
        .appearance, .increaseContrast, .location, .sound, .audioOutput, .audioInput,
        .deviceLanguage, .timeZone,
        .targetApp, .permissions, .permissionsAccess, .pushNotification, .launchApp, .terminateApp,
        .linkURL,
        .resetKeychain, .resetDefaults,
    ]

    private static func appleTVReason(_ row: ControlsRow) -> String {
        switch row {
        case .textSize:
            return "tvOS has no Dynamic Type: simctl ui content_size answers \"Runtime does not support dynamic text\" (measured, tvOS 27.0)."
        case _ where statusBarRows.contains(row):
            return "simctl status_bar answers \"Status bar overrides not supported on this platform\" for tvOS (measured, tvOS 27.0)."
        case .biometricsEnrolled, .biometricsMatch:
            return "Apple TV has no Face ID or Touch ID."
        default:
            return "Not measured on tvOS, and Device Hub's own tvOS panel does not list it."
        }
    }
}

extension ControlsFamily {
    /// The families with a Photos and a Contacts app (Add Sample Data, Send Files, the stage drop).
    var offersSampleData: Bool { self == .iPhone || self == .iPad }

    /// The families whose pasteboard works (measured: tvOS answers "Pasteboard is not supported").
    private static let clipboardFamilies: Set<ControlsFamily> = [.iPhone, .iPad, .physicalApple]

    /// Whether any row of `control` is visible on the family: a control none
    /// of whose rows shows is never read or written (the poll skips it).
    func offers(_ control: AppleControl) -> Bool {
        // Orientation has no Controls row (Device Hub moved it to the Device menu), so the
        // rows table cannot answer for it: a family offers it where the device turns.
        // Without this, `route(.orientation)` was "unavailable" on every family and the
        // Device > Orientation menu went dark as soon as the panel had loaded (2026-10-05).
        if control == .orientation { return platform == .apple && rotates }
        // The clipboard has no Controls row either (the Device menu's Get / Send Clipboard and
        // Settings ▸ Clipboard are its surfaces): a family offers it where the pasteboard works.
        if control == .clipboard { return Self.clipboardFamilies.contains(self) }
        return ControlsRow.allCases.contains { $0.appleControl == control && $0.availability(on: self).isVisible }
    }

    /// The reason a control is out on the family (its first row's), nil when offered.
    func unavailableReason(for control: AppleControl) -> String? {
        guard !offers(control) else { return nil }
        if control == .clipboard {
            return self == .appleTV
                ? "simctl pbcopy and pbpaste answer \"Pasteboard is not supported by this runtime\" for tvOS (measured, tvOS 27.0)."
                : "\(title) does not offer it."
        }
        return ControlsRow.allCases
            .first { $0.appleControl == control && $0.availability(on: self).reason != nil }?
            .availability(on: self).reason
            ?? "\(title) does not offer it."
    }

    /// The rows of `rows` this family shows, in order.
    func visible(_ rows: [ControlsRow]) -> [ControlsRow] {
        rows.filter { $0.availability(on: self).isVisible }
    }
}
