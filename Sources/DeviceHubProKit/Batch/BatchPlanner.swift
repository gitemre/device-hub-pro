import Foundation

/// Where a selected device is, as far as Apply to Selected cares: only a
/// ready device takes an action.
public enum BatchReadiness: Sendable, Hashable {
    /// Running and usable: an adb device online, a simulator at its home
    /// screen (`SimulatorLifecycleController.isReady`).
    case ready
    /// Booting: an AVD whose emulator is not online yet, a simulator not at
    /// its home screen yet.
    case starting
    /// Not running (a stopped AVD or simulator).
    case stopped
    /// adb lists it `offline`.
    case offline
    /// A phone that has not authorized this Mac's USB debugging key.
    case unauthorized
    /// A simulator that cannot run (its runtime is missing), and why.
    case unavailable(String)
    /// The row went away since it was selected.
    case notListed

    /// Why a device in this state is skipped; nil when it is ready.
    public var skipReason: String? {
        switch self {
        case .ready: nil
        case .starting: "Still starting"
        case .stopped: "Not running"
        case .offline: "Offline"
        case .unauthorized: "Not authorized: allow USB debugging on the phone"
        case .unavailable(let reason): reason.isEmpty ? "Unavailable" : "Unavailable: \(reason)"
        case .notListed: "No longer listed"
        }
    }
}

/// One selected device as Apply to Selected plans for it.
public struct BatchTarget: Sendable, Hashable, Identifiable {
    /// The sidebar row's stable key (an AVD by name, a simulator by UDID,
    /// another adb device by serial): the row stays selected across boots,
    /// where an adb serial is reused by whichever emulator boots next.
    public let id: String
    public let platform: DevicePlatform
    public let kind: DeviceKind
    /// The running device; nil while it is not running.
    public let ref: DeviceRef?
    public let name: String
    /// "Android", "iOS", "tvOS".
    public let osName: String?
    /// "16", "27.0".
    public let osVersion: String?
    public let readiness: BatchReadiness
    /// An Android device's API level, when Device Info read it.
    public let apiLevel: Int?

    public init(
        id: String,
        platform: DevicePlatform,
        kind: DeviceKind,
        ref: DeviceRef?,
        name: String,
        osName: String?,
        osVersion: String?,
        readiness: BatchReadiness,
        apiLevel: Int? = nil
    ) {
        self.id = id
        self.platform = platform
        self.kind = kind
        self.ref = ref
        self.name = name
        self.osName = osName
        self.osVersion = osVersion
        self.readiness = readiness
        self.apiLevel = apiLevel
    }

    /// "Android 16", "iOS 27.0", for the grid's labels and the result lines.
    public var osLabel: String? {
        switch (osName, osVersion) {
        case let (name?, version?): "\(name) \(version)"
        case let (name?, nil): name
        case let (nil, version?): version
        case (nil, nil): nil
        }
    }
}

/// What one device gets for an action: the per-platform value the
/// mechanisms take.
public enum BatchOperation: Sendable, Equatable {
    case appearance(dark: Bool)
    case androidTextSize(FontScaleStep)
    case simulatorTextSize(SimulatorContentSize)
    case language(DeviceLocale)
    case location(latitude: Double, longitude: Double)
    /// adb's request: `am start -W -a VIEW -d <link>`.
    case openAndroidLink(LinkRequest)
    /// simctl's `openurl`.
    case openSimulatorURL(URL)
    case install(BatchBuild)
    case statusBar(clean: Bool)
    case screenshot
    // Settings profiles (`ProfilePlanner`): the settings a profile sets.
    case reduceMotion(Bool)
    case increaseContrast(Bool)
    case showBorders(Bool)
    /// TalkBack / VoiceOver.
    case screenReader(Bool)
    case timeFormat(TimeFormatSetting)
    /// A simulator's cleared location.
    case clearLocation
    /// A whole profile for one device: its operations in order.
    case profile(ProfilePlan)
}

/// One device's plan: run an operation, or skip it and say why.
public enum BatchStep: Sendable, Equatable {
    case run(BatchOperation)
    case skip(String)

    public var operation: BatchOperation? {
        if case .run(let operation) = self { return operation }
        return nil
    }

    public var skipReason: String? {
        if case .skip(let reason) = self { return reason }
        return nil
    }
}

/// Plans an action per device: a device that is not ready is skipped with
/// its state, and a ready one gets the operation its platform takes, or is
/// skipped with the reason its platform cannot (a phone has no simulated
/// location, a tvOS simulator no Controls, a device without a build it
/// runs). Pure: the app resolves the rows to targets, runs the steps through
/// each platform's mechanisms and reports the results.
public enum BatchPlanner {
    /// The skip line for a simulator of another platform than iOS, whose
    /// Controls were never measured (the Controls panel's own card says the
    /// same).
    static func controlsOnlyOnIOS(_ platform: String?) -> String {
        "Controls are offered for iPhone and iPad simulators, not \(platform ?? "this platform")"
    }

