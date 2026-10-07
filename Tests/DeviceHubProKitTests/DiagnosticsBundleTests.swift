import XCTest
@testable import DeviceHubProKit

final class DiagnosticsBundleTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiagnosticsBundleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
    }

    // MARK: - Zipping

    func testArchiveStoresTheStagedFilesAndTheirContentsAtTheArchiveRoot() async throws {
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("09-17 10:00:00.000  1234  1234 I Device Hub Pro: hello\n".utf8)
            .write(to: staging.appendingPathComponent("logcat.txt"))
        try Data("{\"serial\":\"emulator-5554\"}".utf8)
            .write(to: staging.appendingPathComponent("device.json"))

        let destination = root.appendingPathComponent("out", isDirectory: true)
        let zipURL = try await DiagnosticsBundle.archive(
            directory: staging,
            named: "probe-diagnostics.zip",
            into: destination
        )

        XCTAssertEqual(zipURL, destination.appendingPathComponent("probe-diagnostics.zip"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: zipURL.path))
        XCTAssertEqual(try zipEntryNames(at: zipURL), ["device.json", "logcat.txt"])
        XCTAssertEqual(
            try unzip("logcat.txt", from: zipURL),
            "09-17 10:00:00.000  1234  1234 I Device Hub Pro: hello\n"
        )
        XCTAssertEqual(try unzip("device.json", from: zipURL), "{\"serial\":\"emulator-5554\"}")
    }

    func testArchiveRejectsAnEmptyStagingDirectory() async throws {
        let staging = root.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        do {
            _ = try await DiagnosticsBundle.archive(directory: staging, named: "empty.zip", into: root)
            XCTFail("expected an empty staging directory to be rejected")
        } catch {
            XCTAssertEqual(error as? DiagnosticsBundleError, .noFilesToArchive)
        }
    }

    // MARK: - Bundle assembly

    func testCollectWritesTheDeviceDumpsIntoATimestampedZip() async throws {
        let stub = try makeStubAdb()
        let destination = root.appendingPathComponent("out", isDirectory: true)

        let result = try await DiagnosticsBundle.collect(
            serial: "emulator-5554",
            adb: AdbClient(adbURL: stub.adbURL),
            into: destination
        )
        let zipURL = result.url

        XCTAssertFalse(result.usedHostClockFallback)
        XCTAssertEqual(
            zipURL.deletingLastPathComponent().standardizedFileURL,
            destination.standardizedFileURL
        )
        let name = zipURL.lastPathComponent
        XCTAssertTrue(name.hasPrefix("emulator-5554-diagnostics-"), name)
        XCTAssertTrue(name.hasSuffix(".zip"), name)

        XCTAssertEqual(
            try zipEntryNames(at: zipURL),
            ["device.json", "dumpsys-battery.txt", "dumpsys-meminfo.txt", "getprop.txt", "logcat.txt"]
        )

        XCTAssertEqual(try unzip("logcat.txt", from: zipURL), StubOutput.logcat)
        XCTAssertEqual(try unzip("dumpsys-battery.txt", from: zipURL), StubOutput.battery)
        XCTAssertEqual(try unzip("dumpsys-meminfo.txt", from: zipURL), StubOutput.meminfo)
        XCTAssertEqual(try unzip("getprop.txt", from: zipURL), """
        ro.build.version.release=14
        ro.build.version.sdk=34
        ro.product.cpu.abi=arm64-v8a
        ro.product.manufacturer=StubCo
        ro.product.model=Stub Phone

        """)

        let deviceJSON = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(try unzip("device.json", from: zipURL).utf8)
            ) as? [String: Any]
        )
        XCTAssertEqual(deviceJSON["serial"] as? String, "emulator-5554")
        XCTAssertEqual(deviceJSON["model"] as? String, "Stub Phone")
        XCTAssertEqual(deviceJSON["manufacturer"] as? String, "StubCo")
        XCTAssertEqual(deviceJSON["androidVersion"] as? String, "14")
        XCTAssertEqual(deviceJSON["apiLevel"] as? String, "34")
        XCTAssertEqual(deviceJSON["abi"] as? String, "arm64-v8a")
        XCTAssertEqual(deviceJSON["isEmulator"] as? Bool, true)

        // The bundle reads exactly the pinned adb commands: the logcat cutoff
        // is the device clock minus five minutes (logcat's time argument is
        // epoch seconds or `MM-DD hh:mm:ss.mmm`, not `5m`).
        XCTAssertEqual(try stub.recordedCalls(), [
            "-s emulator-5554 shell date +%s",
            "-s emulator-5554 logcat -d -v threadtime -t 1599999700.000",
            "-s emulator-5554 shell dumpsys battery",
            "-s emulator-5554 shell dumpsys meminfo",
            "-s emulator-5554 shell getprop",
        ])
    }

    func testCollectFallsBackToTheInjectedHostClockWhenTheDeviceCannotAnswer() async throws {
        let stub = try makeStubAdb(deviceEpoch: nil)
        let destination = root.appendingPathComponent("out", isDirectory: true)
        // 1_600_000_000 − 300 = 1_599_999_700, the same cutoff the device
        // clock test pins, so the logcat invocation can be compared directly.
        let injected = Date(timeIntervalSince1970: 1_600_000_000)

        let result = try await DiagnosticsBundle.collect(
            serial: "emulator-5554",
            adb: AdbClient(adbURL: stub.adbURL),
            into: destination,
            fallbackNow: { injected }
        )

        // The failed `date` read must be reported, not hidden.
        XCTAssertTrue(result.usedHostClockFallback)
        XCTAssertEqual(
            result.url.deletingLastPathComponent().standardizedFileURL,
            destination.standardizedFileURL
        )
        XCTAssertEqual(try stub.recordedCalls(), [
            "-s emulator-5554 shell date +%s",
            "-s emulator-5554 logcat -d -v threadtime -t 1599999700.000",
            "-s emulator-5554 shell dumpsys battery",
            "-s emulator-5554 shell dumpsys meminfo",
            "-s emulator-5554 shell getprop",
        ])
        XCTAssertEqual(try unzip("logcat.txt", from: result.url), StubOutput.logcat)
    }

    /// One invalid UTF-8 byte (a message cut mid-character) used to make the
    /// strict decode return nil, which archived an empty `logcat.txt`. The
    /// device's bytes must reach the archive unchanged.
    func testLogcatWithInvalidUTF8IsArchivedByteForByte() async throws {
        let stub = try makeStubAdb(overrides: [
            #"*"logcat -d -v threadtime -t 1599999700.000") printf '09-17 10:00:00.000  1 1 I T: \303\n09-17 10:00:01.000  1 1 I T: \346\227\245\n' ;;"#,
        ])

        let result = try await DiagnosticsBundle.collect(
            serial: "emulator-5554",
            adb: AdbClient(adbURL: stub.adbURL),
            into: root.appendingPathComponent("out", isDirectory: true)
        )

        var expected = Data("09-17 10:00:00.000  1 1 I T: ".utf8)
        expected.append(0xC3)
        expected.append(contentsOf: Array("\n09-17 10:00:01.000  1 1 I T: 日\n".utf8))
        XCTAssertEqual(try unzipData("logcat.txt", from: result.url), expected)
        XCTAssertEqual(result.failedSections, [])
    }

    /// A wedged section (here `dumpsys meminfo` never returns) is bounded by
    /// the section timeout and archived as `<name>.error.txt`; everything
    /// else is still collected instead of the whole bundle being lost.
    func testAHangingSectionTimesOutAndTheRestIsStillArchived() async throws {
        let stub = try makeStubAdb(overrides: [
            #"*"shell dumpsys meminfo") exec sleep 30 ;;"#,
        ])
        let started = ContinuousClock.now

        let result = try await DiagnosticsBundle.collect(
            serial: "emulator-5554",
            adb: AdbClient(adbURL: stub.adbURL),
            into: root.appendingPathComponent("out", isDirectory: true),
            sectionTimeout: .milliseconds(500)
        )

        XCTAssertLessThan(ContinuousClock.now - started, .seconds(10))
        XCTAssertEqual(result.failedSections, ["dumpsys-meminfo"])
        XCTAssertEqual(
            try zipEntryNames(at: result.url),
            ["device.json", "dumpsys-battery.txt", "dumpsys-meminfo.error.txt", "getprop.txt", "logcat.txt"]
        )
        XCTAssertEqual(try unzip("logcat.txt", from: result.url), StubOutput.logcat)
        XCTAssertEqual(try unzip("dumpsys-battery.txt", from: result.url), StubOutput.battery)
        let report = try unzip("dumpsys-meminfo.error.txt", from: result.url)
        XCTAssertTrue(report.contains("shell dumpsys meminfo"), report)
        XCTAssertTrue(report.contains("did not finish"), report)
    }

    /// Android 6 rejects logcat's epoch time form; the bundle falls back to a
    /// bounded line count instead of failing.
    func testRejectedEpochWindowFallsBackToALineCount() async throws {
        let stub = try makeStubAdb(overrides: [
            #"*"logcat -d -v threadtime -t 1599999700.000") printf 'logcat: invalid time\n' >&2; exit 1 ;;"#,
            #"*"logcat -d -v threadtime -t 10000") printf '09-17 09:00:00.000  1 1 I T: older\n' ;;"#,
        ])

        let result = try await DiagnosticsBundle.collect(
            serial: "emulator-5554",
            adb: AdbClient(adbURL: stub.adbURL),
            into: root.appendingPathComponent("out", isDirectory: true)
        )

        XCTAssertTrue(result.usedLogcatLineFallback)
        XCTAssertEqual(result.failedSections, [])
        XCTAssertEqual(try unzip("logcat.txt", from: result.url), "09-17 09:00:00.000  1 1 I T: older\n")
        XCTAssertTrue(try stub.recordedCalls().contains(
            "-s emulator-5554 logcat -d -v threadtime -t 10000"
        ))
    }

    /// A device that answers nothing yields an error, not a bundle of error
    /// files reported as "saved".
    func testAnUnreachableDeviceThrowsInsteadOfArchivingOnlyErrors() async throws {
        let stub = try makeStubAdb(
            deviceEpoch: nil,
            overrides: [#"*) printf 'error: device offline\n' >&2; exit 1 ;;"#]
        )
        let destination = root.appendingPathComponent("out", isDirectory: true)

        do {
            _ = try await DiagnosticsBundle.collect(
                serial: "emulator-5554",
                adb: AdbClient(adbURL: stub.adbURL),
                into: destination
            )
            XCTFail("expected deviceUnreachable")
        } catch let error as DiagnosticsBundleError {
            guard case .deviceUnreachable(let reason) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(reason.contains("logcat"), reason)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testSuggestedFileNameCarriesTheSerialAndATimestamp() {
        let date = Date(timeIntervalSince1970: 1_600_000_000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"

        XCTAssertEqual(
            DiagnosticsBundle.suggestedFileName(serial: "emulator-5554", date: date),
            "emulator-5554-diagnostics-\(formatter.string(from: date)).zip"
        )
        XCTAssertEqual(
            DiagnosticsBundle.suggestedFileName(serial: "R58/M:123", date: date),
            "R58-M-123-diagnostics-\(formatter.string(from: date)).zip"
        )
    }

    // MARK: - Stub adb

    private enum StubOutput {
        static let logcat = "09-17 10:00:00.000  1234  1234 I Device Hub Pro: hello\n"
        static let battery = "Current Battery Service state:\n  level: 42\n"
        static let meminfo = "Applications Memory Usage (in Kilobytes):\nUptime: 1000\n"
    }

    private struct StubAdb {
        let adbURL: URL
        let traceURL: URL

        func recordedCalls() throws -> [String] {
            try String(contentsOf: traceURL, encoding: .utf8)
                .split(separator: "\n")
                .map(String.init)
        }
    }

    /// `overrides` are extra `case` arms tried before the defaults (the first
    /// matching arm wins), e.g. a section that hangs or fails.
    private func makeStubAdb(
        deviceEpoch: Int? = 1_600_000_000,
        overrides: [String] = []
    ) throws -> StubAdb {
        let directory = root.appendingPathComponent("stub", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let traceURL = directory.appendingPathComponent("calls.log")
        let adbURL = directory.appendingPathComponent("adb")

        let dateCase = deviceEpoch.map { #"*"shell date +%s") printf '\#($0)\n' ;;"# }
            ?? #"*"shell date +%s") printf 'date: not found\n' >&2; exit 1 ;;"#

        let script = """
        #!/bin/sh
        printf '%s\\n' "$*" >> "\(traceURL.path)"
        case "$*" in
          \(overrides.joined(separator: "\n  "))
          \(dateCase)
          *"logcat -d -v threadtime -t 1599999700.000") printf '09-17 10:00:00.000  1234  1234 I Device Hub Pro: hello\\n' ;;
          *"shell dumpsys battery") printf 'Current Battery Service state:\\n  level: 42\\n' ;;
          *"shell dumpsys meminfo") printf 'Applications Memory Usage (in Kilobytes):\\nUptime: 1000\\n' ;;
          *"shell getprop") printf '[ro.build.version.release]: [14]\\n[ro.build.version.sdk]: [34]\\n[ro.product.cpu.abi]: [arm64-v8a]\\n[ro.product.manufacturer]: [StubCo]\\n[ro.product.model]: [Stub Phone]\\n' ;;
          *) printf 'unexpected: %s\\n' "$*" >&2; exit 1 ;;
        esac
        """
        try Data(script.utf8).write(to: adbURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: adbURL.path
        )
        return StubAdb(adbURL: adbURL, traceURL: traceURL)
    }

    // MARK: - unzip helpers (independent of the code under test)

    private func zipEntryNames(at zipURL: URL) throws -> [String] {
        let result = try run("/usr/bin/unzip", ["-Z1", zipURL.path])
        XCTAssertEqual(result.status, 0, result.error)
        return result.output
            .split(separator: "\n")
            .map(String.init)
    }

    private func unzip(_ entry: String, from zipURL: URL) throws -> String {
        let result = try run("/usr/bin/unzip", ["-p", zipURL.path, entry])
        XCTAssertEqual(result.status, 0, result.error)
        return result.output
    }

    /// The entry's exact bytes (the String helper decodes lossily).
    private func unzipData(_ entry: String, from zipURL: URL) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", zipURL.path, entry]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return output
    }

    private func run(_ executable: String, _ arguments: [String]) throws -> (status: Int32, output: String, error: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let error = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return (
            process.terminationStatus,
            String(decoding: output, as: UTF8.self),
            String(decoding: error, as: UTF8.self)
        )
    }
}
