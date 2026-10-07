import AppKit
import Foundation
import Observation
import DeviceHubProKit

/// The guided Android setup behind the "Set up Android tools" card: what a
/// Mac with no Android SDK needs, one flow for the empty stage, the sidebar
/// row, the toolbar warning and every dead end that used to say "not found".
///
/// Two ways out: "Install Android Tools…" runs `AndroidToolsInstaller` into
/// Android Studio's default SDK folder (command-line tools, platform tools,
/// the emulator; the license is shown and accepted only on the user's click;
/// a Java runtime is downloaded only on the user's say-so when the Mac has
/// none), and "Locate SDK…" takes a folder that already holds
/// `platform-tools/adb`. Either one ends in `onToolsAvailable`, which makes
/// the app pick the tools up without a relaunch.
@MainActor
@Observable
final class AndroidSetupModel {
    enum Phase: Equatable {
        case idle
        /// No Java 17+ on this Mac: asks before downloading Temurin.
        case needsJava
        case installing
        /// The Android SDK license text is on screen, waiting for the click.
        case awaitingLicense(SDKLicensePrompt)
        case finished
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// The latest progress of the running install.
    private(set) var progress: AndroidToolsInstallProgress?
    /// The steps that already finished in this run, in order.
    private(set) var completedSteps: [AndroidToolsInstallStep] = []
    /// Why "Locate SDK…" refused a folder.
    private(set) var locateError: String?
    /// A one-line explanation of why the card went back to the start (the
    /// license was declined), instead of resetting without a word.
    private(set) var notice: String?

    /// What the card says after a declined license.
    /// Set by Cancel so the license refusal it causes is not reported as a
    /// Decline. Cleared when an install starts.
    private var cancelRequested = false

    static let licenseDeclinedNotice =
        "The license wasn\u{2019}t accepted, so nothing was installed. You can start again whenever you\u{2019}re ready."
    /// Android Studio is installed: its own SDK flow is the other way in.
    let studioIsInstalled: Bool

    /// The SDK folder the install goes into.
    let installRoot: URL

    /// Runs after tools became available (installed or located): the app
    /// re-runs its locator and restarts polling (`AppModel.adoptAndroidTools`).
    @ObservationIgnored var onToolsAvailable: @MainActor () async -> Void = {}

    private let preferences: AppPreferences
    private let makeInstaller: @MainActor (URL) -> AndroidToolsInstaller
    private let environment: [String: String]
    private let licenseGate = SDKLicenseGate()
    private var task: Task<Void, Never>?

    init(
        preferences: AppPreferences,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        installRoot: URL? = nil,
        studioIsInstalled: Bool? = nil,
        makeInstaller: (@MainActor (URL) -> AndroidToolsInstaller)? = nil
    ) {
        self.preferences = preferences
        self.environment = environment
        self.installRoot = installRoot ?? Self.defaultInstallRoot(environment: environment)
        self.studioIsInstalled = studioIsInstalled ?? Self.detectStudio()
        self.makeInstaller = makeInstaller ?? { AndroidToolsInstaller(root: $0) }
    }

    /// Android Studio's default folder, so Studio shares the result; a folder
    /// named by `ANDROID_HOME` / `ANDROID_SDK_ROOT` wins, as it does for the
    /// locators.
    static func defaultInstallRoot(environment: [String: String]) -> URL {
        for key in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let root = environment[key], !root.isEmpty {
                return URL(fileURLWithPath: root, isDirectory: true)
            }
        }
        return AndroidSDKLocation.defaultRoot
    }

    static func detectStudio() -> Bool {
        !JavaRuntimeLocator.studioRuntimes(in: JavaRuntimeLocator.defaultApplicationDirectories).isEmpty
    }

    var isRunning: Bool {
        switch phase {
        case .installing, .awaitingLicense: return true
        default: return false
        }
    }

    /// "~/Library/Android/sdk" for the explanation.
    var installRootDisplay: String {
        (installRoot.path as NSString).abbreviatingWithTildeInPath
    }

    /// Puts the card in a given state without running anything, for the
    /// render tests that draw each of its screens.
    func showForPreview(
        phase: Phase,
        progress: AndroidToolsInstallProgress? = nil,
        completed: [AndroidToolsInstallStep] = [],
        locateError: String? = nil,
        notice: String? = nil
    ) {
        self.notice = notice
        self.phase = phase
        self.progress = progress
        self.completedSteps = completed
        self.locateError = locateError
    }

    // MARK: - Install

