import XCTest
@testable import DeviceHubProKit

/// The simctl parsers fed byte-exact captures instead of invented text.
///
/// Every fixture under `Fixtures/ios27-simulator/simctl-core/` and
/// `…/controls/` is the raw stdout or stderr of the exact command production
/// runs, except `device.plist.created` and `device.plist.booted`: byte
/// copies of the fixture device's `<set>/<UDID>/device.plist` file (what
/// `SimulatorWatcher` watches), not command output. Unless a test says
/// otherwise, it was captured on 2026-09-25 with
/// Xcode 27.0 (27A266a) and CoreSimulator 1171.7, running the real simctl
/// binary (not the `xcrun` wrapper) against `DeviceHubPro-A-fixtures`, an
/// iPhone 17 Pro on iOS 27.0 (24A434), UDID 95D9676B-3317-4BA5-8CF6-3CDD0488CACA,
/// in a private device set (`simctl --set <scratch>/simset`). The simulator
/// inherited the Mac's `tr_TR` locale and `Europe/Istanbul` time zone. Files
/// the tests call "spike" come from the same day's simctl spike instead: a
/// throwaway iPhone 18 Pro (iOS 27.0, default set, UDID
/// 84B08C4E-3502-4517-A6F3-49057EC6DA9D), captured through the `xcrun`
/// wrapper (which execs the same binary).
///
/// Redaction: the macOS user name inside paths (`dataPath`, `logPath`, the
/// private set's scratch folder, container URLs) is replaced with the
/// same-length placeholder `aqauser001`, and the scratch folder's
/// machine- and session-specific segment (`<tool>-<uid>/<project>/<session
/// UUID>`, before `/fixtures00/trackA`) with the same-length
/// `aqa-tmp-01/aqa-project-placeholder-01/aqa-session-placeholder-000000000000`
/// (slashes stay escaped where JSON escapes them); nothing else was
/// changed. Exit codes are spelled out beside each stderr fixture (recorded
/// at capture time).
/// `.stdout`/`.stderr` names keep the streams apart where production reads
/// them separately.
final class SimctlFixtureTests: XCTestCase {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/ios27-simulator", isDirectory: true)

    static func url(_ folder: String, _ name: String) -> URL {
        root.appendingPathComponent(folder).appendingPathComponent(name)
    }

    static func data(_ folder: String, _ name: String) throws -> Data {
        try Data(contentsOf: url(folder, name))
    }

    static func text(_ folder: String, _ name: String) throws -> String {
        try XCTUnwrap(String(data: data(folder, name), encoding: .utf8), "\(name) is not UTF-8")
    }

    static let udid = "95D9676B-3317-4BA5-8CF6-3CDD0488CACA"

    // MARK: - list -j

    /// `simctl --set <set> list -j devices` right after `create`: one iOS
    /// 27.0 device, never booted, so `lastUsedAt` and `logPathSize` are
    /// absent. The other runtimes list no devices (a private set starts empty).
    func testDeviceListOfANewDevice() throws {
        let devices = try SimctlParsing.devices(
            fromListJSON: try Self.data("simctl-core", "simctl-list-j-devices.shutdown.json")
        )
        XCTAssertEqual(devices.count, 1)
        let device = try XCTUnwrap(devices.first)
        XCTAssertEqual(device.udid, Self.udid)
        XCTAssertEqual(device.name, "DeviceHubPro-A-fixtures")
        XCTAssertEqual(device.state, .shutdown)
        XCTAssertFalse(device.isBooted)
        XCTAssertTrue(device.isAvailable)
        XCTAssertEqual(device.deviceTypeIdentifier, "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro")
        XCTAssertEqual(device.runtimeIdentifier, "com.apple.CoreSimulator.SimRuntime.iOS-27-0")
        XCTAssertEqual(device.dataPathSize, 18_337_792)
        XCTAssertNil(device.logPathSize)
        XCTAssertNil(device.lastUsedAt)
        XCTAssertEqual(
            device.logPath,
            "/Users/aqauser001/Library/Logs/CoreSimulator/95D9676B-3317-4BA5-8CF6-3CDD0488CACA",
            "a private set still logs under the user's Library (simctl delete leaves it behind)"
        )
        XCTAssertTrue(device.dataPath?.hasSuffix("/simset/95D9676B-3317-4BA5-8CF6-3CDD0488CACA/data") == true)
    }

