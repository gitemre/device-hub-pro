import AppKit
import AVFoundation
import Foundation
import Observation
import DeviceHubProKit

/// How saving the annotation editor's PNG ended.
enum AnnotationSaveOutcome: Equatable {
    case saved
    /// The save panel was dismissed: the editor stays open, annotations kept.
    case cancelled
    /// The write failed; the editor shows the message itself.
    case failed(String)
}

/// A screenshot the pill's capture button saved, for the "Screenshot Saved"
/// banner (`StageBanner`): where it went and a thumbnail of it.
struct SavedScreenshot: Identifiable, Equatable {
    enum Kind: Equatable { case screenshot, recording, replay }

    var id = UUID()
    let url: URL
    var thumbnail: NSImage?
    var kind: Kind = .screenshot

    /// The banner's title.
    var title: String {
        switch kind {
        case .screenshot: return "Screenshot Saved"
        case .recording: return "Recording Saved"
        case .replay: return "Replay Saved"
        }
    }
    /// The banner's second line: the card reveals, the thumbnail drags out.
    var subtitle: String { "Click to reveal, drag to share" }

    /// What a drag of the thumbnail carries: the saved file itself, so
    /// Finder and other apps receive a copy of it under its own name
    /// (without `suggestedName` Finder names the copy "PNG image"). Nil when
    /// the file is gone.
    func dragProvider(fileManager: FileManager = .default) -> NSItemProvider? {
        guard fileManager.fileExists(atPath: url.path),
              let provider = NSItemProvider(contentsOf: url) else { return nil }
        provider.suggestedName = url.deletingPathExtension().lastPathComponent
        return provider
    }
}

/// Where Device Hub puts a screenshot and what it calls it (measured on DH
/// 27.0: the Desktop, "Screenshot <device> <date> at <time>.png", the date
/// and time in the user's format with the separators macOS file names may
/// hold, so 29.09.2026 at 13.13.30).
enum ScreenshotFile {
    /// `path` as a directory when it names a folder that exists, else nil.
    static func existingDirectory(path: String, fileManager: FileManager = .default) -> URL? {
        guard !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return url
    }

    /// The macOS screenshot folder (`com.apple.screencapture location`)
    /// when it names a folder that exists, else the Desktop.
    static func defaultDirectory(
        configured: String? = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"),
        fileManager: FileManager = .default
    ) -> URL {
        if let configured, !configured.isEmpty {
            let url = URL(fileURLWithPath: (configured as NSString).expandingTildeInPath, isDirectory: true)
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return url
            }
        }
        return fileManager.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    /// "Screenshot iPhone 17 29.09.2026 at 13.13.30.png".
    static func name(device: String?, date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let day = DateFormatter()
        day.locale = locale
        day.timeZone = timeZone
        day.dateStyle = .short
        day.timeStyle = .none
        let time = DateFormatter()
        time.locale = locale
        time.timeZone = timeZone
        time.dateStyle = .none
        time.timeStyle = .medium
        let stamp = "\(day.string(from: date)) at \(time.string(from: date))"
        let safe = sanitized(stamp)
        let subject = device.map { sanitized($0) }.flatMap { $0.isEmpty ? nil : $0 }
        return ["Screenshot", subject, safe].compactMap { $0 }.joined(separator: " ") + ".png"
    }

    /// A file-name part: no path separators, and the colons of a time
    /// written as dots.
    static func sanitized(_ text: String) -> String {
        text.replacingOccurrences(of: "/", with: ".")
            .replacingOccurrences(of: ":", with: ".")
            .trimmingCharacters(in: .whitespaces)
    }

