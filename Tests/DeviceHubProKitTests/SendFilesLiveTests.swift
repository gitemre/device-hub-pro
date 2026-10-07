import XCTest
@testable import DeviceHubProKit

/// Send Files against real devices, behind switches (they skip otherwise):
///
///     DHP_SENDFILES_SERIAL=emulator-5580 swift test --filter SendFilesLiveTests/testAndroid
///
/// The Android test pins the one serial it may touch (an emulator the run made
/// for itself): it pushes a photo and a folder, checks `ls` and MediaStore
/// through `content query`, then removes what it pushed.
///
///     DHP_SENDFILES_SIM_SET=<private set folder> DHP_SENDFILES_SIM_UDID=<udid> \
///       swift test --filter SendFilesLiveTests/testSimulator
///
/// The simulator test names a booted simulator in a private device set the run
/// created, copies a folder into the Files app's storage and removes it.
final class SendFilesLiveTests: XCTestCase {
    private func makeFiles() throws -> (folder: URL, photo: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SendFilesLive-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("aqa-send-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: folder.appendingPathComponent("a.txt"))
        // A 1x1 PNG.
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
        try png.write(to: folder.appendingPathComponent("sub/inner.png"))
        let photo = root.appendingPathComponent("aqa photo one.png")
        try png.write(to: photo)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (folder, photo)
    }

    func testAndroid() async throws {
        guard let serial = ProcessInfo.processInfo.environment["DHP_SENDFILES_SERIAL"], !serial.isEmpty else {
            throw XCTSkip("set DHP_SENDFILES_SERIAL to an emulator made for this run")
        }
        guard let adb = AdbClient.locate() else { throw XCTSkip("adb not found") }
        let (folder, photo) = try makeFiles()
        let result = try await adb.send([photo, folder], to: .pictures, serial: serial)
        XCTAssertEqual(result.filesPushed, 3)
        XCTAssertEqual(result.destination, "/sdcard/Pictures")
        XCTAssertEqual(result.scanMisses, 0)
        let listing = try await adb.shell(serial: serial, ["ls", "-R", "/sdcard/Pictures"])
        print("SENDFILES-LIVE ls:\n\(listing)")
        XCTAssertTrue(listing.contains("aqa photo one.png"))
        XCTAssertTrue(listing.contains("inner.png"))
        let query = try await adb.shell(
            serial: serial,
            ["content", "query", "--uri", "content://media/external/images/media", "--projection", "_display_name:_data"]
        )
        print("SENDFILES-LIVE media:\n\(query)")
        XCTAssertTrue(query.contains("aqa photo one.png"), "the photo is in MediaStore")
        XCTAssertTrue(query.contains("inner.png"), "a file inside a pushed folder is too")
        // Put the emulator back.
        _ = try await adb.shell(serial: serial, ["rm", "-rf", "'/sdcard/Pictures/aqa photo one.png'", "/sdcard/Pictures/aqa-send-folder"])
        _ = try? await adb.shell(serial: serial, [AdbClient.scanFileCommand(path: "/storage/emulated/0/Pictures/aqa photo one.png")])
    }

    func testSimulator() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let set = environment["DHP_SENDFILES_SIM_SET"], let udid = environment["DHP_SENDFILES_SIM_UDID"],
              !set.isEmpty, !udid.isEmpty
        else { throw XCTSkip("set DHP_SENDFILES_SIM_SET and DHP_SENDFILES_SIM_UDID") }
        let toolchain = await AppleToolchain.probe()
        guard toolchain.simctlUsable, let simctl = toolchain.makeSimctlClient(deviceSet: URL(fileURLWithPath: set, isDirectory: true)) else {
            throw XCTSkip("simctl is not usable")
        }
        let (folder, photo) = try makeFiles()
        let storage = try await simctl.filesAppStorage(udid: udid)
        XCTAssertEqual(try SimctlClient.copyItems([folder], into: storage), 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: storage.appendingPathComponent("aqa-send-folder/sub/inner.png").path))
        try FileManager.default.removeItem(at: storage.appendingPathComponent("aqa-send-folder"))
        try await simctl.addMedia(udid: udid, files: [photo])
    }
}
