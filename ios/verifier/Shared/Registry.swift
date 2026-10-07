import Foundation

// The iOS verifier's rows: one per Device Hub Pro Controls row it mirrors, in the
// manifest's vocabulary (controls-rows.json, `ios` keys). Foundation only, so
// `swift test` checks it on the Mac (IOSVerifierRegistryTests) while the app
// (App/) compiles the same file for the simulator.

/// What a row reads, as the manifest's `observes` says it.
enum Observes: String, Codable, Sendable, CaseIterable {
    /// What apps see: the setting's effect on this app (a trait, an API answer).
    case effect
    /// The value Device Hub Pro wrote, read back where apps can read it.
    case key
    /// Nothing an app can read reflects the change; the row says what apps see instead.
    case note

    /// The tag the row shows.
    var tag: String {
        switch self {
        case .effect: return "Effect"
        case .key: return "Key value"
        case .note: return "Note"
        }
    }
}

struct VerifierRow: Sendable, Identifiable, Equatable {
    let id: String
    /// The Controls row's label on iOS, verbatim where the manifest says `sameTitle`.
    let title: String
    let observes: Observes
    /// Where Device Hub Pro changes it and which API this app reads.
    let source: String
    let detail: String
    /// The row offers an action (it starts something only this app sees, never a device change).
    var action: String? = nil
}

struct VerifierSection: Sendable, Identifiable, Equatable {
    let id: String
    let title: String
    let rows: [VerifierRow]
}

enum Registry {
    static let bundleIdentifier = "com.devicehubpro.verifier"
    /// The scheme the Links rows answer (the Android verifier's too).
    static let linkScheme = "devicehubpro-verifier"

