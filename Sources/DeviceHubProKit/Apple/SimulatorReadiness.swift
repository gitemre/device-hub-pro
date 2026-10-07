import CoreGraphics
import Foundation
import ImageIO

/// One job from `simctl spawn <UDID> launchctl list`: the device's launchd
/// jobs, one `PID<TAB>Status<TAB>Label` line each under a header. A job that
/// is loaded but not running has `-` for its pid.
public struct SimulatorLaunchdJob: Sendable, Equatable {
    /// The running process, nil for a job that is not running.
    public let pid: Int?
    /// The last exit status launchd recorded (0 when it never exited).
    public let status: Int?
    public let label: String

    public init(pid: Int?, status: Int?, label: String) {
        self.pid = pid
        self.status = status
        self.label = label
    }
}

extension DeviceBootPhase {
    /// The phase a `simctl bootstatus` update reports. Finished leaves the
    /// home screen to wait for.
    public init(_ phase: SimulatorBootStatus.Phase) {
        switch phase {
        case .waitingOnBackBoard: self = .waitingOnBackBoard
        case .waitingOnDataMigration: self = .migratingData
        case .waitingOnSystemApp: self = .waitingOnSystemApp
        case .finished: self = .waitingOnHomeScreen
        case .other(let text): self = .other(text)
        }
    }
}

/// When a booted simulator is ready: its boot status is
/// Finished, its home screen process runs (SpringBoard; PineBoard on tvOS),
/// **and** its screen shows the home screen rather than the boot screen.
/// `simctl list` says Booted long before.
///
/// Measured on iOS 27.0 (CoreSimulator 1171.7, 2026-09-26), no signal short
/// of the screen itself is enough:
/// - SpringBoard already had a pid 0.03 s after `simctl boot` returned on a
///   first boot, while `bootstatus` was still waiting on BackBoard and on
///   data migration (Finished came 21.7 s later).
/// - Finished with SpringBoard running came 3.75 s into a warm boot and
///   0.6 s after the migration of a boot after an erase; a screenshot taken
///   at that moment showed the Apple logo both times (the home screen came
///   seconds later). SpringBoard's `com.apple.springboard.finishedstartup`
///   notify state, 0 in the poll before Finished, held its pid in the first
///   poll after (0.5 s later), so it adds nothing.
/// - After a cold first boot the same two signals did coincide with a drawn
///   home screen (its icons still loading).
///
/// So the screen is the third condition: without the live canvas a `simctl
/// io screenshot`, with it a frame. The boot screen is black but for the
/// Apple logo in its middle; the home screen draws outside that box (the
/// status bar, the dock, the icons, even while they load; a locked iOS 27.0
/// simulator shows its lock screen, which counts too). A screen with
/// nothing lit at all is `dark`: a screen that is off, or the black a tvOS
/// 27.0 boot showed for 3.6 s between the boot screen and the home screen
/// (`simctl-io-screenshot.tvos-dark.png`).
public enum SimulatorReadiness {
    /// SpringBoard's launchd label: the home screen of iOS and iPadOS.
    public static let homeScreenLabel = "com.apple.SpringBoard"
    /// PineBoard's launchd label: tvOS's home screen (tvOS has no
    /// SpringBoard job).
    public static let tvHomeScreenLabel = "com.apple.PineBoard"

    /// The launchd label of the home screen process on a runtime `platform`
    /// (`SimulatorRuntime.platform`, "iOS" for iPadOS too): SpringBoard on
    /// iOS, PineBoard on tvOS, both from job lists captured on Xcode 27
    /// (`simctl-spawn-launchctl-list.ready` and `.tvos-ready`). Nil for a
    /// platform no list was captured on (watchOS, visionOS) or an unknown
    /// one: the ready signal then goes by the boot status and the screen.
    public static func homeScreenLabel(platform: String?) -> String? {
        switch platform {
        case "iOS"?: homeScreenLabel
        case "tvOS"?: tvHomeScreenLabel
        default: nil
        }
    }

