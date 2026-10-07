import AVFoundation
import Contacts
import CoreLocation
import CoreMotion
import EventKit
import LocalAuthentication
import MediaPlayer
import Photos
import SwiftUI
import UIKit
import UserNotifications

/// What the SwiftUI environment says about the settings this app renders
/// with; `VerifierView` hands it over whenever it changes.
struct EnvironmentSnapshot: Equatable {
    var dark = false
    /// The position among the twelve text sizes (`DynamicTypeSize.allCases`).
    var textSizeIndex = 3
    var increasedContrast = false
    var reduceMotion = false
    var reduceTransparency = false
    var voiceOver = false
    var buttonShapes = false
}

/// Holds every row's reading, stamps changes and writes
/// `Documents/readings.json` whenever one changes. The polled readings are
/// read once a second (the permissions every 3 s); the environment,
/// location, links, pushes and memory warnings arrive as they happen.
@MainActor
final class VerifierModel: NSObject, ObservableObject {
    @Published private(set) var readings: [String: Reading] = [:]
    @Published private(set) var changedAt: [String: Date] = [:]
    @Published private(set) var writeFailure: String?
    @Published private(set) var locationNeedsPermission = false

    let launchedAt = Date()
    let system: String

    private var changes: [String: Int] = [:]
    private let locationManager = CLLocationManager()
    private var measuringAnimation = false
    private var memoryWarnings = 0
    private var lastMemoryWarning: Date?
    private var lastMatch: (result: String, at: Date)?
    private var polling: Task<Void, Never>?
    private var polls = 0
    private var observers: [NSObjectProtocol] = []
    private var writeScheduled = false

    static var readingsURL: URL {
        URL.documentsDirectory.appending(path: ReadingsDocument.fileName)
    }

