import AppKit
import XCTest
@testable import DeviceHubProApp
import DeviceHubProKit

/// The Apps rows' icon cache: warm disk-cache hits are synchronous (no
/// placeholder frame), the in-memory memo is keyed per path/serial, and a
/// failure is remembered per device and cleared when the device changes.
@MainActor
final class AppIconStoreTests: XCTestCase {
    /// A real 1x1 RGBA PNG, decodable by `NSImage`.
    private let pngPayload = Data(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
    )!

    func testWarmDiskCacheIsServedSynchronously() throws {
        let cache = try temporaryDirectory().appendingPathComponent("cache", isDirectory: true)
        try writeCachedIcon(package: "com.example.app", version: "42", in: cache)
        let store = AppIconStore(adbClient: nil, cacheDirectory: cache)

        let icon = store.icon(for: "com.example.app", version: "42", serial: "emulator-5554")

        XCTAssertNotNil(icon, "a warm disk cache must be served without a placeholder frame")
    }

    /// Rows call `icon(for:…)`/`icon(forLocalAPKAt:…)` from their body, so a
    /// warm-cache hit must not write the observed memo synchronously; the
    /// write is deferred to the next main-actor turn. Until then the hit is
    /// re-read from disk (a distinct `NSImage`), and afterwards every call
    /// shares the memoized instance.
    func testWarmDiskCacheHitDefersTheMemoWriteOffTheCallingTurn() async throws {
        let cache = try temporaryDirectory().appendingPathComponent("cache", isDirectory: true)
        try writeCachedIcon(package: "com.example.app", version: "42", in: cache)
        let store = AppIconStore(adbClient: nil, cacheDirectory: cache)

        let first = store.icon(for: "com.example.app", version: "42", serial: "emulator-5554")
        let second = store.icon(for: "com.example.app", version: "42", serial: "emulator-5554")

        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertFalse(
            first === second,
            "the warm-cache memo write must not land during the calling turn"
        )

        try await waitUntil("the deferred memo write") {
            store.icon(for: "com.example.app", version: "42", serial: "emulator-5554") === first
        }
    }

    func testLocalAPKIconIsMemoizedAcrossSymlinkedPaths() async throws {
        let directory = try temporaryDirectory()
        let cache = directory.appendingPathComponent("cache", isDirectory: true)
        try writeCachedIcon(package: "com.example.app", version: "42", in: cache)

        let real = directory.appendingPathComponent("app.apk")
        try Data("apk".utf8).write(to: real)
        let link = directory.appendingPathComponent("alias.apk")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let store = AppIconStore(adbClient: nil, cacheDirectory: cache)

        let first = store.icon(forLocalAPKAt: real, package: "com.example.app", version: "42")
        XCTAssertNotNil(first)

        // The memo write is deferred off the calling turn; the second lookup
        // may race it, so wait for it to land (a poll re-schedules an
        // idempotent write until it does).
        try await waitUntil("the deferred memo write") {
            store.icon(forLocalAPKAt: link, package: "com.example.app", version: "42") === first
        }
        XCTAssertTrue(
            store.icon(forLocalAPKAt: link, package: "com.example.app", version: "42") === first,
            "the same APK through a symlink must share one memoized icon"
        )
    }

    func testDeviceFailuresAreMemoizedPerSerial() async throws {
        let stub = try makeStubAdb()
        let store = AppIconStore(
            adbClient: stub.client,
            cacheDirectory: try temporaryDirectory().appendingPathComponent("cache", isDirectory: true),
            locateTool: { Self.fakeTool }
        )

        _ = store.icon(for: "com.example.app", version: "42", serial: "emulator-5554")
        try await waitUntil("the first serial's load") { self.calls(stub.callsURL).count == 1 }
        try await Task.sleep(for: .milliseconds(150))

        _ = store.icon(for: "com.example.app", version: "42", serial: "emulator-5554")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(
            calls(stub.callsURL).count,
            1,
            "a failed serial must not be retried on every row render"
        )

        _ = store.icon(for: "com.example.app", version: "42", serial: "emulator-5556")
        try await waitUntil("the second serial's load") { self.calls(stub.callsURL).count == 2 }
    }