    /// The home screen process's name on a runtime `platform`, as the boot
    /// progress names it: SpringBoard on iOS, PineBoard on tvOS; nil where
    /// none is known (`homeScreenLabel(platform:)`).
    public static func homeScreenProcessName(platform: String?) -> String? {
        switch platform {
        case "iOS"?: "SpringBoard"
        case "tvOS"?: "PineBoard"
        default: nil
        }
    }

    /// The pid of the job labelled `label` (by default SpringBoard) when it
    /// runs, nil when it is not loaded or not running (`-`).
    public static func homeScreenPID(in jobs: [SimulatorLaunchdJob], label: String = homeScreenLabel) -> Int? {
        jobs.first { $0.label == label }?.pid
    }

    /// Whether a `bootstatus` run that exited 0 saw the boot finish: its last
    /// update is Finished, or it printed none because the boot had already
    /// finished (simctl then prints only "Device already booted, nothing to
    /// do.").
    public static func bootFinished(lastUpdate: SimulatorBootStatus?) -> Bool {
        lastUpdate.map(\.isFinished) ?? true
    }

    /// All three: the boot finished, the home screen process runs, and the
    /// screen shows more than the boot screen.
    public static func isReady(bootFinished: Bool, homeScreenPID: Int?, showsHomeScreen: Bool) -> Bool {
        bootFinished && homeScreenPID != nil && showsHomeScreen
    }

    /// What a screenshot or a frame shows.
    public enum ScreenContent: Sendable, Equatable {
        /// Something outside the logo's box: the home screen (or the lock
        /// screen, or an app).
        case homeScreen
        /// Something lit inside the logo's box only: the boot screen.
        case bootScreen
        /// Nothing lit: a screen that is off, or a black transition.
        case dark
    }

    /// Whether `image` (a screenshot or a frame, upright) shows anything
    /// outside the box the boot screen's Apple logo sits in. The image is
    /// reduced to a 120-pixel-wide grey thumbnail first, so a status bar's
    /// text still registers while compression noise does not. A black
    /// screen is no home screen either.
    public static func showsHomeScreen(_ image: CGImage) -> Bool {
        screenContent(image) == .homeScreen
    }

    /// What `image` (a screenshot or a frame, upright) shows, told from the
    /// lit pixels of a 120-pixel-wide grey thumbnail: outside the logo's box
    /// (the home screen), only inside it (the boot screen), or none (dark).
    /// Nil when the image cannot be drawn.
    public static func screenContent(_ image: CGImage) -> ScreenContent? {
        guard image.width > 0, image.height > 0 else { return nil }
        let width = 120
        let height = max(1, Int((Double(image.height) * Double(width) / Double(image.width)).rounded()))
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        // The logo's box, with a margin, in the middle of the screen (it is
        // centred vertically, so the bitmap's bottom-up rows do not matter).
        let logoColumns = Int(Double(width) * 0.3)..<Int(Double(width) * 0.7)
        let logoRows = Int(Double(height) * 0.38)..<Int(Double(height) * 0.62)
        var litOutside = 0
        var litInside = 0
        for row in 0..<height {
            for column in 0..<width where pixels[row * width + column] > litThreshold {
                if logoRows.contains(row) && logoColumns.contains(column) {
                    litInside += 1
                } else {
                    litOutside += 1
                }
            }
        }
        if litOutside >= minimumLitPixels { return .homeScreen }
        return litOutside + litInside >= minimumLitPixels ? .bootScreen : .dark
    }

    /// `showsHomeScreen` for a PNG file (`simctl io screenshot`); nil when
    /// the file holds no image.
    public static func showsHomeScreen(imageAt url: URL) -> Bool? {
        screenContent(imageAt: url).map { $0 == .homeScreen }
    }

    /// `screenContent` for a PNG file (`simctl io screenshot`); nil when the
    /// file holds no image.
    public static func screenContent(imageAt url: URL) -> ScreenContent? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return screenContent(image)
    }

    /// A thumbnail pixel brighter than this (of 255) is drawn content.
    static let litThreshold: UInt8 = 40
    /// How many such pixels outside the logo's box make a home screen.
    static let minimumLitPixels = 10
}