    /// The same listing once `bootstatus -b` reported Finished: `Booted`,
    /// plus the keys a used device gains.
    func testDeviceListOfABootedDevice() throws {
        let devices = try SimctlParsing.devices(
            fromListJSON: try Self.data("simctl-core", "simctl-list-j-devices.booted.json")
        )
        let device = try XCTUnwrap(devices.first)
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(device.state, .booted)
        XCTAssertTrue(device.isBooted)
        XCTAssertEqual(device.logPathSize, 159_744)
        XCTAssertEqual(device.dataPathSize, 701_755_392)
        XCTAssertEqual(device.lastUsedAt, ISO8601DateFormatter().date(from: "2026-09-25T12:04:47Z"))
    }

    /// `list -j devices` of an empty private set: every installed runtime
    /// appears as a key with an empty array.
    func testDeviceListOfAnEmptySet() throws {
        let devices = try SimctlParsing.devices(
            fromListJSON: try Self.data("simctl-core", "simctl-list-j-devices.empty-set.json")
        )
        XCTAssertEqual(devices, [])
    }

    /// `list -j runtimes`: iOS 26.5 (a disk-image runtime) and iOS 27.0 (a
    /// cryptex under `/private/var/run/…`), tvOS 26.5 and 27.0, in the
    /// listing's order, with their supported device types.
    func testRuntimeList() throws {
        let runtimes = try SimctlParsing.runtimes(
            fromListJSON: try Self.data("simctl-core", "simctl-list-j-runtimes.json")
        )
        XCTAssertEqual(runtimes.map(\.identifier), [
            "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
            "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
            "com.apple.CoreSimulator.SimRuntime.tvOS-26-5",
            "com.apple.CoreSimulator.SimRuntime.tvOS-27-0",
        ])
        let ios27 = runtimes[1]
        XCTAssertEqual(ios27.name, "iOS 27.0")
        XCTAssertEqual(ios27.version, "27.0")
        XCTAssertEqual(ios27.buildVersion, "24A434")
        XCTAssertEqual(ios27.platform, "iOS")
        XCTAssertTrue(ios27.isAvailable)
        XCTAssertFalse(ios27.isInternal)
        XCTAssertEqual(ios27.supportedDeviceTypeIdentifiers.count, 62)
        XCTAssertTrue(ios27.supportedDeviceTypeIdentifiers.contains("com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"))
        XCTAssertTrue(ios27.bundlePath?.hasPrefix("/private/var/run/com.apple.security.cryptexd/") == true)
        XCTAssertEqual(runtimes[0].supportedDeviceTypeIdentifiers.count, 65)
        XCTAssertEqual(runtimes[3].buildVersion, "24J360")
    }

    /// `list -j devicetypes`: all 129 types Xcode 27.0 ships, every one with
    /// the same nine keys.
    func testDeviceTypeList() throws {
        let types = try SimctlParsing.deviceTypes(
            fromListJSON: try Self.data("simctl-core", "simctl-list-j-devicetypes.json")
        )
        XCTAssertEqual(types.count, 129)
        let pro = try XCTUnwrap(types.first { $0.identifier == "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro" })
        XCTAssertEqual(pro.name, "iPhone 17 Pro")
        XCTAssertEqual(pro.productFamily, "iPhone")
        XCTAssertEqual(pro.modelIdentifier, "iPhone18,1")
        XCTAssertEqual(types.first?.identifier, "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro")
        XCTAssertEqual(types.first?.minRuntimeVersion, "27.0.0")
        XCTAssertEqual(Set(types.compactMap(\.productFamily)).isSuperset(of: ["iPhone", "iPad"]), true)
    }

    func testDeviceListRejectsNonJSON() {
        XCTAssertThrowsError(try SimctlParsing.devices(fromListJSON: Data("Invalid device: x\n".utf8)))
    }

    // MARK: - create, device.plist

