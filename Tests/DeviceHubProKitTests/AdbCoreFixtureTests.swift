import XCTest
@testable import DeviceHubProKit

/// The adb-core parsers fed byte-exact captures instead of invented text.
///
/// Every fixture under `Fixtures/api37-emulator/adb-core/` is the raw output
/// of the exact command production runs, captured from an API 37 emulator
/// (`emulator-5554`: AVD `Pixel_9_Pro_Fold`, image `sdk_gphone16k_arm64`,
/// Android 17) with platform-tools 37.0.0, emulator 37.2.8 (the running VM)
/// and SDK emulator 36.6.11 / cmdline-tools 22.0 on the Mac. The expected
/// values are spelled out here and were read back through a second command
/// (noted beside each), never computed by the parser under test.
///
/// Files are named after their command: `shell-…` is `adb -s emulator-5554
/// shell …`, `emu-…` is `adb -s emulator-5554 emu …`, `host-…` runs on the
/// Mac. `.stdout`/`.stderr` pairs keep the two streams apart where the
/// production code reads them separately.
final class AdbCoreFixtureTests: XCTestCase {
    static let fixtureDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/api37-emulator/adb-core", isDirectory: true)

    static func url(_ name: String) -> URL {
        fixtureDirectory.appendingPathComponent(name)
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: url(name))
    }

    /// Decoded the way `ProcessResult.standardOutputText` decodes a child's
    /// output.
    static func text(_ name: String) throws -> String {
        try XCTUnwrap(String(data: data(name), encoding: .utf8), "\(name) is not UTF-8")
    }

    // MARK: - adb devices / track-devices

    /// `adb devices -l` (what `AdbClient.listDevices` and the watcher's
    /// degraded poll run). Cross-checked against `getprop`
    /// (`ro.product.name`, `ro.product.model`, `ro.product.device`).
    func testDevicesLongListing() throws {
        let devices = AdbParsing.devices(from: try Self.text("adb-devices-l.txt"))
        XCTAssertEqual(devices, [
            AndroidDevice(
                serial: "emulator-5554",
                state: "device",
                model: "sdk_gphone16k_arm64",
                product: "sdk_gphone16k_arm64",
                device: "emu64a16k",
                transportID: "2"
            ),
        ])
        XCTAssertTrue(devices[0].isEmulator)
        XCTAssertTrue(devices[0].isOnline)
        XCTAssertEqual(devices[0].displayName, "sdk_gphone16k_arm64")
    }

    /// The plain `adb devices` rows are tab-separated.
    func testDevicesPlainListing() throws {
        let devices = AdbParsing.devices(from: try Self.text("adb-devices.txt"))
        XCTAssertEqual(devices, [AndroidDevice(serial: "emulator-5554", state: "device")])
    }

    /// The first frame `adb track-devices -l` writes (the `DeviceWatcher`
    /// child): `0074` then the `devices -l` row, with no header line.
    func testTrackDevicesLongFirstFrame() throws {
        let bytes = try Self.data("adb-track-devices-l.bin")
        var decoder = AdbHostFrameDecoder()
        let payloads = try decoder.append(bytes)
        XCTAssertEqual(payloads.count, 1)
        let devices = AdbParsing.trackDevicesSnapshot(from: payloads[0])
        XCTAssertEqual(devices, [
            AndroidDevice(
                serial: "emulator-5554",
                state: "device",
                model: "sdk_gphone16k_arm64",
                product: "sdk_gphone16k_arm64",
                device: "emu64a16k",
                transportID: "2"
            ),
        ])
        // The frame carries exactly what a `devices -l` read reports.
        XCTAssertEqual(devices, AdbParsing.devices(from: try Self.text("adb-devices-l.txt")))

        // The same bytes arriving one at a time complete the frame only on
        // its last byte.
        var trickle = AdbHostFrameDecoder()
        var trickled: [String] = []
        for (index, byte) in bytes.enumerated() {
            let completed = try trickle.append(Data([byte]))
            if index < bytes.count - 1 {
                XCTAssertTrue(completed.isEmpty, "frame completed early at byte \(index)")
            }
            trickled += completed
        }
        XCTAssertEqual(trickled, payloads)
    }

    /// `adb devices -l` and the first `adb track-devices -l` frame (`00de`,
    /// 222 bytes) captured while a USB phone (a Xiaomi `2209116AG`) was
    /// attached beside the emulator (its serial replaced by the same-length
    /// `0a1b2c3d4e5f`, so the frame length is unchanged): a physical row carries its `usb:<path>`
    /// devpath before `product:`, and adb lists it first. Both commands
    /// agree row for row.
    func testDevicesWithAUsbPhoneAttached() throws {
        let phone = AndroidDevice(
            serial: "0a1b2c3d4e5f",
            state: "device",
            model: "2209116AG",
            product: "sweet_global2",
            device: "sweet",
            transportID: "5"
        )
        let emulator = AndroidDevice(
            serial: "emulator-5554",
            state: "device",
            model: "sdk_gphone16k_arm64",
            product: "sdk_gphone16k_arm64",
            device: "emu64a16k",
            transportID: "2"
        )
        let listed = AdbParsing.devices(from: try Self.text("adb-devices-l-usb-phone.txt"))
        XCTAssertEqual(listed, [phone, emulator])
        XCTAssertFalse(listed[0].isEmulator)
        XCTAssertEqual(listed[0].displayName, "2209116AG")

        var decoder = AdbHostFrameDecoder()
        let payloads = try decoder.append(try Self.data("adb-track-devices-l-usb-phone.bin"))
        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(payloads[0].utf8.count, 0xde)
        XCTAssertEqual(AdbParsing.trackDevicesSnapshot(from: payloads[0]), [phone, emulator])
    }

    /// The first frame of the plain `adb track-devices`: `0015` then
    /// `serial<TAB>state`.
    func testTrackDevicesPlainFirstFrame() throws {
        var decoder = AdbHostFrameDecoder()
        let payloads = try decoder.append(try Self.data("adb-track-devices.bin"))
        XCTAssertEqual(payloads, ["emulator-5554\tdevice\n"])
        XCTAssertEqual(
            AdbParsing.trackDevicesSnapshot(from: payloads[0]),
            [AndroidDevice(serial: "emulator-5554", state: "device")]
        )
    }

    // MARK: - getprop

    /// `adb shell getprop ro.build.version.sdk` (`AdbClient.sdkLevel`).
    func testSdkLevel() async throws {
        let adb = try makeTool(stdout: "shell-getprop-ro.build.version.sdk.txt")
        let level = try await adb.adbClient.sdkLevel(serial: "emulator-5554")
        XCTAssertEqual(level, 37)
    }

    /// `DeviceInfo` from the full `adb shell getprop` dump, through
    /// `AdbClient.deviceInfo`. Model/product agree with `adb devices -l`;
    /// the AVD name agrees with `adb emu avd name`.
    func testDeviceInfoFromFullGetprop() async throws {
        let adb = try makeTool(stdout: "shell-getprop.txt")
        let info = try await adb.adbClient.deviceInfo(serial: "emulator-5554", isEmulator: true)
        XCTAssertEqual(info.serial, "emulator-5554")
        XCTAssertEqual(info.model, "sdk_gphone16k_arm64")
        XCTAssertEqual(info.manufacturer, "Google")
        XCTAssertEqual(info.androidVersion, "17")
        XCTAssertEqual(info.apiLevel, "37")
        XCTAssertEqual(info.abi, "arm64-v8a")
        XCTAssertTrue(info.isEmulator)
        // The Controls panel's device class: a phone image declares `emulator` only.
        XCTAssertEqual(info.characteristics, "emulator")
        XCTAssertEqual(info.formFactor, .handheld)

        let properties = AdbParsing.getprop(from: try Self.text("shell-getprop.txt"))
        XCTAssertEqual(properties["ro.boot.qemu.avd_name"], "Pixel_9_Pro_Fold")
        XCTAssertEqual(properties["ro.product.name"], "sdk_gphone16k_arm64")
        XCTAssertEqual(properties["ro.product.device"], "emu64a16k")
        XCTAssertEqual(
            properties["ro.build.fingerprint"],
            "google/sdk_gphone16k_arm64/emu64a16k:17/CP31.260623.012/16064790:user/dev-keys"
        )
        XCTAssertEqual(properties["persist.sys.boot.reason"], "")
        XCTAssertEqual(properties["vold.has_reserved"], "1")
    }

    /// A getprop value can span lines: bootstat keeps
    /// `persist.sys.boot.reason.history` as one `reason,time` entry per
    /// line, so the dump prints its record over four lines and only the last
    /// one closes the `]`. The value agrees with `adb shell getprop
    /// persist.sys.boot.reason.history`, and the record's continuation lines
    /// neither end the dump's parsing nor become properties of their own.
    func testGetpropKeepsAMultiLineValueWhole() throws {
        let properties = AdbParsing.getprop(from: try Self.text("shell-getprop.txt"))
        XCTAssertEqual(
            properties["persist.sys.boot.reason.history"],
            "reboot,1790279800\nreboot,1790279318\nreboot,1790151787\nreboot,1789093744"
        )
        let single = try Self.text("shell-getprop-persist.sys.boot.reason.history.txt")
        XCTAssertEqual(properties["persist.sys.boot.reason.history"], String(single.dropLast()))

        // 556 lines, 553 records: the three continuation lines are not keys.
        XCTAssertEqual(properties.count, 553)
        XCTAssertFalse(properties.keys.contains { $0.hasPrefix("reboot,") })
        // The record after the multi-line one still parses.
        XCTAssertEqual(properties["persist.sys.dalvik.vm.lib.2"], "libart.so")
    }

    // MARK: - pm list packages

    /// `pm list packages -3` (`AdbClient.listPackages`, the default).
    func testThirdPartyPackages() throws {
        XCTAssertEqual(
            AdbParsing.packages(from: try Self.text("shell-pm-list-packages-3.txt")),
            ["com.devicehubpro.verifier", "com.example.testing.companion"]
        )
    }

    /// `pm list packages` (`listPackages(thirdPartyOnly: false)`): 260 rows.
    func testAllPackages() throws {
        let packages = AdbParsing.packages(from: try Self.text("shell-pm-list-packages.txt"))
        XCTAssertEqual(packages.count, 260)
        XCTAssertEqual(Set(packages).count, 260)
        for id in ["android", "com.example.browser", "com.example.mails", "com.devicehubpro.verifier"] {
            XCTAssertTrue(packages.contains(id), "missing \(id)")
        }
        XCTAssertFalse(packages.contains { $0.contains(":") || $0.contains(" ") })
    }

    /// `pm list packages --show-versioncode -3` (`listPackagesDetailed`).
    /// Version codes agree with `dumpsys package <id>` (`versionCode=1`).
    func testThirdPartyPackagesWithVersions() throws {
        XCTAssertEqual(
            AdbParsing.packagesWithVersions(
                from: try Self.text("shell-pm-list-packages-show-versioncode-3.txt")
            ),
            [
                AdbClient.InstalledPackage(id: "com.devicehubpro.verifier", versionCode: "1"),
                AdbClient.InstalledPackage(id: "com.example.testing.companion", versionCode: "1"),
            ]
        )
    }

    /// `pm list packages --show-versioncode` (`includeSystem: true`): the
    /// same 260 ids as the plain listing. GMS's code agrees with the first
    /// `versionCode=` line of `dumpsys package com.example.mails`.
    func testAllPackagesWithVersions() throws {
        let packages = AdbParsing.packagesWithVersions(
            from: try Self.text("shell-pm-list-packages-show-versioncode.txt")
        )
        XCTAssertEqual(
            packages.map(\.id),
            AdbParsing.packages(from: try Self.text("shell-pm-list-packages.txt"))
        )
        XCTAssertTrue(packages.allSatisfy { $0.versionCode != nil })
        let byID = Dictionary(uniqueKeysWithValues: packages.map { ($0.id, $0.versionCode) })
        XCTAssertEqual(byID["com.example.mails"], "263332035")
        XCTAssertEqual(byID["com.android.vending"], "85322340")
        XCTAssertEqual(byID["com.example.browser"], "801005204")
    }

    /// `listPackagesDetailed` end to end on this image: the version codes
    /// come from the `--show-versioncode` listing itself (no fallback).
    func testDetailedListingKeepsVersionCodesWhenSupported() async throws {
        let adb = try makeTool(stdout: "shell-pm-list-packages-show-versioncode-3.txt")
        let packages = try await adb.adbClient.listPackagesDetailed(serial: "emulator-5554")
        XCTAssertEqual(packages, [
            AdbClient.InstalledPackage(id: "com.devicehubpro.verifier", versionCode: "1"),
            AdbClient.InstalledPackage(id: "com.example.testing.companion", versionCode: "1"),
        ])
    }

    /// `pm list packages --devicehubpro-unknown-option`, captured: the package
    /// manager answers an option it does not know with `Error: Unknown
    /// option: <option>` on stdout, stderr empty, exit 255
    /// (`PackageManagerShellCommand.runListPackages`, `default:` branch).
    /// Real listings never read as a refusal: every row starts `package:`.
    func testUnknownPmOptionReadsAsARefusal() throws {
        let refusal = try Self.text("shell-pm-list-packages-devicehubpro-unknown-option.stdout.txt")
        XCTAssertEqual(refusal, "Error: Unknown option: --devicehubpro-unknown-option\n")
        XCTAssertTrue(try Self.data("shell-pm-list-packages-devicehubpro-unknown-option.stderr.txt").isEmpty)
        XCTAssertTrue(AdbClient.packageManagerRefused(refusal))
        for listing in [
            "shell-pm-list-packages.txt",
            "shell-pm-list-packages-3.txt",
            "shell-pm-list-packages-show-versioncode.txt",
            "shell-pm-list-packages-show-versioncode-3.txt",
        ] {
            XCTAssertFalse(AdbClient.packageManagerRefused(try Self.text(listing)), listing)
        }
        XCTAssertFalse(AdbClient.packageManagerRefused("package:com.example.errorreporter versionCode:3\n"))
    }

    /// SOURCE-DERIVED: `--show-versioncode` arrived in Android 8.0 (the
    /// `case "--show-versioncode"` first appears in android-8.0.0_r1's
    /// `PackageManagerShellCommand.runListPackages`). Android 7.x (API 24-25)
    /// answers it through the `default:` branch captured above: stdout,
    /// exit 255. Android 6 and older run `Pm.java` (android-6.0.1_r1), which
    /// prints the same line on stderr and exits 1, but the legacy shell
    /// merges stderr into stdout (CRLF under a PTY) and reports no exit
    /// status. Each must fall back to the plain listing, without version
    /// codes, instead of failing (Android 7) or showing no apps (Android 6).
    func testDetailedListingFallsBackWithoutShowVersioncode() async throws {
        let refusals: [(answer: String, exitCode: Int32)] = [
            ("Error: Unknown option: --show-versioncode\n", 255),
            ("Error: Unknown option: --show-versioncode\n", 0),
            ("Error: Unknown option: --show-versioncode\r\n", 0),
        ]
        for refusal in refusals {
            let adb = try makeTool(
                whenArgument: "--show-versioncode",
                stdoutText: refusal.answer,
                exitCode: refusal.exitCode,
                otherwise: "shell-pm-list-packages-3.txt"
            )
            let packages = try await adb.tool.adbClient.listPackagesDetailed(serial: "emulator-5554")
            XCTAssertEqual(packages, [
                AdbClient.InstalledPackage(id: "com.devicehubpro.verifier", versionCode: nil),
                AdbClient.InstalledPackage(id: "com.example.testing.companion", versionCode: nil),
            ], "exit \(refusal.exitCode)")
            XCTAssertEqual(try adb.runs(), [
                "-s emulator-5554 shell pm list packages --show-versioncode -3",
                "-s emulator-5554 shell pm list packages -3",
            ])
        }

        let all = try makeTool(
            whenArgument: "--show-versioncode",
            stdoutText: "Error: Unknown option: --show-versioncode\n",
            exitCode: 255,
            otherwise: "shell-pm-list-packages.txt"
        )
        let packages = try await all.tool.adbClient.listPackagesDetailed(serial: "emulator-5554", includeSystem: true)
        XCTAssertEqual(packages.count, 260)
        XCTAssertTrue(packages.allSatisfy { $0.versionCode == nil })
        XCTAssertEqual(try all.runs(), [
            "-s emulator-5554 shell pm list packages --show-versioncode",
            "-s emulator-5554 shell pm list packages",
        ])
    }

    /// SOURCE-DERIVED: a package manager that refuses the plain listing too
    /// (`Pm.java`'s `Error: Could not access the Package Manager.  Is the
    /// system running?`, exit 0 through the legacy shell) is an error, not an
    /// empty app list; a failing exit without pm's answer is not retried.
    func testDetailedListingReportsARefusedPlainListing() async throws {
        let unreachable = "Error: Could not access the Package Manager.  Is the system running?\r\n"
        let adb = try makeTool(stdoutText: unreachable)
        do {
            _ = try await adb.adbClient.listPackagesDetailed(serial: "emulator-5554")
            XCTFail("a refused listing must throw")
        } catch AdbError.commandFailed(let arguments, _, let message) {
            XCTAssertEqual(arguments, ["-s", "emulator-5554", "shell", "pm", "list", "packages", "-3"])
            XCTAssertEqual(message, "Error: Could not access the Package Manager.  Is the system running?")
        }

        let offline = try makeTool(stdoutText: "", stderrText: "adb: device offline\n", exitCode: 1)
        do {
            _ = try await offline.adbClient.listPackagesDetailed(serial: "emulator-5554")
            XCTFail("a failing adb must throw")
        } catch AdbError.commandFailed(let arguments, let exitCode, let message) {
            XCTAssertEqual(arguments.last, "-3")
            XCTAssertTrue(arguments.contains("--show-versioncode"))
            XCTAssertEqual(exitCode, 1)
            XCTAssertEqual(message, "adb: device offline\n")
        }
    }

    // MARK: - Pre-shell-protocol devices (SOURCE-DERIVED)

    /// SOURCE-DERIVED: devices without adb's `shell_v2` feature (Android 6
    /// and older; the shell protocol arrived in Android 7.0) serve `adb shell
    /// <command>` through adbd's legacy `shell:` service, which runs the
    /// command under a PTY: its ONLCR output translation turns every `\n`
    /// into `\r\n` (the reason `adb exec-out` exists). No such device is at
    /// hand, so the real API 37 captures are replayed with that translation
    /// applied; each must parse exactly as its LF original.
    func testShellOutputThroughALegacyPtyParsesLikeTheOriginal() throws {
        func ptyTranslated(_ name: String) throws -> String {
            try Self.text(name).replacingOccurrences(of: "\n", with: "\r\n")
        }

        let getprop = AdbParsing.getprop(from: try ptyTranslated("shell-getprop.txt"))
        XCTAssertEqual(getprop, AdbParsing.getprop(from: try Self.text("shell-getprop.txt")))
        XCTAssertEqual(getprop.count, 553)
        XCTAssertEqual(getprop["ro.build.version.sdk"], "37")
        XCTAssertEqual(
            getprop["persist.sys.boot.reason.history"],
            "reboot,1790279800\nreboot,1790279318\nreboot,1790151787\nreboot,1789093744"
        )

        let packages = AdbParsing.packages(from: try ptyTranslated("shell-pm-list-packages-3.txt"))
        XCTAssertEqual(packages, ["com.devicehubpro.verifier", "com.example.testing.companion"])
        XCTAssertEqual(
            AdbParsing.packages(from: try ptyTranslated("shell-pm-list-packages.txt")).count,
            260
        )
        XCTAssertEqual(
            AdbParsing.packagesWithVersions(from: try ptyTranslated("shell-pm-list-packages-show-versioncode-3.txt")),
            [
                AdbClient.InstalledPackage(id: "com.devicehubpro.verifier", versionCode: "1"),
                AdbClient.InstalledPackage(id: "com.example.testing.companion", versionCode: "1"),
            ]
        )

        let global = AdbParsing.globalSettings(from: try ptyTranslated("shell-settings-list-global.txt"))
        XCTAssertEqual(global, AdbParsing.globalSettings(from: try Self.text("shell-settings-list-global.txt")))
        XCTAssertEqual(global["airplane_mode_on"], "0")
        XCTAssertEqual(global["display_size_forced"], "")

        XCTAssertEqual(
            AdbParsing.appearanceReading(from: try ptyTranslated("shell-cmd-uimode-night.txt")),
            .mode(.dark)
        )
        let size = PhysicalInput.parseDisplaySize(fromWmSize: try ptyTranslated("shell-wm-size.txt"))
        XCTAssertEqual(size?.width, 2076)
        XCTAssertEqual(size?.height, 2152)
    }

    // MARK: - Display

    /// `adb shell wm size` (`naturalDisplaySize`'s parser). Agrees with the
    /// ON `DisplayDeviceInfo` in `dumpsys display` (`2076 x 2152`) and with
    /// the screencap PNG's IHDR (`testScreencapStripsTheMultiDisplayWarning`).
    func testWmSize() throws {
        let size = PhysicalInput.parseDisplaySize(fromWmSize: try Self.text("shell-wm-size.txt"))
        XCTAssertEqual(size?.width, 2076)
        XCTAssertEqual(size?.height, 2152)
    }

    /// `adb shell dumpsys display` on the unfolded Fold: two display
    /// devices (inner ON with layer stack 0, outer OFF with layer stack
    /// -1), both at rotation 0 (`DisplayInfo{… rotation 0 …}`).
    func testDisplayRotationFromDumpsysDisplay() throws {
        XCTAssertEqual(AdbParsing.displayRotation(from: try Self.text("shell-dumpsys-display.txt")), 0)
    }

    /// `adb exec-out screencap -p` on the two-display Fold starts with
    /// screencap's multi-display warning (exec-out merges stderr), then the
    /// PNG. The fixture is the capture's first 410 bytes: the warning, the
    /// signature, IHDR, sBIT and sRGB — the image data is left out to keep
    /// the repository small.
    func testScreencapStripsTheMultiDisplayWarning() throws {
        let bytes = try Self.data("exec-out-screencap-p.head.bin")
        XCTAssertTrue(bytes.starts(with: Data("[Warning] Multiple displays were found".utf8)))

        let png = try XCTUnwrap(AdbParsing.pngData(from: bytes))
        XCTAssertEqual(png.count, bytes.count - 347)
        XCTAssertEqual(Array(png.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        // IHDR: width and height, big-endian, right after the chunk header.
        let ihdr = Array(png[png.startIndex + 8..<png.startIndex + 24])
        XCTAssertEqual(Array(ihdr[4..<8]), Array("IHDR".utf8))
        let width = ihdr[8..<12].reduce(0) { $0 << 8 | Int($1) }
        let height = ihdr[12..<16].reduce(0) { $0 << 8 | Int($1) }
        XCTAssertEqual(width, 2076)
        XCTAssertEqual(height, 2152)
    }

    // MARK: - Settings and appearance

    /// `adb shell cmd uimode night`. Agrees with `settings list secure`
    /// (`ui_night_mode=2`, `UiModeManager.MODE_NIGHT_YES`).
    func testAppearanceReading() throws {
        XCTAssertEqual(
            AdbParsing.appearanceReading(from: try Self.text("shell-cmd-uimode-night.txt")),
            .mode(.dark)
        )
        let secure = AdbParsing.globalSettings(from: try Self.text("shell-settings-list-secure.txt"))
        XCTAssertEqual(secure["ui_night_mode"], "2")
    }

    /// `adb shell settings list global` (`AdbClient.globalSettings`). Values
    /// agree with `settings get global <key>`; a value may hold `=`, be
    /// empty, or be the literal `null` the settings provider prints for a
    /// null row.
    func testSettingsListGlobal() throws {
        let settings = AdbParsing.globalSettings(from: try Self.text("shell-settings-list-global.txt"))
        XCTAssertEqual(settings.count, 205)
        XCTAssertEqual(settings["airplane_mode_on"], "0")
        XCTAssertEqual(settings["wifi_on"], "1")
        XCTAssertEqual(settings["bluetooth_on"], "1")
        XCTAssertEqual(settings["window_animation_scale"], "1")
        XCTAssertEqual(
            settings["backup_agent_timeout_parameters"],
            "kv_backup_agent_timeout_millis=45000,custom_kv_backup_timeout_ms_map=android=60000"
        )
        XCTAssertEqual(settings["display_size_forced"], "")
        XCTAssertEqual(settings["alarm_manager_dummy_flags"], "null")
    }

    /// `settings list system` and `settings list secure`
    /// (`AdbClient.settingsList(namespace:)`).
    func testSettingsListSystemAndSecure() throws {
        let system = AdbParsing.globalSettings(from: try Self.text("shell-settings-list-system.txt"))
        XCTAssertEqual(system.count, 46)
        XCTAssertEqual(system["font_scale"], "1.3")
        XCTAssertEqual(system["screen_off_timeout"], "2147483647")
        XCTAssertEqual(
            system["alarm_alert"],
            "content://media/internal/audio/media/21?title=Cesium&canonical=1"
        )

        let secure = AdbParsing.globalSettings(from: try Self.text("shell-settings-list-secure.txt"))
        XCTAssertEqual(secure.count, 159)
        XCTAssertEqual(secure["accessibility_enabled"], "0")
        XCTAssertEqual(secure["high_text_contrast_enabled"], "0")
        XCTAssertEqual(secure["enabled_accessibility_services"], "null")
        XCTAssertEqual(AccessibilityServices.parse(secure["enabled_accessibility_services"] ?? ""), [])
    }

    // MARK: - Emulator console

    /// `adb emu avd name`: CRLF-terminated, then `OK`. Agrees with getprop's
    /// `ro.boot.qemu.avd_name` and the discovery file's `avd.id`.
    func testEmuAvdName() throws {
        XCTAssertEqual(AdbParsing.avdName(from: try Self.text("emu-avd-name.txt")), "Pixel_9_Pro_Fold")
    }

    /// `adb emu avd discoverypath`, then the discovery file it names
    /// (`EmulatorDiscovery.grpcInfo`). This VM was started without
    /// `-grpc-use-token`, so the file has no `grpc.token`; its port agrees
    /// with the VM's `-grpc 8554` in `ps`.
    func testEmuDiscoveryPathAndFile() throws {
        XCTAssertEqual(
            AdbParsing.discoveryPath(from: try Self.text("emu-avd-discoverypath.txt")),
            "/Users/testeruser/Library/Caches/TemporaryItems/avd/running/pid_71988.ini"
        )
        // `avd path` answers in the same shape; it is not a discovery file.
        XCTAssertEqual(
            AdbParsing.discoveryPath(from: try Self.text("emu-avd-path.txt")),
            "/Users/testeruser/.android/avd/Pixel_9_Pro_Fold.avd"
        )

        let discovery = AdbParsing.emulatorDiscovery(from: try Self.text("emulator-discovery-pid.ini"))
        XCTAssertEqual(discovery.port, 8554)
        XCTAssertNil(discovery.token)
    }

    /// `adb emu sensor get acceleration` (CRLF, then `OK`).
    func testEmuSensorGetAcceleration() throws {
        let vector = try XCTUnwrap(
            AdbParsing.sensorTriple(from: try Self.text("emu-sensor-get-acceleration.txt"))
        )
        XCTAssertEqual(vector.x, 1.5)
        XCTAssertEqual(vector.y, 2.5)
        XCTAssertEqual(vector.z, 3.5)
        XCTAssertEqual(AdbParsing.poseIndex(x: vector.x, y: vector.y, z: vector.z), 0)
    }

    /// `adb emu resize-display` with no index (`AdbClient.resizeDisplayPresets`),
    /// captured with exit status 0 from the emulator 37.2.8 VM. The console
    /// answers with its usage line, `KO usage: "resize-display <index>" 0:
    /// phone\t1: unfolded\t2: tablet` and CRLF. The same literal sits in
    /// emulator 36.6.11's string table, and the console prints it on every
    /// AVD, resizable or not (this one is not), so the list is the console's
    /// presets and `AvdConfig.isResizable` decides whether the AVD offers
    /// them.
    func testResizeDisplayUsageListsThePresets() async throws {
        let expected = [
            ResizePreset(index: 0, name: "phone"),
            ResizePreset(index: 1, name: "unfolded"),
            ResizePreset(index: 2, name: "tablet"),
        ]
        let usage = try Self.text("emu-resize-display.txt")
        XCTAssertEqual(AdbParsing.resizePresets(fromUsage: usage), expected)

        let adb = try makeTool(stdout: "emu-resize-display.txt")
        let presets = try await adb.adbClient.resizeDisplayPresets(serial: "emulator-5554")
        XCTAssertEqual(presets, expected)

        // The generic console call still treats the KO answer as a failure;
        // only the preset read accepts it.
        do {
            try await adb.adbClient.emuCommand(serial: "emulator-5554", ["resize-display"])
            XCTFail("a KO answer must throw")
        } catch AdbError.commandFailed(_, _, let message) {
            XCTAssertEqual(message, usage)
        }
    }

    /// A console that answers without a usage offers no presets; an adb that
    /// fails (the emulator went away) throws.
    func testResizeDisplayPresetsWithoutAUsage() async throws {
        let bareKO = try makeTool(stdoutText: "KO\r\n")
        let none = try await bareKO.adbClient.resizeDisplayPresets(serial: "emulator-5554")
        XCTAssertEqual(none, [])

        let gone = try makeTool(stdoutText: "", stderrText: "error: device 'emulator-5554' not found\n", exitCode: 1)
        do {
            _ = try await gone.adbClient.resizeDisplayPresets(serial: "emulator-5554")
            XCTFail("a failed adb call must throw")
        } catch AdbError.commandFailed(let arguments, let exitCode, let message) {
            XCTAssertEqual(arguments, ["-s", "emulator-5554", "emu", "resize-display"])
            XCTAssertEqual(exitCode, 1)
            XCTAssertEqual(message, "error: device 'emulator-5554' not found\n")
        }
    }

    // MARK: - Host processes

    /// `ps -axo pid=,command=` on the Mac (`EmulatorManager.runningEmulators`).
    /// The fixture keeps nine of the capture's 834 lines byte-exact — every
    /// emulator-related process (the VM, its crashpad handler and netsimd),
    /// the adb server and a tracker, and a few system processes (right-aligned
    /// pids, a path with spaces); the rest of the Mac's process list is left
    /// out as unrelated personal data.
    func testRunningEmulatorsFromPs() throws {
        let running = EmulatorManager.parseRunningEmulators(
            psOutput: try Self.text("host-ps-axo-pid-command.txt")
        )
        XCTAssertEqual(running, [RunningEmulator(avd: "Pixel_9_Pro_Fold", processID: 71988, grpcPort: 8554)])

        // The whole port ladder from real inputs: the discovery file wins;
        // without it, the AVD name `emu avd name` reports finds the VM in ps.
        let discovery = AdbParsing.emulatorDiscovery(from: try Self.text("emulator-discovery-pid.ini"))
        XCTAssertEqual(
            GrpcPortResolver.resolve(
                discovery: EmulatorGRPCInfo(port: try XCTUnwrap(discovery.port), token: discovery.token),
                avdName: "Pixel_9_Pro_Fold",
                running: running,
                liveScanPorts: []
            ),
            .discovery(8554)
        )
        XCTAssertEqual(
            GrpcPortResolver.resolve(
                discovery: nil,
                avdName: AdbParsing.avdName(from: try Self.text("emu-avd-name.txt")),
                running: running,
                liveScanPorts: []
            ),
            .processMatch(8554)
        )
    }

    /// `emulator -list-avds` (`EmulatorManager.listAvds`), SDK emulator
    /// 36.6.11 (37.2.8 prints the same bytes): one name per line, nothing on
    /// stderr. Agrees with the `<name>.ini` files in `~/.android/avd`.
    func testListAvds() async throws {
        let tool = try makeTool(
            stdout: "emulator-list-avds.stdout.txt",
            stderr: "emulator-list-avds.stderr.txt"
        )
        let avds = try await EmulatorManager(emulatorURL: tool.executableURL, processScope: .ownProcesses).listAvds()
        XCTAssertEqual(avds, [
            "MyNotes_API35",
            "Pixel_10_Pro",
            "Pixel_9_Pro",
            "Pixel_9_Pro_Fold",
            "Pixel_Fold",
            "ai_glasses_displayless_API37.1",
            "atd34",
        ])
    }

    /// `avdmanager list device` (cmdline-tools 22.0): 95 definitions. Its
    /// stderr complains about system images without a `devices.xml`, which
    /// `listDevices` ignores on a zero exit.
    func testAvdmanagerListDevice() throws {
        let devices = AvdmanagerParsing.devices(from: try Self.text("avdmanager-list-device.stdout.txt"))
        XCTAssertEqual(devices.count, 95)
        XCTAssertEqual(Set(devices.map(\.id)).count, 95)
        XCTAssertEqual(devices.first, AvdDevice(id: "ai_glasses_displayless", name: "Audio Glasses", tag: "ai-glasses"))
        XCTAssertEqual(devices.last, AvdDevice(id: "13.5in Freeform", name: "13.5\" Freeform"))
        for expected in [
            AvdDevice(id: "pixel_9_pro", name: "Pixel 9 Pro"),
            AvdDevice(id: "pixel_9_pro_fold", name: "Pixel 9 Pro Fold"),
            AvdDevice(id: "resizable", name: "Resizable (Experimental)"),
            AvdDevice(id: "medium_phone", name: "Medium Phone"),
            AvdDevice(id: "Galaxy Nexus", name: "Galaxy Nexus"),
            AvdDevice(id: "Nexus 7 2013", name: "Nexus 7"),
            AvdDevice(id: "8in Foldable", name: "8\" Fold-out"),
        ] {
            XCTAssertTrue(devices.contains(expected), "missing \(expected)")
        }
        let stderr = try Self.text("avdmanager-list-device.stderr.txt")
        XCTAssertTrue(stderr.hasPrefix("Error: Could not load devices from "))
    }

    // MARK: - Wireless debugging

    /// `adb mdns services`: the header, one `_adb._tcp` row (a phone on the
    /// LAN with legacy TCP debugging; the Openscreen backend prints the type
    /// without a trailing dot), then a blank line.
    func testMdnsServices() throws {
        let services = WirelessPairing.mdnsServices(from: try Self.text("adb-mdns-services.txt"))
        XCTAssertEqual(services, [
            WirelessPairing.MdnsService(
                instance: "adb-0A1B2C3D4E5F60718",
                type: "_adb._tcp",
                host: "192.168.1.199",
                port: 5555
            ),
        ])
        // A legacy `_adb._tcp` row is not a pairing-code connect endpoint.
        XCTAssertNil(WirelessPairing.connectEndpoint(forHost: "192.168.1.199", in: services))
    }

    /// `adb connect 127.0.0.1:1` (nothing listens): exit 0, the failure on
    /// stdout — `connect` must decide from the text.
    func testConnectFailureReportedOnStdoutWithExitZero() async throws {
        let adb = try makeTool(
            stdout: "adb-connect-unreachable.stdout.txt",
            stderr: "adb-connect-unreachable.stderr.txt",
            exitCode: 0
        )
        do {
            try await adb.adbClient.connect(address: "127.0.0.1:1")
            XCTFail("a refused connect must throw")
        } catch AdbError.commandFailed(let arguments, let exitCode, let message) {
            XCTAssertEqual(arguments, ["connect", "127.0.0.1:1"])
            XCTAssertEqual(exitCode, 0)
            XCTAssertEqual(message, "failed to connect to '127.0.0.1:1': Connection refused")
        }
    }

    /// `adb pair 127.0.0.1:1 123456` (nothing listens): exit 1, the
    /// `error:` message on stderr and stdout empty — `pair` reports stderr.
    func testPairFailureReportedOnStderrWithExitOne() async throws {
        XCTAssertTrue(try Self.data("adb-pair-unreachable.stdout.txt").isEmpty)
        XCTAssertEqual(
            try Self.text("adb-pair-unreachable.stderr.txt"),
            "error: protocol fault (couldn't read status message): Undefined error: 0\n"
        )
        let adb = try makeTool(
            stdout: "adb-pair-unreachable.stdout.txt",
            stderr: "adb-pair-unreachable.stderr.txt",
            exitCode: 1
        )
        do {
            try await adb.adbClient.pair(address: "127.0.0.1:1", code: "123456")
            XCTFail("a failed pair must throw")
        } catch AdbError.commandFailed(let arguments, let exitCode, let message) {
            XCTAssertEqual(arguments, ["pair", "127.0.0.1:1", "123456"])
            XCTAssertEqual(exitCode, 1)
            XCTAssertEqual(message, "error: protocol fault (couldn't read status message): Undefined error: 0")
        }

        let request = try WirelessPairing.request(address: "127.0.0.1:1", code: "123456", connectPort: "")
        let outcome = try await adb.adbClient.pairAndConnect(request, discoveryTimeout: .milliseconds(10))
        guard case .pairingFailed(let message) = outcome else {
            return XCTFail("expected pairingFailed, got \(outcome)")
        }
        XCTAssertTrue(message.contains("protocol fault"), message)
    }

    // MARK: - Package installs (SOURCE-DERIVED)

    /// SOURCE-DERIVED: `adb install` is not run against the shared emulator.
    /// platform-tools' streamed install (`client/adb_install.cpp`,
    /// `install_app_streamed`) prints `Performing Streamed Install` on
    /// stdout as it starts; a refused package ends with `adb: failed to
    /// install <apk>: <status>` on stderr and exit 1. The error must carry
    /// that status — `INSTALL_FAILED_VERSION_DOWNGRADE` is what tells the
    /// user to allow a downgrade.
    func testStreamedInstallFailureKeepsThePackageManagerReason() async throws {
        let refusal = "adb: failed to install /tmp/app.apk: Failure [INSTALL_FAILED_VERSION_DOWNGRADE: "
            + "Downgrade detected: Update version code 1 is older than current 2]\n"
        let adb = try makeTool(stdoutText: "Performing Streamed Install\n", stderrText: refusal, exitCode: 1)
        do {
            try await adb.adbClient.install(serial: "emulator-5554", apkURL: URL(fileURLWithPath: "/tmp/app.apk"))
            XCTFail("a refused install must throw")
        } catch AdbError.commandFailed(_, let exitCode, let message) {
            XCTAssertEqual(exitCode, 1)
            XCTAssertEqual(
                message,
                "adb: failed to install /tmp/app.apk: Failure [INSTALL_FAILED_VERSION_DOWNGRADE: "
                    + "Downgrade detected: Update version code 1 is older than current 2]\n"
                    + "Performing Streamed Install"
            )
        }

        // A pushed install (no streaming) reports on stdout alone.
        XCTAssertEqual(
            AdbClient.installFailureMessage(
                standardOutput: "\tpkg: /data/local/tmp/app.apk\nFailure [INSTALL_FAILED_ALREADY_EXISTS]\n",
                standardError: ""
            ),
            "pkg: /data/local/tmp/app.apk\nFailure [INSTALL_FAILED_ALREADY_EXISTS]"
        )
    }

    /// SOURCE-DERIVED: a pushed install, what adb falls back to on a device
    /// without the `cmd` feature (Android 6 and older): `install_app_legacy`
    /// (`client/adb_install.cpp`) prints `Performing Push Install`, pushes the
    /// APK to `/data/local/tmp/<basename>` and runs `pm install` there.
    /// The push summary (`client/file_sync_client.cpp`, `ReportTransferRate`)
    /// names the local path and goes to stdout up to platform-tools 34.0.5
    /// (`LinePrinter` wrote to stderr from 35.0.2). The legacy shell merges
    /// pm's stderr into stdout, so `Pm.java` (android-6.0.1_r1) adds its
    /// `\tpkg: <device path>` echo before `Success`, with `\r\n` endings under
    /// a PTY, and there is no exit status: the exit is 0 either way. A path
    /// or file name containing "error" is a success; pm's verdict lines decide.
    func testPushedInstallDecidesFromVerdictLinesNotThePath() async throws {
        let apk = "/Users/me/Projects/ErrorTracker/error-reporter.apk"
        let pushed = "Performing Push Install\n"
            + "\(apk): 1 file pushed, 0 skipped. 38.1 MB/s (2154321 bytes in 0.054s)\n"
        for newline in ["\n", "\r\n"] {
            let echo = "\tpkg: /data/local/tmp/error-reporter.apk" + newline
            let succeeded = try makeTool(stdoutText: pushed + echo + "Success" + newline)
            try await succeeded.adbClient.install(serial: "emulator-5554", apkURL: URL(fileURLWithPath: apk))

            for verdict in [
                "Failure [INSTALL_FAILED_OLDER_SDK]",
                "Error: Could not access the Package Manager.  Is the system running?",
            ] {
                let refused = try makeTool(stdoutText: pushed + echo + verdict + newline)
                do {
                    try await refused.adbClient.install(serial: "emulator-5554", apkURL: URL(fileURLWithPath: apk))
                    XCTFail("\(verdict) must fail the install")
                } catch AdbError.commandFailed(_, let exitCode, let message) {
                    XCTAssertEqual(exitCode, 0)
                    XCTAssertTrue(message.hasSuffix(verdict), message)
                }
            }
        }

        // Newer adb clients keep the push summary off stdout.
        XCTAssertFalse(AdbClient.installFailed(
            exitCode: 0,
            standardOutput: "Performing Push Install\n\tpkg: /data/local/tmp/error-reporter.apk\nSuccess\n"
        ))
        // A streamed install's success, and any failing exit.
        XCTAssertFalse(AdbClient.installFailed(exitCode: 0, standardOutput: "Performing Streamed Install\nSuccess\n"))
        XCTAssertTrue(AdbClient.installFailed(exitCode: 1, standardOutput: "Performing Streamed Install\n"))
    }

    // MARK: - Activity manager (SOURCE-DERIVED)

    /// SOURCE-DERIVED: `am start -a android.settings.APPLICATION_DETAILS_SETTINGS
    /// -d package:<id>` (`AdbClient.openAppInfo`) is not run against the
    /// shared emulator — it opens Settings. `ActivityManagerShellCommand`
    /// echoes `Starting: <intent>` on stdout, and `Intent.toString()` shows
    /// the data through `Uri.toSafeString()`, which keeps the whole
    /// `package:<id>` on Android 13 and older; this API 37 image redacts it
    /// to `dat=package:` (its logcat prints `Intent { act=…PACKAGE_CHANGED
    /// dat=package: … }`). Failures are separate lines starting `Error`.
    func testOpenAppInfoReadsFailuresFromErrorLinesOnly() async throws {
        let olderEcho = "Starting: Intent { act=android.settings.APPLICATION_DETAILS_SETTINGS "
            + "dat=package:com.example.errorreporter }\n"
        let older = try makeTool(stdoutText: olderEcho)
        try await older.adbClient.openAppInfo(serial: "emulator-5554", package: "com.example.errorreporter")

        let modernEcho = "Starting: Intent { act=android.settings.APPLICATION_DETAILS_SETTINGS dat=package: }\n"
        let modern = try makeTool(stdoutText: modernEcho)
        try await modern.adbClient.openAppInfo(serial: "emulator-5554", package: "com.example.errorreporter")

        let unresolved = "Error: Activity not started, unable to resolve Intent { "
            + "act=android.settings.APPLICATION_DETAILS_SETTINGS dat=package:com.example.app flg=0x10000000 }\n"
        // Older images exit 0 after printing the error; newer ones exit 1.
        for exitCode: Int32 in [0, 1] {
            let failing = try makeTool(stdoutText: olderEcho, stderrText: unresolved, exitCode: exitCode)
            do {
                try await failing.adbClient.openAppInfo(serial: "emulator-5554", package: "com.example.app")
                XCTFail("an unresolved intent must throw (exit \(exitCode))")
            } catch AdbError.commandFailed(_, _, let message) {
                XCTAssertTrue(message.contains("unable to resolve"), message)
            }
        }

        XCTAssertTrue(AdbClient.activityStartFailed(
            "Starting: Intent { cmp=com.example/.Missing }\nError type 3\n"
                + "Error: Activity class {com.example/com.example.Missing} does not exist.\n"
        ))
        XCTAssertFalse(AdbClient.activityStartFailed(
            olderEcho + "Warning: Activity not started, its current task has been brought to the front\n"
        ))
    }

    // MARK: - screenrecord

    /// `adb shell screenrecord --help` prints its usage on stderr (stdout
    /// empty, exit 0). The `--time-limit` help wraps, but "remove the time
    /// limit" stays on one line — which the device-side `grep -q` in
    /// `screenRecordCommand` needs.
    func testScreenrecordHelpOffersNoTimeLimit() async throws {
        let adb = try makeTool(
            stdout: "shell-screenrecord-help.stdout.txt",
            stderr: "shell-screenrecord-help.stderr.txt"
        )
        let unlimited = await adb.adbClient.screenRecordHasNoTimeLimit(serial: "emulator-5554")
        XCTAssertTrue(unlimited)

        let help = try Self.text("shell-screenrecord-help.stderr.txt")
        XCTAssertTrue(help.split(separator: "\n").contains { $0.contains("remove the time limit") })
        XCTAssertTrue(try Self.text("shell-screenrecord-help.stdout.txt").isEmpty)
    }
}


/// A stand-in for an external tool that replays a capture: the fixture's
/// stdout and stderr bytes, then its exit code, whatever the arguments.
struct AdbCoreFixtureTool {
    let executableURL: URL

    var adbClient: AdbClient { AdbClient(adbURL: executableURL) }
}

extension AdbCoreFixtureTests {
    /// A replaying tool for the named fixtures, removed after the test.
    func makeTool(stdout: String? = nil, stderr: String? = nil, exitCode: Int32 = 0) throws -> AdbCoreFixtureTool {
        try makeTool(
            stdoutPath: stdout.map { Self.url($0).path },
            stderrPath: stderr.map { Self.url($0).path },
            exitCode: exitCode
        )
    }

    /// A replaying tool for output that could not be captured live
    /// (SOURCE-DERIVED tests), removed after the test.
    func makeTool(
        stdoutText: String,
        stderrText: String? = nil,
        exitCode: Int32 = 0
    ) throws -> AdbCoreFixtureTool {
        let directory = try makeToolDirectory()
        let stdoutURL = directory.appendingPathComponent("stdout.txt")
        try Data(stdoutText.utf8).write(to: stdoutURL)
        var stderrPath: String?
        if let stderrText {
            let stderrURL = directory.appendingPathComponent("stderr.txt")
            try Data(stderrText.utf8).write(to: stderrURL)
            stderrPath = stderrURL.path
        }
        return try writeTool(in: directory, stdoutPath: stdoutURL.path, stderrPath: stderrPath, exitCode: exitCode)
    }

    /// A tool that answers any run whose arguments include `argument` with
    /// `stdoutText` and `exitCode`, and every other run with the fixture
    /// `otherwise` and exit 0. `runs()` lists each run's arguments.
    func makeTool(
        whenArgument argument: String,
        stdoutText: String,
        exitCode: Int32,
        otherwise fixture: String
    ) throws -> (tool: AdbCoreFixtureTool, runs: () throws -> [String]) {
        let directory = try makeToolDirectory()
        let answerURL = directory.appendingPathComponent("answer.txt")
        try Data(stdoutText.utf8).write(to: answerURL)
        let logURL = directory.appendingPathComponent("runs.log")
        let script = [
            "#!/bin/sh",
            "echo \"$*\" >> '\(logURL.path)'",
            "for argument in \"$@\"; do",
            "  if [ \"$argument\" = '\(argument)' ]; then",
            "    cat '\(answerURL.path)'",
            "    exit \(exitCode)",
            "  fi",
            "done",
            "cat '\(Self.url(fixture).path)'",
            "exit 0",
        ]
        let url = directory.appendingPathComponent("tool")
        try Data((script.joined(separator: "\n") + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        let runs = {
            try String(contentsOf: logURL, encoding: .utf8).split(separator: "\n").map(String.init)
        }
        return (AdbCoreFixtureTool(executableURL: url), runs)
    }

    private func makeTool(stdoutPath: String?, stderrPath: String?, exitCode: Int32) throws -> AdbCoreFixtureTool {
        try writeTool(in: makeToolDirectory(), stdoutPath: stdoutPath, stderrPath: stderrPath, exitCode: exitCode)
    }

    private func makeToolDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AdbCoreFixtureTool-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func writeTool(
        in directory: URL,
        stdoutPath: String?,
        stderrPath: String?,
        exitCode: Int32
    ) throws -> AdbCoreFixtureTool {
        var lines = ["#!/bin/sh"]
        if let stdoutPath {
            lines.append("cat '\(stdoutPath)'")
        }
        if let stderrPath {
            lines.append("cat '\(stderrPath)' >&2")
        }
        lines.append("exit \(exitCode)")
        let url = directory.appendingPathComponent("tool")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return AdbCoreFixtureTool(executableURL: url)
    }
}