    public static func plan(_ action: BatchAction, for targets: [BatchTarget]) -> [String: BatchStep] {
        var steps: [String: BatchStep] = [:]
        for target in targets {
            steps[target.id] = step(action, for: target)
        }
        return steps
    }

    public static func step(_ action: BatchAction, for target: BatchTarget) -> BatchStep {
        if let reason = target.readiness.skipReason {
            return .skip(reason)
        }
        if case .profile(let profile) = action {
            let plan = ProfilePlanner.plan(profile, for: target)
            if plan.operations.isEmpty {
                let shown = plan.skipped.filter(\.isReportable)
                let why = shown.isEmpty
                    ? (plan.skipped.isEmpty ? "The profile sets nothing" : "This device has none of the profile's settings")
                    : shown.map(\.text).joined(separator: ", ")
                return .skip("Nothing to apply: \(why)")
            }
            return .run(.profile(plan))
        }
        switch target.platform {
        case .android: return androidStep(action, for: target)
        case .apple: return appleStep(action, for: target)
        }
    }

    private static func androidStep(_ action: BatchAction, for target: BatchTarget) -> BatchStep {
        switch action {
        case .appearance(let dark):
            return .run(.appearance(dark: dark))
        case .textSize(let size):
            let step = size.androidStep
            if let api = target.apiLevel, !FontScaleStep.steps(apiLevel: api).contains(step) {
                return .skip("\(step.label) text needs Android 14 or later (API \(FontScaleStep.nonLinearScalingMinimumAPI))")
            }
            return .run(.androidTextSize(step))
        case .language(let locale):
            return .run(.language(locale))
        case .location(let place):
            guard target.kind == .emulator else {
                return .skip("A phone reports its own location: a simulated one needs an emulator")
            }
            return .run(.location(latitude: place.latitude, longitude: place.longitude))
        case .openURL(let text):
            do {
                return .run(.openAndroidLink(try LinkRequest(text, browsable: true, package: nil, apiLevel: target.apiLevel)))
            } catch {
                return .skip("\(error)")
            }
        case .install(let builds):
            guard let build = builds.first(where: { $0.platform == .android }) else {
                return .skip("No Android build chosen (.apk, .apks or a folder of split APKs)")
            }
            return .run(.install(build))
        case .statusBar(let clean):
            if let api = target.apiLevel, api < StatusBarDemo.minimumAPI {
                return .skip("Demo mode needs Android 6.0 or later")
            }
            return .run(.statusBar(clean: clean))
        case .screenshot:
            return .run(.screenshot)
        case .profile:
            return .skip("A profile is planned per setting")
        }
    }

    private static func appleStep(_ action: BatchAction, for target: BatchTarget) -> BatchStep {
        let isIOS = target.osName == nil || target.osName == "iOS"
        switch action {
        case .appearance(let dark):
            guard isIOS else { return .skip(controlsOnlyOnIOS(target.osName)) }
            return .run(.appearance(dark: dark))
        case .textSize(let size):
            guard isIOS else { return .skip(controlsOnlyOnIOS(target.osName)) }
            return .run(.simulatorTextSize(size.simulatorSize))
        case .language(let locale):
            guard isIOS else { return .skip(controlsOnlyOnIOS(target.osName)) }
            return .run(.language(locale))
        case .location(let place):
            guard isIOS else { return .skip(controlsOnlyOnIOS(target.osName)) }
            return .run(.location(latitude: place.latitude, longitude: place.longitude))
        case .openURL(let text):
            switch SimctlClient.readLink(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            case .success(let url):
                return .run(.openSimulatorURL(url))
            case .failure(.noScheme):
                return .skip("Not a URL: it needs a scheme, such as https: or myapp:")
            case .failure(.hostFile):
                return .skip("A file on the Mac: a simulator opens links, not files")
            case .failure(.unreadable):
                return .skip("Cannot be read as a URL")
            }
        case .install(let builds):
            guard let build = builds.first(where: { $0.platform == .apple }) else {
                return .skip("No simulator build chosen (.app, .ipa or .zip)")
            }
            return .run(.install(build))
        case .statusBar(let clean):
            guard isIOS else { return .skip(controlsOnlyOnIOS(target.osName)) }
            return .run(.statusBar(clean: clean))
        case .screenshot:
            return .run(.screenshot)
        case .profile:
            return .skip("A profile is planned per setting")
        }
    }
}