    func testClearingDeviceFailuresAllowsARetry() async throws {
        let stub = try makeStubAdb()
        let store = AppIconStore(
            adbClient: stub.client,
            cacheDirectory: try temporaryDirectory().appendingPathComponent("cache", isDirectory: true),
            locateTool: { Self.fakeTool }
        )

        _ = store.icon(for: "com.example.app", version: "42", serial: "emulator-5554")
        try await waitUntil("the first load") { self.calls(stub.callsURL).count == 1 }
        try await Task.sleep(for: .milliseconds(150))

        store.clearDeviceFailures(keepingSerial: "emulator-5554")

        _ = store.icon(for: "com.example.app", version: "42", serial: "emulator-5554")
        try await waitUntil("the retry after clearing") { self.calls(stub.callsURL).count == 2 }
    }

    /// The synchronous disk-cache hit path sniffs the file too: a poisoned
    /// `.png` (a pre-fix build cached a non-raster under the name) is dropped
    /// instead of served, and the load falls through to extraction.
    func testPoisonedDiskCacheFileIsDroppedBeforeServing() async throws {
        let cache = try temporaryDirectory().appendingPathComponent("cache", isDirectory: true)
        AppIconStore.markCacheCurrent(in: cache)
        let file = ApkIconExtractor.cacheFileURL(
            forPackage: "com.example.app",
            version: "42",
            in: cache
        )
        try Data("<adaptive-icon/>".utf8).write(to: file)
        let store = AppIconStore(adbClient: nil, cacheDirectory: cache)

        let icon = store.icon(for: "com.example.app", version: "42", serial: "emulator-5554")

        XCTAssertNil(icon)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: file.path),
            "a non-raster cache file must be dropped, not served"
        )
    }

    /// A sniff-passing but undecodable file must be dropped too: the sniff
    /// alone cannot prove the bytes are a usable image, and `NSImage(data:)`
    /// accepts a truncated PNG that ImageIO cannot draw a frame from.
    func testUndecodableDiskCacheFileIsDroppedBeforeServing() async throws {
        let cache = try temporaryDirectory().appendingPathComponent("cache", isDirectory: true)
        AppIconStore.markCacheCurrent(in: cache)
        let file = ApkIconExtractor.cacheFileURL(
            forPackage: "com.example.app",
            version: "42",
            in: cache
        )
        try pngPayload.prefix(40).write(to: file)
        let store = AppIconStore(adbClient: nil, cacheDirectory: cache)

        let icon = store.icon(for: "com.example.app", version: "42", serial: "emulator-5554")

        XCTAssertNil(icon)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: file.path),
            "an undecodable cache file must be dropped, not served"
        )
    }

    /// A device switch keeps memory bounded: the previous serial's memoized
    /// icons are dropped, the current serial's survive (they are what the
    /// Apps list is rendering).
    func testDeviceSwitchDropsThePreviousSerialsMemoAndKeepsTheCurrent() async throws {
        let cache = try temporaryDirectory().appendingPathComponent("cache", isDirectory: true)
        try writeCachedIcon(package: "com.example.one", version: "1", in: cache)
        try writeCachedIcon(package: "com.example.two", version: "1", in: cache)
        let store = AppIconStore(adbClient: nil, cacheDirectory: cache)

        let previous = try XCTUnwrap(
            store.icon(for: "com.example.one", version: "1", serial: "emulator-5554")
        )
        let current = try XCTUnwrap(
            store.icon(for: "com.example.two", version: "1", serial: "emulator-5556")
        )
        try await waitUntil("both deferred memo writes") {
            store.icon(for: "com.example.one", version: "1", serial: "emulator-5554") === previous
                && store.icon(for: "com.example.two", version: "1", serial: "emulator-5556") === current
        }

        store.clearDeviceFailures(keepingSerial: "emulator-5556")

        XCTAssertTrue(
            store.icon(for: "com.example.two", version: "1", serial: "emulator-5556") === current,
            "the current serial's memo must survive the switch"
        )
        XCTAssertFalse(
            store.icon(for: "com.example.one", version: "1", serial: "emulator-5554") === previous,
            "the previous serial's memo must be dropped"
        )
    }

    /// Local-APK entries are path-keyed, not device-keyed: they belong to the
    /// install popover, not to a device, so a device switch must not evict
    /// one the popover may still be rendering.
    func testDeviceSwitchKeepsTheLocalAPKMemo() async throws {
        let directory = try temporaryDirectory()
        let cache = directory.appendingPathComponent("cache", isDirectory: true)
        try writeCachedIcon(package: "com.example.app", version: "42", in: cache)
        let apk = directory.appendingPathComponent("app.apk")
        try Data("apk".utf8).write(to: apk)
        let store = AppIconStore(adbClient: nil, cacheDirectory: cache)

        let first = try XCTUnwrap(
            store.icon(forLocalAPKAt: apk, package: "com.example.app", version: "42")
        )
        try await waitUntil("the deferred memo write") {
            store.icon(forLocalAPKAt: apk, package: "com.example.app", version: "42") === first
        }

        store.clearDeviceFailures(keepingSerial: "emulator-5556")

        XCTAssertTrue(
            store.icon(forLocalAPKAt: apk, package: "com.example.app", version: "42") === first,
            "the local-APK memo must survive a device switch"
        )
    }

    // MARK: - Bounded loads (F6)

    /// Without aapt2 nothing can be extracted, so nothing may be pulled: the
    /// old store pulled every visible row's whole APK before finding out.
    func testNothingIsPulledWithoutAapt2() async throws {
        let stub = try makeStubAdb()
        let store = AppIconStore(
            adbClient: stub.client,
            cacheDirectory: try temporaryDirectory().appendingPathComponent("cache", isDirectory: true),
            locateTool: { nil }
        )

        _ = store.icon(for: "com.example.app", version: "42", serial: "emulator-5554")
        _ = store.icon(for: "com.example.app", version: "42", serial: "emulator-5554")
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertTrue(calls(stub.callsURL).isEmpty, "no adb call without aapt2: \(calls(stub.callsURL))")
        XCTAssertEqual(store.deviceLoadCount.running, 0)
    }

    func testAtMostTwoPullsRunAtOnce() async throws {
        let stub = try makeSlowPullAdb(seconds: 2)
        let store = AppIconStore(
            adbClient: stub.client,
            cacheDirectory: try temporaryDirectory().appendingPathComponent("cache", isDirectory: true),
            locateTool: { Self.fakeTool }
        )

        for index in 0..<6 {
            _ = store.icon(for: "com.example.app\(index)", version: "1", serial: "emulator-5554")
        }
        try await waitUntil("two pulls") { self.pullStarts(stub) == 2 }
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(pullStarts(stub), 2, "every visible row pulled its APK at once")
        XCTAssertEqual(store.deviceLoadCount.running, 2)
        XCTAssertEqual(store.deviceLoadCount.pending, 4)
    }

    func testTheNewestRequestsLoadFirstAndTheQueueIsBounded() async throws {
        let stub = try makeSlowPullAdb(seconds: 2)
        let store = AppIconStore(
            adbClient: stub.client,
            cacheDirectory: try temporaryDirectory().appendingPathComponent("cache", isDirectory: true),
            locateTool: { Self.fakeTool }
        )

        let count = AppIconStore.maxConcurrentDeviceLoads + AppIconStore.maxPendingDeviceLoads + 10
        for index in 0..<count {
            _ = store.icon(for: "com.example.app\(index)", version: "1", serial: "emulator-5554")
        }

        XCTAssertEqual(store.deviceLoadCount.running, AppIconStore.maxConcurrentDeviceLoads)
        XCTAssertEqual(store.deviceLoadCount.pending, AppIconStore.maxPendingDeviceLoads)
    }

    func testReleasingTheStoreCancelsItsPulls() async throws {
        let stub = try makeSlowPullAdb(seconds: 1.5)
        var store: AppIconStore? = AppIconStore(
            adbClient: stub.client,
            cacheDirectory: try temporaryDirectory().appendingPathComponent("cache", isDirectory: true),
            locateTool: { Self.fakeTool }
        )
        let released = WeakStore(store)

        _ = store?.icon(for: "com.example.app", version: "42", serial: "emulator-5554")
        try await waitUntil("the pull") { self.pullStarts(stub) == 1 }

        store = nil
        XCTAssertNil(released.store, "a running load must not keep the store alive")
        try await Task.sleep(for: .milliseconds(2000))

        XCTAssertEqual(pullFinishes(stub), 0, "the Apps tab closing must stop its pulls")
    }

    func testDeviceSwitchCancelsThePreviousDevicesPulls() async throws {
        let stub = try makeSlowPullAdb(seconds: 1.5)
        let store = AppIconStore(
            adbClient: stub.client,
            cacheDirectory: try temporaryDirectory().appendingPathComponent("cache", isDirectory: true),
            locateTool: { Self.fakeTool }
        )

        _ = store.icon(for: "com.example.app", version: "42", serial: "emulator-5554")
        try await waitUntil("the pull") { self.pullStarts(stub) == 1 }

        store.clearDeviceFailures(keepingSerial: "emulator-5556")
        XCTAssertEqual(store.deviceLoadCount.running, 0)
        try await Task.sleep(for: .milliseconds(2000))

        XCTAssertEqual(pullFinishes(stub), 0)
    }

    // MARK: - Cache version

    /// Older builds cached the background layer of adaptive icons alone;
    /// the cache is emptied once, then kept.
    func testAnOlderCacheIsClearedOnce() throws {
        let cache = try temporaryDirectory().appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let old = ApkIconExtractor.cacheFileURL(forPackage: "com.example.old", version: "1", in: cache)
        try pngPayload.write(to: old)

        _ = AppIconStore(adbClient: nil, cacheDirectory: cache)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))

        let current = ApkIconExtractor.cacheFileURL(forPackage: "com.example.new", version: "1", in: cache)
        try pngPayload.write(to: current)
        let store = AppIconStore(adbClient: nil, cacheDirectory: cache)

        XCTAssertTrue(FileManager.default.fileExists(atPath: current.path))
        XCTAssertNotNil(store.icon(for: "com.example.new", version: "1", serial: "emulator-5554"))
    }

    // MARK: - Harness

    private final class WeakStore {
        weak var store: AppIconStore?
        init(_ store: AppIconStore?) { self.store = store }
    }

    /// Any executable stands in for aapt2: extraction then fails, which is
    /// all the load tests need.
    private static let fakeTool = URL(fileURLWithPath: "/usr/bin/true")

    private struct StubAdb {
        let client: AdbClient
        let callsURL: URL
    }

    /// A fake `adb` whose `pm path` answers and whose `pull` takes `seconds`,
    /// logging `start`/`done` to `callsURL` around it.
    private func makeSlowPullAdb(seconds: Double) throws -> StubAdb {
        let directory = try temporaryDirectory()
        let logURL = directory.appendingPathComponent("pulls.log")
        let adbURL = directory.appendingPathComponent("adb")
        let script = """
        #!/bin/sh
        case "$*" in
          *"pm path"*)
            printf 'package:/data/app/example/base.apk\\n'
            ;;
          *" pull "*)
            printf 'start\\n' >> "\(logURL.path)"
            sleep \(seconds)
            printf 'done\\n' >> "\(logURL.path)"
            ;;
        esac
        exit 0
        """
        try Data(script.utf8).write(to: adbURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: adbURL.path
        )
        return StubAdb(client: AdbClient(adbURL: adbURL), callsURL: logURL)
    }

    private func pullStarts(_ stub: StubAdb) -> Int {
        calls(stub.callsURL).filter { $0 == "start" }.count
    }

    private func pullFinishes(_ stub: StubAdb) -> Int {
        calls(stub.callsURL).filter { $0 == "done" }.count
    }

    /// A fake `adb` that logs its argv and fails every command, like an
    /// offline device.
    private func makeStubAdb() throws -> StubAdb {
        let directory = try temporaryDirectory()
        let logURL = directory.appendingPathComponent("calls.log")
        let adbURL = directory.appendingPathComponent("adb")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$*" >> "\(logURL.path)"
        exit 1
        """
        try Data(script.utf8).write(to: adbURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: adbURL.path
        )
        return StubAdb(client: AdbClient(adbURL: adbURL), callsURL: logURL)
    }

    /// An icon cached by the current build (the cache-version marker too).
    private func writeCachedIcon(package: String, version: String, in cache: URL) throws {
        AppIconStore.markCacheCurrent(in: cache)
        try pngPayload.write(
            to: ApkIconExtractor.cacheFileURL(forPackage: package, version: version, in: cache)
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppIconStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func calls(_ logURL: URL) -> [String] {
        ((try? String(contentsOf: logURL, encoding: .utf8)) ?? "")
            .split(separator: "\n")
            .map(String.init)
    }

    private func waitUntil(
        _ what: String,
        timeout: TimeInterval = 5,
        until condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("\(what) did not happen within \(timeout) s")
    }
}
