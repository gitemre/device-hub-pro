import XCTest
import AppKit
import SwiftUI
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// The capture folder preference, the saved-capture thumbnail's state and the
/// Face ID shortcut wiring. No device, no GUI.
@MainActor
final class CaptureExtrasTests: XCTestCase {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureExtrasTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data("shot".utf8)

    // MARK: - Capture folder preference

    func testTheCaptureFolderDefaultsToNothingAndPersists() throws {
        let defaults = UserDefaults.scratch()
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertEqual(preferences.captureFolderPath, "")
        XCTAssertNil(preferences.captureFolder)

        let directory = try makeDirectory()
        preferences.setCaptureFolder(directory)

        XCTAssertEqual(defaults.string(forKey: "captureFolderPath"), directory.path)
        let reread = AppPreferences(defaults: defaults)
        XCTAssertEqual(reread.captureFolder?.path, directory.path)

        reread.setCaptureFolder(nil)
        XCTAssertNil(defaults.object(forKey: "captureFolderPath"))
        XCTAssertNil(AppPreferences(defaults: defaults).captureFolder)
    }

    func testAMissingOrNonFolderPathFallsBackToTheDefault() throws {
        let preferences = AppPreferences(defaults: .scratch())
        preferences.setCaptureFolder(URL(fileURLWithPath: "/no/such/folder/for/captures", isDirectory: true))
        XCTAssertNil(preferences.captureFolder)

        let file = try makeDirectory().appendingPathComponent("a.txt")
        try Data("x".utf8).write(to: file)
        preferences.setCaptureFolder(file)
        XCTAssertNil(preferences.captureFolder, "a file is not a folder")
    }

    func testAScreenshotIsSavedInTheChosenFolder() async throws {
        let defaultFolder = try makeDirectory()
        let chosen = try makeDirectory()
        let picker = TestPicker()
        picker.autoSaveDirectory = defaultFolder
        let preferences = AppPreferences(defaults: .scratch())
        let context = ActiveDeviceContext()
        let capture = CaptureController(
            adbClient: nil,
            status: StatusCenter(),
            preferences: preferences,
            context: context,
            pasteboard: TestPasteboard(),
            picker: picker
        )
        context.device = .apple("00000000-0000-4000-8000-000000000001")

        let first = try XCTUnwrap(capture.saveScreenshot(Self.png))
        XCTAssertEqual(first.deletingLastPathComponent().standardizedFileURL.path, defaultFolder.standardizedFileURL.path)

        preferences.setCaptureFolder(chosen)
        let second = try XCTUnwrap(capture.saveScreenshot(Self.png))
        XCTAssertEqual(second.deletingLastPathComponent().standardizedFileURL.path, chosen.standardizedFileURL.path)

        // The chosen folder is removed: back to the default, no failed save.
        try FileManager.default.removeItem(at: chosen)
        let third = try XCTUnwrap(capture.saveScreenshot(Self.png))
        XCTAssertEqual(third.deletingLastPathComponent().standardizedFileURL.path, defaultFolder.standardizedFileURL.path)
    }

    // MARK: - The thumbnail's state

    func testASavedScreenshotCarriesItsBannerTextAndFileDrag() throws {
        let directory = try makeDirectory()
        let url = directory.appendingPathComponent("Screenshot.png")
        try Self.png.write(to: url)

        let shot = SavedScreenshot(url: url, thumbnail: nil)

        XCTAssertEqual(shot.kind, .screenshot)
        XCTAssertEqual(shot.title, "Screenshot Saved")
        XCTAssertNotNil(shot.dragProvider(), "the saved file is what a drag carries")
        XCTAssertEqual(shot.dragProvider()?.suggestedName, shot.url.deletingPathExtension().lastPathComponent,
                       "Finder names the dropped copy after the saved file")

        try FileManager.default.removeItem(at: url)
        XCTAssertNil(shot.dragProvider(), "a file that is gone is not offered")
    }

    func testASavedRecordingRaisesTheSameBannerAndReplacesAScreenshot() async throws {
        let directory = try makeDirectory()
        let picker = TestPicker()
        picker.autoSaveDirectory = directory
        let capture = CaptureController(
            adbClient: nil,
            status: StatusCenter(),
            preferences: AppPreferences(defaults: .scratch()),
            context: ActiveDeviceContext(),
            pasteboard: TestPasteboard(),
            picker: picker
        )
        capture.saveScreenshot(Self.png)
        let screenshot = try XCTUnwrap(capture.savedScreenshot)

        let clip = directory.appendingPathComponent("clip.mov")
        try Data("not a movie".utf8).write(to: clip)
        capture.showSavedRecording(at: clip)

        let recording = try XCTUnwrap(capture.savedScreenshot)
        XCTAssertNotEqual(recording.id, screenshot.id)
        XCTAssertEqual(recording.kind, .recording)
        XCTAssertEqual(recording.title, "Recording Saved")
        XCTAssertEqual(recording.url, clip)
        XCTAssertNotNil(recording.dragProvider())

        // Clicking reveals the clip and takes the banner down.
        var revealed: [URL] = []
        capture.revealInFinder = { revealed.append($0) }
        capture.revealSavedScreenshot()
        XCTAssertEqual(revealed, [clip])
        XCTAssertNil(capture.savedScreenshot)
    }

    // MARK: - Face ID shortcuts

    func testBiometricShortcutsOnlyReachTheDevicesOwnMenu() {
        let match = BiometricShortcuts.shortcut(menu: "Face ID", deviceType: nil, matching: true)
        XCTAssertEqual(match, BiometricShortcuts.match)
        XCTAssertEqual(BiometricShortcuts.shortcut(menu: "Face ID", deviceType: "Face ID", matching: false), BiometricShortcuts.nonMatch)
        XCTAssertNil(BiometricShortcuts.shortcut(menu: "Touch ID", deviceType: "Face ID", matching: true))
        XCTAssertNil(BiometricShortcuts.shortcut(menu: "Face ID", deviceType: "Touch ID", matching: true))
        XCTAssertEqual(BiometricShortcuts.shortcut(menu: "Touch ID", deviceType: "Touch ID", matching: true), BiometricShortcuts.match)
    }

    /// ⌥⌘M is Open Compact Mirror's: the Face ID pair must not shadow it.
    func testBiometricShortcutsDoNotCollideWithTheCompactMirrorOrEachOther() {
        let compactMirror = KeyboardShortcut("m", modifiers: [.command, .option])
        XCTAssertNotEqual(BiometricShortcuts.match, compactMirror)
        XCTAssertNotEqual(BiometricShortcuts.match, BiometricShortcuts.nonMatch)
        XCTAssertNotEqual(BiometricShortcuts.nonMatch, KeyboardShortcut("n", modifiers: [.command, .shift]), "⇧⌘N opens a new window")
    }
}