    func testCreatePrintsTheNewUDID() throws {
        XCTAssertEqual(
            SimctlParsing.createdUDID(from: try Self.text("simctl-core", "simctl-create.stdout.txt")),
            Self.udid
        )
        XCTAssertNil(SimctlParsing.createdUDID(from: "booted\n"))
    }

    /// `<set>/<UDID>/device.plist` after `create` (state 1) and after the
    /// boot finished (state 3, plus `lastUsedAt`): the only two states it
    /// ever persists. Both are file copies taken from the throwaway fixture
    /// device, byte-exact (they hold no user name or path).
    func testDevicePlistState() throws {
        XCTAssertEqual(SimctlParsing.devicePlistState(try Self.data("simctl-core", "device.plist.created")), .shutdown)
        XCTAssertEqual(SimctlParsing.devicePlistState(try Self.data("simctl-core", "device.plist.booted")), .booted)
        XCTAssertNil(SimctlParsing.devicePlistState(Data("not a plist".utf8)))
    }

    func testStateStrings() {
        XCTAssertEqual(SimulatorState(listValue: "Shutting Down"), .shuttingDown)
        XCTAssertEqual(SimulatorState(listValue: "Booting"), .booting)
        XCTAssertEqual(SimulatorState(listValue: "Creating"), .creating)
        XCTAssertEqual(SimulatorState(listValue: "Paused"), .other("Paused"))
        XCTAssertEqual(SimulatorState(plistValue: 4), .shuttingDown)
    }

    // MARK: - bootstatus

    /// `bootstatus <udid> -b` over the first boot (24.2 s): 20 data-migration
    /// updates (the LaunchServices migrator alone runs 15 s), then Finished
    /// with status 4294967295.
    func testBootStatusOfAColdFirstBoot() throws {
        let updates = SimctlParsing.bootStatuses(
            from: try Self.text("simctl-core", "simctl-bootstatus-b.cold-first-boot.stdout.txt")
        )
        XCTAssertEqual(updates.count, 21)
        XCTAssertEqual(updates.first?.timestamp, "2026-09-25 12:04:51 +0000")
        XCTAssertEqual(updates.first?.status, 2)
        XCTAssertEqual(updates.first?.phase, .waitingOnDataMigration)
        XCTAssertNil(updates.first?.reason, "Reason:(null) means no reason")
        XCTAssertEqual(updates[1].reason, "Preparing to migrate")
        XCTAssertEqual(updates.dropLast().filter { $0.phase == .waitingOnDataMigration }.count, 20)
        XCTAssertTrue(updates.dropLast().allSatisfy { !$0.isTerminal && !$0.isFinished })

        let last = try XCTUnwrap(updates.last)
        XCTAssertEqual(last.status, 4_294_967_295)
        XCTAssertTrue(last.isTerminal)
        XCTAssertEqual(last.phase, .finished)
        XCTAssertTrue(last.isFinished)
        XCTAssertEqual(last.elapsedSeconds, 24)
    }

    /// Spike: `bootstatus -b` after `simctl reboot` (iPhone 18 Pro): a short
    /// migration, then "Waiting on System App" (status 4) twice, then
    /// Finished — reported 3 s in, while the home screen only appeared at
    /// about 26 s (which is why "Ready" needs more than Finished).
    func testBootStatusAfterAReboot() throws {
        let updates = SimctlParsing.bootStatuses(
            from: try Self.text("simctl-core", "simctl-bootstatus-b.after-reboot.stdout.txt")
        )
        XCTAssertEqual(updates.map(\.phase), [
            .waitingOnDataMigration, .waitingOnSystemApp, .waitingOnSystemApp, .finished,
        ])
        XCTAssertEqual(updates.map(\.status), [2, 4, 4, 4_294_967_295])
        XCTAssertEqual(updates.map(\.elapsedSeconds), [1, 2, 2, 3])
    }