    /// `name` in `directory`, or `name 2`, `name 3`, … before its extension
    /// while that file exists.
    static func uniqueURL(named name: String, in directory: URL, fileManager: FileManager = .default) -> URL {
        let first = directory.appendingPathComponent(name)
        guard fileManager.fileExists(atPath: first.path) else { return first }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var index = 2
        while true {
            let candidate = directory.appendingPathComponent("\(base) \(index)").appendingPathExtension(ext)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }
}

/// Screenshots of the mirrored device (the capture button saves one straight
/// to the screenshot folder, Device Hub's way, and shows the "Screenshot
/// Saved" banner; the annotation editor is opened from the button's
/// right-click menu; the copy variant goes to the clipboard) and the
/// Diagnostics tab's bundle download.
///
/// One per `DeviceWorkspace` (`capture`), which the views and menus read
/// directly. Screenshots read the
/// mirrored device from the shared `ActiveDeviceContext`; the diagnostics
/// bundle reads the stage's live serial through `liveSelectionSerialProvider`
/// instead, and the two stay separate.
@MainActor
@Observable
final class CaptureController {
    private let adbClient: AdbClient?
    private let status: StatusCenter
    private let preferences: AppPreferences
    private let context: ActiveDeviceContext
    /// Where a copied screenshot goes (the Mac pasteboard in the app).
    private let pasteboard: any MacPasteboard
    /// Asks where a saved screenshot or diagnostics bundle goes (the save
    /// panel in the app).
    private let picker: any FileDestinationPicker
    /// The stage's live serial (`AppModel.liveSelectionSerial`), which the
    /// diagnostics bundle is collected from. Wired by its owner once it
    /// exists; nil until then.
    @ObservationIgnored var liveSelectionSerialProvider: @MainActor () -> String? = { nil }
    /// The mirrored device's display shapes (`MirrorController.liveDisplayShapes`),
    /// so a framed screenshot clips the screen to the corner the live stage
    /// shows. Wired by its owner; empty until then.
    @ObservationIgnored var displayShapesProvider: @MainActor () -> [DisplayShape] = { [] }
    /// A PNG of the mirrored simulator's screen
    /// (`SimulatorCanvasController.screenshotPNG`): the live canvas's frame,
    /// else `simctl io screenshot`; nil when no simulator is mirrored.
    /// Wired by its owner; nil until then.
    @ObservationIgnored var simulatorScreenshot: (@MainActor () async throws -> Data?)?
    /// The mirrored simulator's Apple chrome and how its device is turned
    /// (`SimulatorCanvasController.devicePose`), so a framed screenshot
    /// shows the stage's chrome; nil for any other device and for a
    /// simulator without one (it keeps the vector body). Wired by its owner.
    @ObservationIgnored var appleChromeCapture: @MainActor () -> AppleChromeCapture? = { nil }
    /// The mirrored device's name for a saved screenshot's file name
    /// (`AppServices.displayName(of:)`). Wired by its owner; the device's id
    /// until then.
    @ObservationIgnored var displayName: @MainActor (DeviceRef) -> String = { $0.id }
    /// Shows a saved file in Finder (the banner's "Open in Finder").
    @ObservationIgnored var revealInFinder: @MainActor (URL) -> Void = { url in
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    @ObservationIgnored var now: () -> Date = Date.init
    /// How long the banner stays (Device Hub's: about three seconds).
    var bannerDuration: Duration = .seconds(3)
    /// Told after a screenshot was saved (the workspace shows the one-time
    /// replay tip through it).
    @ObservationIgnored var onScreenshotSaved: @MainActor () -> Void = {}

    /// The screenshot the banner shows; nil once it timed out or was opened.
    private(set) var savedScreenshot: SavedScreenshot?
    @ObservationIgnored private var bannerTask: Task<Void, Never>?

    /// A simulator's chrome for a framed screenshot: the frame, the device's
    /// counter-clockwise turns and the rotation the live session reported
    /// for its frames (nil on the view-only canvas).
    struct AppleChromeCapture {
        var frame: AppleChromeFrame
        var deviceTurns: Int
        var reported: SimulatorFrameRotation?
    }

    init(
        adbClient: AdbClient?,
        status: StatusCenter,
        preferences: AppPreferences,
        context: ActiveDeviceContext,
        pasteboard: any MacPasteboard,
        picker: any FileDestinationPicker
    ) {
        self.adbClient = adbClient
        self.status = status
        self.preferences = preferences
        self.context = context
        self.pasteboard = pasteboard
        self.picker = picker
    }

    /// The annotation editor's request; set after a capture, cleared on
    /// apply or cancel.
    var annotationEditRequest: AnnotationEditRequest?

    /// Cancelling the editor discards the capture.
    func cancelAnnotationEditing() {
        annotationEditRequest = nil
    }

    /// Frames the shot when the option is on, off the main actor (decoding
    /// the artwork and encoding the PNG take a few hundred ms):
    ///
    /// - an AVD with a skin in its artwork, the screen clipped to the corner
    ///   the live stage uses for the same display and the device's camera
    ///   cutout filled black (`screenShapeResolver`); a capture in a pose
    ///   the skin has no display for (landscape, for every modern skin and
    ///   the open fold) in the natural display's artwork turned by the
    ///   capture's display rotation, as the stage turns it, or in the
    ///   vector body when that rotation cannot be read;
    /// - any other Android device (a physical phone, a skinless AVD) in the
    ///   vector body its reported displays plan
    ///   (`DeviceCompositionPlanner.vector`), cutout included;
    /// - a simulator in its Apple chrome (`appleChromeCapture`), turned
    ///   with the device as on the stage, the buttons at rest;
    /// - any other simulator in the vector body its device type's display
    ///   plans (`SimulatorDisplayProfile`, no cutout: the simulator draws its
    ///   Dynamic Island into the picture), the live stage's body.
    ///
    /// Both paths take the capture's panel from the live stage's shapes
    /// (`displayShapesProvider`), its cutout turned the way the capture is:
    /// upright when the capture has the panel's own orientation, else by one
    /// read of the display rotation. An undecodable shot or a failed
    /// composite keeps the raw shot and says so in the status flash.
    private func framedScreenshot(_ png: Data) async -> Data {
        guard includeDeviceFrameInScreenshots else { return png }
        guard let size = DeviceFrameRenderer.pixelSize(ofScreenshot: png) else {
            flashStatus("Device frame unavailable — continuing without it: \(DeviceFrameError.imageDecodeFailed)")
            return png
        }
        if let chrome = appleChromeCapture() {
            // The stage's Apple chrome, turned with the device; the shot,
            // posed by the interface, turned into the device's pose.
            let content = AppleChromePose.contentTurns(
                frame: size,
                native: chrome.frame.screenPixels,
                reported: chrome.reported,
                deviceTurns: chrome.deviceTurns
            )
            do {
                return try await DeviceFrameRenderer.composeInBackground(
                    screenshot: png,
                    composition: DeviceCompositionPlanner.appleChrome(chrome.frame, quarterTurns: chrome.deviceTurns),
                    screenshotTurns: chrome.deviceTurns - content
                )
            } catch {
                flashStatus("Device frame unavailable — continuing without it: \(error)")
                return png
            }
        }
        let shapes = displayShapesProvider()
        let avd = activeAvdName
        let turns = await quarterTurns(ofCapture: size, shapes: shapes)
        let plan = DeviceCompositionPlanner.vector(
            screen: size,
            displays: shapes,
            fallbackDensityDpi: avd.flatMap { AvdConfig.lcdDensity(avdName: $0, avdHome: context.avdHome) },
            hingeCount: context.hingeCount,
            quarterTurns: turns
        )
        do {
            if let avd {
                do {
                    // A skin with no display in the capture's pose (the
                    // open fold, every modern skin in landscape) is turned
                    // by the read rotation, as the stage turns it.
                    if let framed = try await DeviceFrameRenderer.composeInBackground(
                        screenshot: png,
                        avdName: avd,
                        avdHome: context.avdHome,
                        quarterTurns: turns,
                        screenShape: Self.screenShapeResolver(
                            shapes: shapes,
                            cutout: plan.cutout,
                            cache: SkinThumbnailCache.shared
                        )
                    ) {
                        return framed
                    }
                } catch DeviceFrameError.artworkMissing {
                    // No display for the pose and no rotation to turn one
                    // by (the read failed): the vector body, not the raw
                    // shot.
                }
            }
            return try await DeviceFrameRenderer.composeInBackground(screenshot: png, composition: plan)
        } catch {
            flashStatus("Device frame unavailable — continuing without it: \(error)")
            return png
        }
    }

    /// The display rotation (`Surface.ROTATION_*`) a capture of `capture`
    /// pixels was taken at, as far as the frame needs it (the cutout's
    /// place, and the turn of a skin with no display in the capture's pose):
    /// 0 when the capture has its panel's natural orientation (an
    /// upside-down portrait is taken for upright, as on the live stage),
    /// else one read of `dumpsys display`. Nil, and nothing read, when the
    /// panel is unknown; nil too when the read fails (the cutout is then
    /// left out, and such a skin gives way to the vector body).
    private func quarterTurns(ofCapture capture: CGSize, shapes: [DisplayShape]) async -> Int? {
        guard let shape = DisplayShape.matching(frame: capture, in: shapes) else {
            return nil
        }
        let natural = shape.naturalSize
        let sameOrientation = capture.width == capture.height
            || natural.width == natural.height
            || (capture.width > capture.height) == (natural.width > natural.height)
        if sameOrientation { return 0 }
        guard let adbClient, let serial = activeSerial else { return nil }
        return await adbClient.displayRotation(serial: serial)
    }

    /// The live stage's screen corner for the display a capture is framed
    /// in: the device's display matching the capture's size among `shapes`,
    /// under the same policy and measured artwork traits as the live stage
    /// (`cache`), measured off the main actor when the live stage has not
    /// measured them yet.
    nonisolated static func screenCornerResolver(
        shapes: [DisplayShape],
        cache: SkinThumbnailCache
    ) -> DeviceFrameRenderer.ScreenCornerResolver {
        { variant, display, frame in
            await cache.screenCornerMeasuredOffMain(
                for: variant,
                display: display,
                device: DisplayShape.matching(frame: frame, in: shapes)
            ).radius
        }
    }

    /// `screenCornerResolver`'s corner plus `cutout`: the device's camera
    /// cutout placed for the capture (the vector plan's, which follows the
    /// same rules), filled black on the skin's display.
    nonisolated static func screenShapeResolver(
        shapes: [DisplayShape],
        cutout: CutoutPlacement?,
        cache: SkinThumbnailCache
    ) -> DeviceFrameRenderer.ScreenShapeResolver {
        let corner = screenCornerResolver(shapes: shapes, cache: cache)
        return { variant, display, frame in
            (radius: await corner(variant, display, frame), cutout: cutout)
        }
    }

    /// Whether Take Screenshot and Copy Screenshot can act: an adb device is
    /// mirrored (`adb exec-out screencap`), or a simulator is (its canvas's
    /// frame, else `simctl io screenshot`).
    var canTakeScreenshot: Bool {
        activeSerial != nil || (context.device?.platform == .apple && simulatorScreenshot != nil)
    }

    /// The capture button: the screenshot (framed when the option is on)
    /// saved at once in the screenshot folder, and the banner.
    func takeScreenshot() async {
        do {
            guard let raw = try await rawScreenshot() else { flashStatus("No screen to capture yet."); return }
            saveScreenshot(await framedScreenshot(raw))
        } catch {
            if !error.isCancellation { errorMessage = "\(error)" }
        }
    }

    /// The capture button's right-click "Annotate…": the screenshot in the
    /// annotation editor, which saves through a save panel.
    func annotateScreenshot() async {
        do {
            guard let raw = try await rawScreenshot() else { flashStatus("No screen to capture yet."); return }
            annotationEditRequest = AnnotationEditRequest(png: await framedScreenshot(raw))
        } catch {
            if !error.isCancellation { errorMessage = "\(error)" }
        }
    }

    /// A screenshot another tool took (a physical Apple device's `devicectl
    /// device capture screenshot`): saved and announced like every other
    /// device's, raw (no device frame: there is no chrome for a physical
    /// device).
    func editScreenshot(_ png: Data) {
        saveScreenshot(png)
    }

    /// Writes `png` to the screenshot folder under Device Hub's name and
    /// raises the banner; a failed write is an error alert.
    @discardableResult
    func saveScreenshot(_ png: Data) -> URL? {
        let directory = preferences.captureFolder ?? picker.screenshotDirectory
        let name = ScreenshotFile.name(device: context.device.map(displayName), date: now())
        let url = ScreenshotFile.uniqueURL(named: name, in: directory)
        do {
            try png.write(to: url, options: .atomic)
        } catch {
            errorMessage = "Could not save the screenshot: \(error.localizedDescription)"
            return nil
        }
        showBanner(for: SavedScreenshot(url: url, thumbnail: NSImage(data: png)))
        onScreenshotSaved()
        return url
    }

    /// A recording saved at `url`: the same banner, with the clip's first
    /// frame as its thumbnail once that is read.
    func showSavedRecording(at url: URL, kind: SavedScreenshot.Kind = .recording) {
        let shot = SavedScreenshot(url: url, thumbnail: nil, kind: kind)
        showBanner(for: shot)
        Task { @MainActor [weak self] in
            guard let image = await Self.firstFrame(of: url) else { return }
            guard var current = self?.savedScreenshot, current.id == shot.id else { return }
            current.thumbnail = image
            self?.savedScreenshot = current
        }
    }

    /// The clip's first frame, read off the main actor; nil when it cannot be.
    nonisolated static func firstFrame(of url: URL) async -> NSImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 160)
        guard let cg = try? await generator.image(at: .zero).image else { return nil }
        return NSImage(cgImage: cg, size: .zero)
    }