    /// Starts (or, after an error, resumes) the install. `allowJavaDownload`
    /// is the user's yes to downloading a Java runtime.
    func startInstall(allowJavaDownload: Bool = false) {
        guard task == nil else { return }
        phase = .installing
        progress = nil
        completedSteps = []
        notice = nil
        cancelRequested = false
        licenseGate.reset()
        let installer = makeInstaller(installRoot)
        let gate = licenseGate
        task = Task { [weak self] in
            do {
                try await installer.install(
                    allowJavaDownload: allowJavaDownload,
                    onProgress: { progress in
                        Task { @MainActor in self?.apply(progress) }
                    },
                    onLicense: { text in
                        gate.wait(text: text) { prompt in
                            Task { @MainActor in
                                self?.phase = .awaitingLicense(SDKLicensePrompt(text: prompt))
                            }
                        }
                    }
                )
                await self?.finishInstall()
            } catch let error as AndroidToolsInstallError {
                self?.installEnded(with: error)
            } catch {
                self?.installEnded(with: .toolFailed(error.localizedDescription))
            }
        }
    }

    private func apply(_ update: AndroidToolsInstallProgress) {
        guard isRunning else { return }
        if let previous = progress?.step, previous != update.step, !completedSteps.contains(previous) {
            completedSteps.append(previous)
        }
        progress = update
    }

    private func finishInstall() async {
        task = nil
        if installRoot.standardizedFileURL.path != AndroidSDKLocation.defaultRoot.standardizedFileURL.path {
            // Outside Studio's default folder the locators only know the
            // folder through the preference.
            preferences.setAndroidSDKPath(installRoot.path)
            AndroidSDKLocation.applyPreferredRoot(installRoot.path)
        }
        await onToolsAvailable()
        progress = nil
        phase = .finished
    }

    private func installEnded(with error: AndroidToolsInstallError) {
        task = nil
        licenseGate.decide(false)
        progress = nil
        switch error {
        case .cancelled:
            // The user's own choice, not an error.
            phase = .idle
        case .licenseDeclined:
            phase = .idle
            // Cancel also answers a pending license with no; only the
            // Decline button says why nothing was installed.
            if !cancelRequested { notice = Self.licenseDeclinedNotice }
        case .javaRequired:
            phase = .needsJava
        default:
            phase = .failed(error.description)
        }
    }

    func acceptLicense() {
        licenseGate.decide(true)
        phase = .installing
    }

    func declineLicense() {
        licenseGate.decide(false)
    }

    /// Stops the running install (a pending license counts as declined). What
    /// was downloaded is kept: the next run reuses it.
    func cancel() {
        guard isRunning else { return }
        cancelRequested = true
        licenseGate.decide(false)
        task?.cancel()
    }

    /// Back from an error or the Java question to the start.
    func reset() {
        guard !isRunning else { return }
        phase = .idle
        progress = nil
        completedSteps = []
        locateError = nil
        notice = nil
    }

    // MARK: - Locate

    /// Takes the folder the user picked as the SDK. Returns whether it was
    /// accepted; a refusal says why in `locateError`.
    @discardableResult
    func locateSDK(at url: URL) -> Bool {
        switch AndroidSDKLocation.validate(url) {
        case .valid(let root):
            locateError = nil
            preferences.setAndroidSDKPath(root.path)
            AndroidSDKLocation.applyPreferredRoot(root.path)
            Task { [weak self] in
                await self?.onToolsAvailable()
                self?.phase = .finished
            }
            return true
        case .notAFolder:
            locateError = "Choose the folder that holds the Android SDK."
            return false
        case .missingPlatformTools(let folder):
            locateError = "\(folder.lastPathComponent) has no platform-tools folder with adb in it. "
                + "Choose the SDK folder itself (the one with platform-tools, emulator and cmdline-tools), "
                + "or install the tools with Install Android Tools."
            return false
        }
    }

    /// The panel behind "Locate SDK…".
    func chooseSDKFolder() {
        let panel = NSOpenPanel()
        panel.title = "Locate the Android SDK"
        panel.message = "Choose the Android SDK folder (it contains platform-tools)."
        panel.prompt = "Use This Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = AndroidSDKLocation.defaultRoot.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        locateSDK(at: url)
    }

    // MARK: - Links

    static let androidStudioURL = URL(string: "https://developer.android.com/studio")!

    func openAndroidStudioPage() {
        NSWorkspace.shared.open(Self.androidStudioURL)
    }

    /// The Android Studio app, when it is installed.
    func openAndroidStudio() {
        let candidates = JavaRuntimeLocator.defaultApplicationDirectories
        for directory in candidates {
            let apps = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
            if let app = apps.first(where: { $0.hasPrefix("Android Studio") && $0.hasSuffix(".app") }) {
                NSWorkspace.shared.open(directory.appendingPathComponent(app))
                return
            }
        }
    }

    // MARK: - Copy

    /// What the guided install needs and does, for the card.
    static let explanation = "Device Hub Pro needs Google\u{2019}s Android tools to find and control Android devices and emulators. "
        + "It can download them for you, or you can point it at an SDK you already have."

    /// The dismissed card never shows again; the toolbar warning stays.
    func dismissCard() {
        preferences.setAndroidSetupDismissed(true)
    }
}