    /// Streamed line by line, the parser hands out each update once its
    /// block ends, and the final block on `finish()`.
    func testBootStatusParserStreamsBlocks() throws {
        let text = try Self.text("simctl-core", "simctl-bootstatus-b.after-reboot.stdout.txt")
        var parser = SimulatorBootStatusParser()
        var emittedAt: [Int] = []
        for (index, line) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            if !parser.consume(String(line)).isEmpty {
                emittedAt.append(index)
            }
        }
        XCTAssertEqual(emittedAt, [5, 8, 11, 14], "each update completes on its blank line")
        XCTAssertEqual(parser.finish(), [])
    }

    // MARK: - Apps

    /// `listapps <udid>` on a fresh iOS 27.0 device: 39 system apps in
    /// OpenStep plist format, scalars as unquoted strings.
    func testListApps() throws {
        let apps = try SimctlParsing.apps(fromListApps: try Self.text("simctl-core", "simctl-listapps.stdout.txt"))
        XCTAssertEqual(apps.count, 39)
        XCTAssertEqual(apps.map(\.bundleIdentifier), apps.map(\.bundleIdentifier).sorted())
        XCTAssertTrue(apps.allSatisfy { $0.applicationType == "System" && !$0.isUserApp })

        let bridge = try XCTUnwrap(apps.first { $0.bundleIdentifier == "com.apple.Bridge" })
        XCTAssertEqual(bridge.title, "Watch")
        XCTAssertEqual(bridge.executable, "Bridge")
        XCTAssertEqual(bridge.tags, ["watch-companion"])
        XCTAssertTrue(bridge.isFirstParty)
        XCTAssertFalse(bridge.isHidden)
        XCTAssertFalse(bridge.isRemovable)
        XCTAssertEqual(bridge.groupContainers.count, 6)

        let carPlay = try XCTUnwrap(apps.first { $0.bundleIdentifier == "com.apple.CarPlayApp" })
        XCTAssertNil(carPlay.dataContainer, "CarPlay has no data container")
        XCTAssertEqual(carPlay.version, "1", "an unquoted number is still a string in OpenStep format")
    }

    /// `appinfo <udid> com.apple.mobilesafari`.
    func testAppInfo() throws {
        let safari = try SimctlParsing.app(
            fromAppInfo: try Self.text("simctl-core", "simctl-appinfo-mobilesafari.stdout.txt")
        )
        XCTAssertEqual(safari.bundleIdentifier, "com.apple.mobilesafari")
        XCTAssertEqual(safari.displayName, "Safari")
        XCTAssertEqual(safari.bundleName, "MobileSafari")
        XCTAssertEqual(safari.shortVersion, "27.0")
        XCTAssertEqual(safari.version, "8625.1.29.10.29")
        XCTAssertTrue(safari.path?.hasSuffix("/Applications/MobileSafari.app") == true)
        XCTAssertEqual(safari.dataContainer?.isFileURL, true)
        XCTAssertEqual(
            safari.dataContainer?.lastPathComponent,
            "DEEC28D4-5835-4EBF-8A41-D5F388E542AC",
            "the same container get_app_container … data prints"
        )
        XCTAssertEqual(Set(safari.groupContainers.keys), [
            "group.com.apple.BrowserKit", "group.com.apple.sports", "group.com.apple.tipsnext",
        ])
    }

    /// `get_app_container <udid> com.apple.mobilesafari groups`: TSV, in the
    /// order simctl printed; the paths match `appinfo`'s GroupContainers.
    func testGroupContainers() throws {
        let groups = SimctlParsing.groupContainers(
            from: try Self.text("simctl-core", "simctl-get_app_container-groups.stdout.txt")
        )
        XCTAssertEqual(groups.map(\.identifier), [
            "group.com.apple.sports", "group.com.apple.tipsnext", "group.com.apple.BrowserKit",
        ])
        let safari = try SimctlParsing.app(
            fromAppInfo: try Self.text("simctl-core", "simctl-appinfo-mobilesafari.stdout.txt")
        )
        for group in groups {
            XCTAssertEqual(safari.groupContainers[group.identifier]?.path, group.path)
        }
    }

    /// `launch <udid> com.apple.mobilesafari` prints `<bundle>: <pid>`.
    func testLaunchedPID() throws {
        XCTAssertEqual(
            SimctlParsing.launchedPID(from: try Self.text("simctl-core", "simctl-launch-mobilesafari.stdout.txt")),
            76487
        )
        XCTAssertNil(SimctlParsing.launchedPID(from: ""))
    }

    // MARK: - ui

    /// `ui <udid> appearance|increase_contrast|content_size` without a value
    /// print one token and a newline. On a shut-down device `appearance`
    /// prints `unknown` and exits 0.
    func testUIReadings() throws {
        XCTAssertEqual(SimctlParsing.appearance(from: try Self.text("controls", "simctl-ui-appearance.light.stdout.txt")), .light)
        XCTAssertEqual(SimctlParsing.appearance(from: try Self.text("controls", "simctl-ui-appearance.dark.stdout.txt")), .dark)
        XCTAssertEqual(SimctlParsing.appearance(from: try Self.text("controls", "simctl-ui-appearance.shutdown.stdout.txt")), .unknown)
        XCTAssertEqual(
            SimctlParsing.increaseContrast(from: try Self.text("controls", "simctl-ui-increase_contrast.disabled.stdout.txt")),
            .disabled
        )
        XCTAssertEqual(
            SimctlParsing.increaseContrast(from: try Self.text("controls", "simctl-ui-increase_contrast.enabled.stdout.txt")),
            .enabled
        )
        XCTAssertEqual(
            SimctlParsing.contentSize(from: try Self.text("controls", "simctl-ui-content_size.large.stdout.txt")),
            .large
        )
        let axl = SimctlParsing.contentSize(
            from: try Self.text("controls", "simctl-ui-content_size.accessibility-extra-large.stdout.txt")
        )
        XCTAssertEqual(axl, .accessibilityExtraLarge)
        XCTAssertEqual(axl?.isAccessibilitySize, true)
        XCTAssertEqual(SimulatorContentSize.settable.count, 12)
        XCTAssertFalse(SimulatorContentSize.settable.contains(.unknown))
    }

    /// Invalid `ui` values: `appearance purple` exits 1 with its own
    /// message; `content_size bogus-size` and `increase_contrast maybe` exit
    /// **0** with `Invalid argument` on stderr, which must still read as a
    /// failure.
    func testUIInvalidValues() throws {
        let appearance = try XCTUnwrap(SimctlErrors.uiFailure(
            arguments: ["ui", Self.udid, "appearance", "purple"],
            exitCode: 1,
            standardError: try Self.text("controls", "simctl-ui-appearance-invalid.stderr.txt")
        ))
        XCTAssertEqual(appearance.message, "Unknown apperance: purple")
        XCTAssertNil(appearance.error)

        for name in ["simctl-ui-content_size-invalid.stderr.txt", "simctl-ui-increase_contrast-invalid.stderr.txt"] {
            let failure = try XCTUnwrap(SimctlErrors.uiFailure(
                arguments: ["ui", Self.udid, "content_size", "bogus-size"],
                exitCode: 0,
                standardError: try Self.text("controls", name)
            ), name)
            XCTAssertEqual(failure.kind, .invalidArgument, name)
            XCTAssertEqual(failure.exitCode, 0, name)
        }
        XCTAssertNil(SimctlErrors.uiFailure(arguments: [], exitCode: 0, standardError: ""))
    }

    // MARK: - status_bar

    /// `status_bar list` before any override: the header and rule only.
    func testStatusBarListWithoutOverrides() throws {
        let overrides = SimctlParsing.statusBarOverrides(
            from: try Self.text("controls", "simctl-status_bar-list.empty.stdout.txt")
        )
        XCTAssertTrue(overrides.isEmpty)
    }

    /// After `status_bar override --time 09:41 --dataNetwork 5g --wifiMode
    /// active --wifiBars 3 --cellularMode active --cellularBars 4
    /// --operatorName Device Hub Pro --batteryState charged --batteryLevel 100`:
    /// every enumeration comes back as a number.
    func testStatusBarListAfterAFullOverride() throws {
        let overrides = SimctlParsing.statusBarOverrides(
            from: try Self.text("controls", "simctl-status_bar-list.override-full.stdout.txt")
        )
        XCTAssertEqual(overrides.time, "09:41")
        XCTAssertEqual(overrides.dataNetworkCode, 11)
        XCTAssertEqual(overrides.dataNetwork, .fiveG)
        XCTAssertEqual(overrides.wifiModeCode, 3)
        XCTAssertEqual(overrides.wifiMode, .active)
        XCTAssertEqual(overrides.wifiBars, 3)
        XCTAssertEqual(overrides.cellularMode, .active)
        XCTAssertEqual(overrides.cellularBars, 4)
        XCTAssertEqual(overrides.operatorName, "Device Hub Pro")
        XCTAssertEqual(overrides.batteryState, .charged)
        XCTAssertEqual(overrides.batteryLevel, 100)
        XCTAssertEqual(overrides.notCharging, 0)
    }

    /// Spike: `--dataNetwork lte --wifiMode failed --wifiBars 0
    /// --cellularBars 2 --batteryState discharging --batteryLevel 7` lists
    /// 8 / 2 / 0; and an ISO time (`2007-01-09T09:41:00.000Z`) lists as the
    /// device-local 11:41 (UTC+3).
    func testStatusBarListEnumCodesFromTheSpike() throws {
        let lte = SimctlParsing.statusBarOverrides(
            from: try Self.text("controls", "simctl-status_bar-list.override-lte-failed-wifi.stdout.txt")
        )
        XCTAssertEqual(lte.dataNetwork, .lte)
        XCTAssertEqual(lte.wifiMode, .failed)
        XCTAssertEqual(lte.wifiBars, 0)
        XCTAssertEqual(lte.cellularBars, 2)
        XCTAssertEqual(lte.batteryState, .discharging)
        XCTAssertEqual(lte.batteryLevel, 7)

        let iso = SimctlParsing.statusBarOverrides(
            from: try Self.text("controls", "simctl-status_bar-list.iso-time.stdout.txt")
        )
        XCTAssertEqual(iso.time, "11:41")
        XCTAssertEqual(SimulatorDataNetwork.wifi.listCode, SimulatorDataNetwork.hide.listCode)
    }

    // MARK: - location

    /// `location <udid> list`: the four predefined scenarios.
    func testLocationScenarios() throws {
        let scenarios = SimctlParsing.locationScenarios(
            from: try Self.text("controls", "simctl-location-list.stdout.txt")
        )
        XCTAssertEqual(scenarios.map(\.name), ["City Run", "City Bicycle Ride", "Freeway Drive", "Apple"])
        XCTAssertEqual(scenarios.first?.description, "City Run")
    }

    // MARK: - Errors

    /// SimError 405 (a device in the wrong state) exits 149 = 405 mod 256:
    /// `erase` while booted and a second `shutdown`.
    func testInvalidStateErrors() throws {
        for (name, message) in [
            ("simctl-erase-booted.stderr.txt", "Unable to erase contents and settings in current state: Booted"),
            ("simctl-shutdown-already-shutdown.stderr.txt", "Unable to shutdown device in current state: Shutdown"),
        ] {
            let failure = SimctlErrors.failure(
                arguments: ["erase", Self.udid],
                exitCode: 149,
                standardError: try Self.text("simctl-core", name)
            )
            XCTAssertEqual(failure.error, SimctlErrorReference(domain: "com.apple.CoreSimulator.SimError", code: 405))
            XCTAssertEqual(failure.kind, .invalidState, name)
            XCTAssertEqual(failure.message, message)
            XCTAssertEqual(failure.underlying, [])
            XCTAssertEqual(SimctlErrors.exitStatus(forErrorCode: 405), 149)
        }
    }

    /// POSIX 3 with an underlying error: an unknown bundle (`appinfo`, exit
    /// 3) and `terminate` of an app that is not running (exit 3).
    func testNotFoundErrors() throws {
        let unknown = SimctlErrors.failure(
            arguments: ["appinfo", Self.udid, "com.example.none"],
            exitCode: 3,
            standardError: try Self.text("simctl-core", "simctl-appinfo-unknown.stderr.txt")
        )
        XCTAssertEqual(unknown.kind, .notFound)
        XCTAssertEqual(unknown.message, "Simulator device failed to lookup application properties for com.example.none.")
        XCTAssertEqual(unknown.underlying, [SimctlErrorReference(domain: "NSPOSIXErrorDomain", code: 3)])

        let notRunning = SimctlErrors.failure(
            arguments: ["terminate", Self.udid, "com.apple.mobilesafari"],
            exitCode: 3,
            standardError: try Self.text("simctl-core", "simctl-terminate-not-running.stderr.txt")
        )
        XCTAssertEqual(notRunning.kind, .notFound)
        XCTAssertEqual(notRunning.message, "Simulator device failed to terminate com.apple.mobilesafari.")
    }

    /// Failures without a `domain=` header: an unknown UDID (exit 148), a
    /// missing `--set` folder (exit 1), and a usage text (spike, exit 117).
    func testErrorsWithoutAHeader() throws {
        let invalid = SimctlErrors.failure(
            arguments: ["ui", "00000000-0000-0000-0000-000000000000", "appearance"],
            exitCode: 148,
            standardError: try Self.text("simctl-core", "simctl-ui-invalid-device.stderr.txt")
        )
        XCTAssertEqual(invalid.kind, .invalidDevice)
        XCTAssertNil(invalid.error)
        XCTAssertEqual(invalid.message, "Invalid device: 00000000-0000-0000-0000-000000000000")

        let missingSet = SimctlErrors.failure(
            arguments: ["list", "-j", "devices"],
            exitCode: 1,
            standardError: try Self.text("simctl-core", "simctl-set-missing.stderr.txt")
        )
        XCTAssertEqual(missingSet.kind, .missingDeviceSet)

        let usage = SimctlErrors.failure(
            arguments: ["privacy", Self.udid, "grant", "photos"],
            exitCode: 117,
            standardError: try Self.text("simctl-core", "simctl-privacy-grant-no-bundle.stderr.txt")
        )
        XCTAssertEqual(usage.kind, .usage)
        XCTAssertEqual(usage.message, "Bundle identifier is required for grant actions")
    }

    /// Spike: the header is not always the first line (`location start` with
    /// no waypoints, exit 22), and exit codes are the code mod 256
    /// (`push` to an unknown bundle: UNErrorDomain 2003 → 211; `openurl` of
    /// garbage: OSStatus −50 → 206).
    func testHeaderAfterOtherLinesAndTruncatedExitCodes() throws {
        let waypoints = SimctlErrors.failure(
            arguments: ["location", "x", "start"],
            exitCode: 22,
            standardError: try Self.text("simctl-core", "simctl-location-start-no-waypoints.stderr.txt")
        )
        XCTAssertEqual(waypoints.error, SimctlErrorReference(domain: "NSPOSIXErrorDomain", code: 22))
        XCTAssertEqual(waypoints.kind, .invalidArgument)
        XCTAssertEqual(waypoints.message, "Simulator device failed to complete the requested operation.")

        let push = SimctlErrors.failure(
            arguments: ["push"],
            exitCode: 211,
            standardError: try Self.text("simctl-core", "simctl-push-unknown-bundle.stderr.txt")
        )
        XCTAssertEqual(push.error, SimctlErrorReference(domain: "UNErrorDomain", code: 2003))
        XCTAssertEqual(SimctlErrors.exitStatus(forErrorCode: 2003), 211)

        let url = SimctlErrors.failure(
            arguments: ["openurl"],
            exitCode: 206,
            standardError: try Self.text("simctl-core", "simctl-openurl-invalid.stderr.txt")
        )
        XCTAssertEqual(url.error, SimctlErrorReference(domain: "NSOSStatusErrorDomain", code: -50))
        XCTAssertEqual(SimctlErrors.exitStatus(forErrorCode: -50), 206)
    }

    /// `status_bar override --time 9:41PM`: POSIX 22, exit 22.
    func testStatusBarBadTime() throws {
        let failure = SimctlErrors.failure(
            arguments: ["status_bar"],
            exitCode: 22,
            standardError: try Self.text("controls", "simctl-status_bar-override-bad-time.stderr.txt")
        )
        XCTAssertEqual(failure.kind, .invalidArgument)
        XCTAssertEqual(failure.underlying, [SimctlErrorReference(domain: "NSPOSIXErrorDomain", code: 22)])
    }
}