    static let sections: [VerifierSection] = [
        VerifierSection(id: "display", title: "Display & sound", rows: [
            VerifierRow(
                id: "display.appearance",
                title: "Appearance",
                observes: .effect,
                source: "Display & sound ▸ Appearance · SwiftUI colorScheme",
                detail: "The interface style this app runs with; the verifier's own colours follow it."
            ),
            VerifierRow(
                id: "display.textSize",
                title: "Text Size",
                observes: .effect,
                source: "Display & sound ▸ Text Size · SwiftUI dynamicTypeSize",
                detail: "The content size category this app renders with; the rows' own text scales with it."
            ),
            VerifierRow(
                id: "display.reduceMotion",
                title: "Reduce Motion",
                observes: .effect,
                source: "Display & sound ▸ Reduce Motion · SwiftUI accessibilityReduceMotion",
                detail: "While it is on, a changed row's highlight appears without its fade."
            ),
            VerifierRow(
                id: "display.reduceTransparency",
                title: "Reduce Transparency",
                observes: .effect,
                source: "Display & sound ▸ Reduce Transparency · SwiftUI accessibilityReduceTransparency",
                detail: "While it is on, the header's material turns opaque."
            ),
            VerifierRow(
                id: "display.liquidGlass",
                title: "Liquid Glass",
                observes: .note,
                source: "Display & sound ▸ Liquid Glass · no app API",
                detail: "The system draws Liquid Glass at the opacity Device Hub Pro sets; no API tells an app the value. "
                    + "Watch this app's glass header and the home screen's search pill instead."
            ),
            VerifierRow(
                id: "display.showBorders",
                title: "Show Borders",
                observes: .effect,
                source: "Display & sound ▸ Show Borders · SwiftUI accessibilityShowButtonShapes",
                detail: "iOS calls it Button Shapes; the action buttons here draw their shapes while it is on."
            ),
            VerifierRow(
                id: "display.slowAnimations",
                title: "Slow Animations",
                observes: .effect,
                source: "Display & sound ▸ Slow Animations · UIView.animate completion time",
                detail: "Times a 0.1 s animation of a hidden view every 2 s: more than three times as long "
                    + "means UIKit runs animations slowed (Debug ▸ Slow Animations)."
            ),
            VerifierRow(
                id: "display.sound",
                title: "Sound",
                observes: .effect,
                source: "Display & sound ▸ Sound · AVAudioSession outputVolume",
                detail: "The output volume this app's audio session reports (0–100 %)."
            ),
        ]),
        VerifierSection(id: "accessibility", title: "Accessibility", rows: [
            VerifierRow(
                id: "accessibility.voiceOver",
                title: "VoiceOver",
                observes: .effect,
                source: "Accessibility ▸ VoiceOver · SwiftUI accessibilityVoiceOverEnabled",
                detail: "Whether VoiceOver runs for this app."
            ),
            VerifierRow(
                id: "accessibility.colorFilter",
                title: "Color Filter",
                observes: .effect,
                source: "Accessibility ▸ Color Filter · UIAccessibility.isGrayscaleEnabled",
                detail: "Apps can read only the grayscale filter: the protanopia, deuteranopia and tritanopia "
                    + "filters leave it off, so confirm those on the screen."
            ),
            VerifierRow(
                id: "accessibility.increaseContrast",
                title: "Increase Contrast",
                observes: .effect,
                source: "Accessibility ▸ Increase Contrast · SwiftUI colorSchemeContrast",
                detail: "The contrast this app renders with."
            ),
        ]),
        VerifierSection(id: "location", title: "Location", rows: [
            VerifierRow(
                id: "location.lastFix",
                title: "Location",
                observes: .effect,
                source: "Location · CLLocationManager",
                detail: "The last fix this app received, with its time. It needs the location permission: "
                    + "build.sh grants it, and Allow asks for it while it is undecided.",
                action: "Allow"
            ),
        ]),
        VerifierSection(id: "sensors", title: "Sensors", rows: [
            VerifierRow(
                id: "sensors.orientation",
                title: "Orientation",
                observes: .effect,
                source: "Sensors ▸ Orientation · UIDevice.orientation",
                detail: "The physical pose the device reports (face up and face down included); the interface "
                    + "follows only for poses this app supports."
            ),
        ]),
        VerifierSection(id: "advanced", title: "Advanced", rows: [
            VerifierRow(
                id: "advanced.biometrics",
                title: "Biometrics",
                observes: .effect,
                source: "Advanced ▸ Face ID / Touch ID · LAContext",
                detail: "The biometry type and whether it is enrolled; Authenticate asks for a match here, "
                    + "so a simulated match or non-match shows as the last result.",
                action: "Authenticate"
            ),
        ]),
        VerifierSection(id: "languageTime", title: "Language & time", rows: [
            VerifierRow(
                id: "languageTime.language",
                title: "Language",
                observes: .effect,
                source: "Language & time ▸ Language · Locale.preferredLanguages",
                detail: "The preferred language, the region format and the layout direction this app launched "
                    + "with: a language change reaches an app when it relaunches."
            ),
            VerifierRow(
                id: "languageTime.timeZone",
                title: "Time zone",
                observes: .effect,
                source: "Language & time ▸ Time zone · TimeZone.current",
                detail: "The zone this app's clock uses; a simulator takes it at boot."
            ),
            VerifierRow(
                id: "languageTime.timeFormat24",
                title: "24-hour time",
                observes: .effect,
                source: "Language & time ▸ 24-hour time · DateFormatter template j",
                detail: "The hour format this app's formatters produce."
            ),
        ]),
        VerifierSection(id: "statusBar", title: "Status bar", rows: [
            VerifierRow(
                id: "statusBar.batteryLevel",
                title: "Battery level",
                observes: .note,
                source: "Clean status bar · UIDevice.batteryLevel",
                detail: "The status bar override is drawn only: apps keep reading the simulator's own battery, "
                    + "which is -1 (unknown). Look at the status bar instead."
            ),
            VerifierRow(
                id: "statusBar.batteryState",
                title: "Battery state",
                observes: .note,
                source: "Clean status bar · UIDevice.batteryState",
                detail: "The status bar override is drawn only: apps keep reading the simulator's own state, "
                    + "which is unknown. Look at the status bar instead."
            ),
        ]),
        VerifierSection(id: "appConditions", title: "App conditions", rows: [
            VerifierRow(
                id: "appConditions.memoryWarning",
                title: "Memory warning",
                observes: .effect,
                source: "Memory warning · UIApplication.didReceiveMemoryWarningNotification",
                detail: "How many memory warnings this app received since it launched, and the last one's time. "
                    + "A simulator's warning reaches the app through its device folder; devicectl's "
                    + "process sendMemoryWarning answers success on a simulator, but none arrives."
            ),
            VerifierRow(
                id: "appConditions.push",
                title: "Push notification",
                observes: .effect,
                source: "App conditions ▸ Push notification · UNUserNotificationCenterDelegate willPresent",
                detail: "The last push this app received while it was in front: its title, body and time. "
                    + "simctl push reports \"Source is not authorized\" (the verifier never asks to post "
                    + "notifications), yet the app in front receives it."
            ),
            VerifierRow(
                id: "appConditions.permissions",
                title: "Permissions",
                observes: .effect,
                source: "App conditions ▸ Permissions · each framework's authorization status",
                detail: "This app's own authorization per service, read every 3 s. simctl privacy ends the app "
                    + "for some services; the row shows the new status when it opens again."
            ),
        ]),
        VerifierSection(id: "links", title: "Links", rows: [
            VerifierRow(
                id: "links.lastLink",
                title: "Last link",
                observes: .effect,
                source: "Links ▸ URL · SwiftUI onOpenURL (devicehubpro-verifier:)",
                detail: "The last devicehubpro-verifier: link this app was opened with, verbatim, and when. iOS asks "
                    + "\"Open in AQA Verifier?\" before a link from outside reaches the app: tap Open."
            ),
        ]),
        VerifierSection(id: "clipboard", title: "Clipboard", rows: [
            VerifierRow(
                id: "clipboard.pasteboard",
                title: "Clipboard",
                observes: .effect,
                source: "Device ▸ Get Clipboard / Send Clipboard · UIPasteboard.changeCount",
                detail: "The general pasteboard's change count and what it holds. The contents are never read, "
                    + "so iOS shows no paste prompt."
            ),
        ]),
    ]

    static let rows: [VerifierRow] = sections.flatMap(\.rows)

    static func row(_ id: String) -> VerifierRow? {
        rows.first { $0.id == id }
    }

    /// Rows whose Controls row has no `ios` mapping in controls-rows.json
    /// yet, keyed by verifier row and valued by the Controls row it waits
    /// for; the iOS Controls map each and remove it here. The registry test
    /// fails when a row is both mapped and listed.
    static let awaitingControlsRow: [String: String] = [:]
}