    private func showBanner(for shot: SavedScreenshot) {
        bannerTask?.cancel()
        savedScreenshot = shot
        let duration = bannerDuration
        bannerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, self?.savedScreenshot?.id == shot.id else { return }
            self?.savedScreenshot = nil
        }
    }

    /// Takes the banner down.
    func dismissBanner() {
        bannerTask?.cancel()
        bannerTask = nil
        savedScreenshot = nil
    }

    /// The banner's "Open in Finder": the file selected in Finder.
    func revealSavedScreenshot() {
        guard let shot = savedScreenshot else { return }
        revealInFinder(shot.url)
        dismissBanner()
    }

    func copyScreenshotToClipboard() async {
        do {
            guard let raw = try await rawScreenshot() else { flashStatus("No screen to capture yet."); return }
            let png = await framedScreenshot(raw)
            pasteboard.setPNG(png)
        } catch {
            if !error.isCancellation { errorMessage = "\(error)" }
        }
    }

    /// The mirrored device's screen as a PNG: `adb exec-out screencap` for
    /// an adb device, the simulator's capture for a simulator; nil when
    /// nothing is mirrored (or there is no adb).
    private func rawScreenshot() async throws -> Data? {
        if let serial = activeSerial {
            guard let adbClient else { return nil }
            return try await adbClient.screenshot(serial: serial)
        }
        guard context.device?.platform == .apple, let simulatorScreenshot else { return nil }
        return try await simulatorScreenshot()
    }

    /// Saves the annotation editor's PNG through a save panel and closes the
    /// editor. A failure is returned to the editor instead of raised through
    /// `errorMessage`: the editor is a sheet, and the window's alert behind
    /// it would only appear once the sheet — and the annotations — were gone.
    func saveAnnotatedScreenshot(_ png: Data) -> AnnotationSaveOutcome {
        guard annotationEditRequest != nil else { return .cancelled }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        guard let url = picker.chooseDestination(
            suggestedName: "devicehubpro-\(formatter.string(from: Date())).png",
            directory: nil
        ) else { return .cancelled }
        return writeAnnotatedScreenshot(png, to: url)
    }

    /// The write behind `saveAnnotatedScreenshot`: the editor closes only
    /// once the file is on disk.
    func writeAnnotatedScreenshot(_ png: Data, to url: URL) -> AnnotationSaveOutcome {
        guard annotationEditRequest != nil else { return .cancelled }
        do {
            try png.write(to: url)
        } catch {
            return .failed("Could not save the screenshot: \(error.localizedDescription)")
        }
        annotationEditRequest = nil
        return .saved
    }

    // MARK: - Diagnostics bundle (Diagnostics tab)

    /// True while the Diagnostics inspector is collecting a bundle.
    var isCollectingDiagnostics = false

    /// The Diagnostics inspector's action: ask for a destination, collect the
    /// bundle from the selected (live) device, then reveal the zip in Finder.
    /// The assembly itself lives in `DeviceHubProKit.DiagnosticsBundle`.
    func downloadDiagnosticsBundle() async {
        guard let adbClient, let serial = liveSelectionSerial else { return }

        guard let url = picker.chooseDestination(
            suggestedName: DiagnosticsBundle.suggestedFileName(serial: serial),
            directory: nil
        ) else { return }

        isCollectingDiagnostics = true
        defer { isCollectingDiagnostics = false }

        do {
            let collected = try await DiagnosticsBundle.collect(
                serial: serial,
                adb: adbClient,
                into: url.deletingLastPathComponent()
            )
            if collected.url != url {
                try? FileManager.default.removeItem(at: url)
                try FileManager.default.moveItem(at: collected.url, to: url)
            }
            NSWorkspace.shared.activateFileViewerSelecting([url])
            flashStatus(Self.diagnosticsStatus(for: collected))
        } catch {
            errorMessage = "Could not collect diagnostics: \(error)"
        }
    }

    /// The status flash for a collected bundle: "saved", plus whatever the
    /// bundle lacks — sections that failed (their `.error.txt` says why),
    /// logcat's line-count fallback, the host-clock window.
    static func diagnosticsStatus(for result: DiagnosticsBundleResult) -> String {
        var notes: [String] = []
        if !result.failedSections.isEmpty {
            notes.append("could not collect \(result.failedSections.joined(separator: ", ")) (see the .error.txt files)")
        }
        if result.usedLogcatLineFallback {
            notes.append("logcat holds the last \(DiagnosticsBundle.logcatFallbackLineCount) lines, not the last five minutes")
        } else if result.usedHostClockFallback {
            notes.append("device clock unavailable, the logcat window is approximate")
        }
        guard !notes.isEmpty else { return "Diagnostics bundle saved" }
        return "Diagnostics bundle saved — " + notes.joined(separator: "; ")
    }

    // MARK: - The names the moved members use

    private var activeSerial: String? { context.serial }

    private var activeAvdName: String? { context.avdName }

    private var includeDeviceFrameInScreenshots: Bool { preferences.includeDeviceFrameInScreenshots }

    private var liveSelectionSerial: String? { liveSelectionSerialProvider() }

    private var errorMessage: String? {
        get { status.errorMessage }
        set { status.errorMessage = newValue }
    }

    private func flashStatus(_ message: String) {
        status.flash(message)
    }
}