    override init() {
        let device = UIDevice.current
        let model = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"].map { "\($0) simulator" }
            ?? device.model
        system = "\(device.systemName) \(device.systemVersion) · \(model)"
        super.init()
        device.isBatteryMonitoringEnabled = true
        // The app's own session, so outputVolume follows the device volume;
        // ambient leaves other apps' audio alone.
        try? AVAudioSession.sharedInstance().setCategory(.ambient)
        try? AVAudioSession.sharedInstance().setActive(true)
        update("links.lastLink", Readings.noLink)
        update("appConditions.memoryWarning", Readings.memoryWarnings(count: 0, last: nil))
        update("display.slowAnimations", Readings.toggle(false))
        update("appConditions.push", Readings.noPush)
        update("display.liquidGlass", Readings.liquidGlass)
        device.beginGeneratingDeviceOrientationNotifications()
        update("sensors.orientation", Readings.orientation(device.orientation.rawValue))
        UNUserNotificationCenter.current().delegate = self
        observeNotifications()
        locationManager.delegate = self
        startLocation()
        refresh()
        polling = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.poll()
            }
        }
        // `--authenticate-after <seconds>` (a launch argument) starts the
        // Authenticate action by itself once the delay is over, so a test on
        // the Mac can have the app ask for Face ID without touching the screen.
        let arguments = CommandLine.arguments
        if let flag = arguments.firstIndex(of: "--authenticate-after"),
           arguments.indices.contains(flag + 1), let seconds = Double(arguments[flag + 1]) {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                self?.authenticate()
            }
        }
    }

    // MARK: Readings

    /// Records a reading; a different value from the last one is a change.
    func update(_ id: String, _ reading: Reading) {
        guard Registry.row(id) != nil else {
            assertionFailure("no verifier row \(id)")
            return
        }
        if let previous = readings[id] {
            guard previous != reading else { return }
            changedAt[id] = Date()
            changes[id, default: 0] += 1
        }
        readings[id] = reading
        scheduleWrite()
    }

    func environmentChanged(_ snapshot: EnvironmentSnapshot) {
        update("display.appearance", Readings.appearance(dark: snapshot.dark))
        if let size = Readings.textSize(index: snapshot.textSizeIndex) {
            update("display.textSize", size)
        }
        update("display.reduceMotion", Readings.toggle(snapshot.reduceMotion))
        update("display.reduceTransparency", Readings.toggle(snapshot.reduceTransparency))
        update("display.showBorders", Readings.toggle(snapshot.buttonShapes, detail: snapshot.buttonShapes ? "Button Shapes" : nil))
        update("accessibility.voiceOver", Readings.toggle(snapshot.voiceOver))
        update("accessibility.increaseContrast", Readings.toggle(snapshot.increasedContrast))
    }

    func opened(link url: URL) {
        update("links.lastLink", Readings.link(url.absoluteString, at: Date()))
    }

    /// One poll tick: every row each second, but the permissions only every
    /// third (EventKit and TCC open connections per read). simctl privacy
    /// ends the app for most services anyway, and a launch reads them fresh.
    private func poll() {
        polls += 1
        refresh(permissions: polls % 3 == 0)
        if polls % 2 == 0 { measureAnimationSpeed() }
    }

    /// The polled rows.
    func refresh(permissions: Bool = true) {
        let device = UIDevice.current
        update("statusBar.batteryLevel", Readings.batteryLevel(device.batteryLevel))
        update("statusBar.batteryState", Readings.batteryState(device.batteryState.rawValue))
        update("accessibility.colorFilter", Readings.grayscale(UIAccessibility.isGrayscaleEnabled))
        update("display.sound", Readings.volume(AVAudioSession.sharedInstance().outputVolume))

        let preferred = Locale.preferredLanguages
        let direction = Locale.Language(identifier: preferred.first ?? "en").characterDirection
        update("languageTime.language", Readings.language(
            preferred: preferred,
            localeIdentifier: Locale.autoupdatingCurrent.identifier,
            rightToLeft: direction == .rightToLeft
        ))
        let zone = TimeZone.autoupdatingCurrent
        update("languageTime.timeZone", Readings.timeZone(identifier: zone.identifier, secondsFromGMT: zone.secondsFromGMT()))
        let pattern = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .autoupdatingCurrent) ?? "?"
        update("languageTime.timeFormat24", Readings.timeFormat(pattern: pattern))

        let pasteboard = UIPasteboard.general
        update("clipboard.pasteboard", Readings.pasteboard(
            changeCount: pasteboard.changeCount,
            hasStrings: pasteboard.hasStrings,
            hasURLs: pasteboard.hasURLs,
            hasImages: pasteboard.hasImages
        ))

        refreshBiometrics()
        if permissions {
            update("appConditions.permissions", Readings.permissions(permissionStatuses()))
        }
        locationNeedsPermission = locationManager.authorizationStatus == .notDetermined
    }

    // MARK: Actions (only this app's own prompts; never a device setting)

    /// Whether a row's action can run now.
    func actionAvailable(for id: String) -> Bool {
        switch id {
        case "advanced.biometrics": return true
        case "location.lastFix": return locationNeedsPermission
        default: return false
        }
    }

    func runAction(for id: String) {
        switch id {
        case "advanced.biometrics": authenticate()
        case "location.lastFix": locationManager.requestWhenInUseAuthorization()
        default: break
        }
    }

    private func authenticate() {
        let context = LAContext()
        Task { [weak self] in
            let result: String
            do {
                let success = try await context.evaluatePolicy(
                    .deviceOwnerAuthenticationWithBiometrics,
                    localizedReason: "Shows a simulated match in the verifier."
                )
                result = success ? "Succeeded" : "Failed"
            } catch let error as LAError {
                result = Self.name(error.code)
            } catch {
                result = "Error"
            }
            self?.lastMatch = (result, Date())
            self?.refreshBiometrics()
        }
    }

    // MARK: Sources

    private func refreshBiometrics() {
        let context = LAContext()
        var error: NSError?
        let enrolled = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        let type: String
        switch context.biometryType {
        case .faceID: type = "faceID"
        case .touchID: type = "touchID"
        case .opticID: type = "opticID"
        case .none: type = "none"
        @unknown default: type = "none"
        }
        update("advanced.biometrics", Readings.biometrics(type: type, enrolled: enrolled, lastMatch: lastMatch))
    }

    private func observeNotifications() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.receivedMemoryWarning()
            }
        })
        observers.append(center.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.update("sensors.orientation", Readings.orientation(UIDevice.current.orientation.rawValue))
            }
        })
        // Changes that should not wait for the next poll.
        for name in [
            UIAccessibility.grayscaleStatusDidChangeNotification,
            NSLocale.currentLocaleDidChangeNotification,
            Notification.Name.NSSystemTimeZoneDidChange,
            UIPasteboard.changedNotification,
        ] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }

    /// Times a 0.1 s animation of a hidden view in the key window: UIKit
    /// stretches it past 0.3 s while the simulator's Slow Animations is on.
    private func measureAnimationSpeed() {
        guard !measuringAnimation, UIApplication.shared.applicationState == .active,
              let window = UIApplication.shared.connectedScenes
                  .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first
        else { return }
        measuringAnimation = true
        let probe = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        probe.alpha = 0.01
        window.addSubview(probe)
        let started = Date()
        UIView.animate(withDuration: 0.1, animations: { probe.alpha = 0.02 }, completion: { [weak self] _ in
            let elapsed = Date().timeIntervalSince(started)
            probe.removeFromSuperview()
            MainActor.assumeIsolated {
                guard let self else { return }
                self.measuringAnimation = false
                self.update("display.slowAnimations", Readings.toggle(elapsed > 0.3))
            }
        })
    }

    private func receivedMemoryWarning() {
        memoryWarnings += 1
        lastMemoryWarning = Date()
        update("appConditions.memoryWarning", Readings.memoryWarnings(count: memoryWarnings, last: lastMemoryWarning))
    }

    private func startLocation() {
        switch locationManager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            locationManager.startUpdatingLocation()
            if readings["location.lastFix"] == nil {
                update("location.lastFix", Readings.locationUnavailable("Waiting for a fix"))
            }
        case .notDetermined:
            update("location.lastFix", Readings.locationUnavailable("Permission required · tap Allow"))
        default:
            update("location.lastFix", Readings.locationUnavailable("Permission denied (Settings ▸ Privacy)"))
        }
    }

    private func permissionStatuses() -> [String: String] {
        [
            "location": Self.name(locationManager.authorizationStatus),
            "photos": Self.name(PHPhotoLibrary.authorizationStatus(for: .readWrite)),
            "contacts": Self.name(CNContactStore.authorizationStatus(for: .contacts)),
            "calendar": Self.name(EKEventStore.authorizationStatus(for: .event)),
            "reminders": Self.name(EKEventStore.authorizationStatus(for: .reminder)),
            "microphone": Self.name(AVAudioApplication.shared.recordPermission),
            "camera": Self.name(AVCaptureDevice.authorizationStatus(for: .video)),
            "motion": Self.name(CMMotionActivityManager.authorizationStatus()),
            "mediaLibrary": Self.name(MPMediaLibrary.authorizationStatus()),
        ]
    }

    // MARK: Writing

    private func scheduleWrite() {
        guard !writeScheduled else { return }
        writeScheduled = true
        Task { [weak self] in
            guard let self else { return }
            writeScheduled = false
            write()
        }
    }

    private func write() {
        var rows: [String: ReadingsDocument.Row] = [:]
        for (id, reading) in readings {
            guard let row = Registry.row(id) else { continue }
            rows[id] = ReadingsDocument.Row(
                title: row.title,
                observes: row.observes,
                value: reading.value,
                raw: reading.raw,
                changedAt: changedAt[id],
                changes: changes[id] ?? 0
            )
        }
        let document = ReadingsDocument(
            bundle: Registry.bundleIdentifier,
            system: system,
            launchedAt: launchedAt,
            writtenAt: Date(),
            rows: rows
        )
        do {
            try ReadingsDocument.encoder().encode(document).write(to: Self.readingsURL, options: .atomic)
            writeFailure = nil
        } catch {
            writeFailure = "Could not write readings.json: \(error.localizedDescription)"
        }
    }

    // MARK: Status names

    static func name(_ status: CLAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorizedAlways: return "authorizedAlways"
        case .authorizedWhenInUse: return "authorizedWhenInUse"
        @unknown default: return "unknown"
        }
    }

    static func name(_ status: PHAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorized: return "authorized"
        case .limited: return "limited"
        @unknown default: return "unknown"
        }
    }

    static func name(_ status: CNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorized: return "authorized"
        case .limited: return "limited"
        @unknown default: return "unknown"
        }
    }

    static func name(_ status: EKAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .fullAccess: return "fullAccess"
        case .writeOnly: return "writeOnly"
        @unknown default: return "unknown"
        }
    }

    static func name(_ permission: AVAudioApplication.recordPermission) -> String {
        switch permission {
        case .undetermined: return "notDetermined"
        case .denied: return "denied"
        case .granted: return "authorized"
        @unknown default: return "unknown"
        }
    }

    static func name(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorized: return "authorized"
        @unknown default: return "unknown"
        }
    }

    static func name(_ status: CMAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorized: return "authorized"
        @unknown default: return "unknown"
        }
    }

    static func name(_ status: MPMediaLibraryAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorized: return "authorized"
        @unknown default: return "unknown"
        }
    }

    static func name(_ code: LAError.Code) -> String {
        switch code {
        case .authenticationFailed: return "Failed"
        case .userCancel: return "Cancelled"
        case .systemCancel: return "Cancelled by the system"
        case .appCancel: return "Cancelled by the app"
        case .userFallback: return "Fallback"
        case .biometryNotEnrolled: return "Not enrolled"
        case .biometryLockout: return "Locked out"
        case .biometryNotAvailable: return "Not available"
        default: return "Error \(code.rawValue)"
        }
    }
}

extension VerifierModel: UNUserNotificationCenterDelegate {
    /// A push (simctl push) that arrives while the verifier is in front.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let content = notification.request.content
        let title = content.title
        let body = content.body
        let date = notification.date
        await MainActor.run {
            update("appConditions.push", Readings.push(title: title, body: body, at: date))
        }
        return [.banner, .list]
    }
}

extension VerifierModel: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let fix = locations.last else { return }
        let latitude = fix.coordinate.latitude
        let longitude = fix.coordinate.longitude
        let accuracy = fix.horizontalAccuracy
        let time = fix.timestamp
        MainActor.assumeIsolated {
            update("location.lastFix", Readings.location(
                latitude: latitude,
                longitude: longitude,
                accuracy: accuracy,
                at: time
            ))
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // kCLErrorLocationUnknown (0) only means "no fix yet": keep waiting.
        guard (error as? CLError)?.code != .locationUnknown else { return }
        let message = error.localizedDescription
        MainActor.assumeIsolated {
            update("location.lastFix", Readings.locationUnavailable("Error: \(message)"))
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            startLocation()
            refresh()
        }
    }
}
