import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// What the Controls panel's writes call, under the names the rows use.
@MainActor
protocol ControlsWriting: AnyObject {
    var controls: DeviceControlsState { get set }
    var deviceSettings: DeviceSettingsState { get set }
    func refreshControls() async
    func toggleBatterySaver() async
    func toggleAirplaneMode() async
    func toggleWifi() async
    func toggleBluetooth() async
    func toggleMobileData() async
    func setDataSaver(_ enabled: Bool) async
    func setToggle(_ toggle: DeviceToggle, enabled: Bool) async
    func setAppearance(_ mode: AppearanceMode) async
    func setTextSize(_ step: FontScaleStep) async
    func setReduceMotion(_ enabled: Bool) async
    func setIncreaseContrast(_ enabled: Bool) async
    func setShowBorders(_ enabled: Bool) async
    func setTalkBack(_ enabled: Bool) async
    func setMediaVolume(_ index: Int) async
    func setMediaVolumeLive(_ index: Int)
}

extension DeviceControlsController: ControlsWriting {}

/// Both halves of the panel's state, so one key path names any row.
struct PanelRows {
    var controls: DeviceControlsState
    var deviceSettings: DeviceSettingsState
}

extension ControlsWriting {
    var rows: PanelRows {
        get { PanelRows(controls: controls, deviceSettings: deviceSettings) }
        set {
            controls = newValue.controls
            deviceSettings = newValue.deviceSettings
        }
    }
}

/// The Controls writes as one golden table, one row per write: the 13
/// settings writes and the media-volume commit. Each row is driven twice
/// over a stub adb, on a mirrored phone (no gRPC port), through the model's
/// names and on a bare `DeviceControlsController`:
///
/// - Once with every write command answering, the row's first command
///   held until the test releases it: the optimistic value shows while the
///   write is out, the fence is up, and a poll run meanwhile reads no
///   setting and keeps the optimistic value. Once released, the fence is
///   down, the status line shows the row's exact flash (none for the five
///   network toggles) and the reconcile's read-back stands.
/// - Once with no write command answering: the row rolls back to its
///   previous value, the error names the failed command, nothing flashes
///   and the fence is down.
///
/// Then the media-volume fallback: an absolute write the device ignores is
/// walked with the volume keys, one it takes is not. And the Sound knob's
/// live stepping: a commit or the teardown cancels it, and a worker stopped
/// mid-press never writes the applied index.
///
/// The stub answers the reads with the API 37 emulator's captures under
/// `DeviceHubProKitTests/Fixtures/api37-emulator/controls`, byte-exact; the
/// writes answer with nothing (exit 0), or fail with no output. Each row's
/// seeded value is the opposite of what the capture reports, so every
/// write asks for the captured state and its reconcile settles on the
/// first read-back. The capture never moves, so the volume row, whose
/// target differs from the captured index, ends on the captured index.
@MainActor
final class ControlsWriteTests: XCTestCase {
    private static let phone = AndroidDevice.online("HT4CWJT0000A", model: "Pixel A")
    private static let serial = phone.serial
    private static let talkBack = "com.google.android.marvin.talkback"

    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("DeviceHubProKitTests/Fixtures/api37-emulator/controls")

    // MARK: Table

    enum Stage: String {
        case previous, optimistic, settled
    }

    struct WriteRow {
        let name: String
        /// The write's adb command the stub holds until the test releases it.
        let held: String
        /// The status line after a successful write; nil for none.
        let flash: String?
        /// The command whose failure the error names when no write answers.
        let failure: String
        let seed: @MainActor (any ControlsWriting) -> Void
        let assertShows: @MainActor (any ControlsWriting, Stage, String) -> Void
        let write: @MainActor (any ControlsWriting) async -> Void

        @MainActor
        static func row<Value: Equatable>(
            _ name: String,
            _ path: WritableKeyPath<PanelRows, Value>,
            previous: Value,
            optimistic: Value,
            settled: Value,
            held: String,
            flash: String?,
            failure: String,
            also: @escaping @MainActor (inout PanelRows) -> Void = { _ in },
            write: @escaping @MainActor (any ControlsWriting) async -> Void
        ) -> WriteRow {
            WriteRow(
                name: name,
                held: held,
                flash: flash,
                failure: failure,
                seed: { target in
                    var rows = target.rows
                    rows[keyPath: path] = previous
                    also(&rows)
                    target.rows = rows
                },
                assertShows: { target, stage, context in
                    let expected: Value
                    switch stage {
                    case .previous: expected = previous
                    case .optimistic: expected = optimistic
                    case .settled: expected = settled
                    }
                    XCTAssertEqual(target.rows[keyPath: path], expected, "\(name): \(stage.rawValue) value \(context)")
                },
                write: write
            )
        }
    }

    private var table: [WriteRow] {
        [
            .row(
                "toggleBatterySaver", \.controls.batterySaverEnabled,
                previous: true, optimistic: false, settled: false,
                held: "cmd power set-mode 0", flash: nil,
                failure: "settings put global low_power 0"
            ) { await $0.toggleBatterySaver() },
            .row(
                "toggleAirplaneMode", \.controls.airplaneModeEnabled,
                previous: true, optimistic: false, settled: false,
                held: "cmd connectivity airplane-mode disable", flash: nil,
                failure: "cmd connectivity airplane-mode disable"
            ) { await $0.toggleAirplaneMode() },
            .row(
                "toggleWifi", \.controls.wifiEnabled,
                previous: false, optimistic: true, settled: true,
                held: "svc wifi enable", flash: nil,
                failure: "svc wifi enable"
            ) { await $0.toggleWifi() },
            .row(
                "toggleBluetooth", \.controls.bluetoothEnabled,
                previous: false, optimistic: true, settled: true,
                held: "svc bluetooth enable", flash: nil,
                failure: "cmd bluetooth_manager enable"
            ) { await $0.toggleBluetooth() },
            .row(
                "toggleMobileData", \.controls.mobileDataEnabled,
                previous: true, optimistic: false, settled: false,
                held: "svc data disable", flash: nil,
                failure: "svc data disable"
            ) { await $0.toggleMobileData() },
            .row(
                "setDataSaver", \.controls.dataSaverEnabled,
                previous: true, optimistic: false, settled: false,
                held: "cmd netpolicy set restrict-background false", flash: "Data Saver turned off",
                failure: "cmd netpolicy set restrict-background false"
            ) { await $0.setDataSaver(false) },
            .row(
                "setToggle", \.deviceSettings.showTaps,
                previous: .off, optimistic: .on, settled: .on,
                held: "settings put system show_touches 1", flash: "Show taps turned on",
                failure: "settings put system show_touches 1"
            ) { await $0.setToggle(.showTaps, enabled: true) },
            .row(
                "setAppearance", \.controls.appearance,
                previous: .mode(.light), optimistic: .mode(.dark), settled: .mode(.dark),
                held: "cmd uimode night yes", flash: "Appearance set to Dark",
                failure: "cmd uimode night yes"
            ) { await $0.setAppearance(.dark) },
            .row(
                "setTextSize", \.deviceSettings.fontScale,
                previous: .value(1.0), optimistic: .value(1.3), settled: .value(1.3),
                held: "settings put system font_scale 1.3", flash: "Text size set to Largest",
                failure: "settings put system font_scale 1.3"
            ) { await $0.setTextSize(.largest) },
            .row(
                "setReduceMotion", \.deviceSettings.reduceMotion,
                previous: .enabled, optimistic: .disabled, settled: .disabled,
                held: "settings put global window_animation_scale 1.0", flash: "Reduce Motion turned off",
                failure: "settings put global window_animation_scale 1.0"
            ) { await $0.setReduceMotion(false) },
            .row(
                "setIncreaseContrast", \.deviceSettings.increaseContrast,
                previous: .on, optimistic: .off, settled: .off,
                held: "settings put secure high_text_contrast_enabled 0", flash: "Increase Contrast turned off",
                failure: "settings put secure high_text_contrast_enabled 0"
            ) { await $0.setIncreaseContrast(false) },
            .row(
                "setShowBorders", \.deviceSettings.showBorders,
                previous: .on, optimistic: .off, settled: .off,
                held: "setprop debug.layout false", flash: "Show Borders turned off",
                failure: "setprop debug.layout false"
            ) { await $0.setShowBorders(false) },
            .row(
                "setTalkBack", \.deviceSettings.voiceOver,
                previous: .on, optimistic: .off, settled: .off,
                held: "settings put secure accessibility_enabled 0", flash: "TalkBack turned off",
                failure: "settings get secure enabled_accessibility_services",
                also: { $0.deviceSettings.talkBackPackage = Self.talkBack }
            ) { await $0.setTalkBack(false) },
            .row(
                "setMediaVolume", \.deviceSettings.mediaVolume,
                previous: MediaVolumeReading(index: 3, minimum: 0, maximum: 15),
                optimistic: MediaVolumeReading(index: 7, minimum: 0, maximum: 15),
                settled: MediaVolumeReading(index: 15, minimum: 0, maximum: 15),
                held: "cmd media_session volume --stream 3 --set 7", flash: "Volume set to 7",
                failure: "input keyevent 25"
            ) { await $0.setMediaVolume(7) },
        ]
    }

    // MARK: Benches

    /// A write target on a stub adb, with the status line and the fence it
    /// reports through.
    struct WriteBench {
        let target: any ControlsWriting
        let status: StatusCenter
        let panel: DeviceControlsController
        let adb: StubAdb
        let finish: @MainActor () -> Void
    }

    /// The model, mirroring `phone` over a stub adb with `arms`.
    private func modelBench(arms: String) async throws -> WriteBench {
        let adb = try makeStubAdb(arms: arms)
        let model = AppModel.testing(adb: adb.client)
        model.workspace.mirror.sessionFactoryOverride = { _, _ in FakeMirrorSession() }
        model.inventory.applyWatcherSnapshot([Self.phone], degraded: false)
        await model.mirror(device: Self.phone)
        XCTAssertEqual(model.activeDeviceSerial, Self.serial)
        // `controlsPanel` is per-device: its writes land
        // on the workspace's own center, not the app-global `model.status`.
        model.workspace.status.clear()
        return WriteBench(
            target: model.controlsPanel,
            status: model.workspace.status,
            panel: model.controlsPanel,
            adb: adb,
            finish: { model.stopMirror() }
        )
    }

    /// A bare panel whose context mirrors `phone`, over a stub adb with
    /// `arms`.
    private func panelBench(arms: String) throws -> WriteBench {
        let adb = try makeStubAdb(arms: arms)
        let context = ActiveDeviceContext()
        context.serial = Self.serial
        let status = StatusCenter()
        let panel = DeviceControlsController(adbClient: adb.client, context: context, status: status)
        return WriteBench(target: panel, status: status, panel: panel, adb: adb, finish: {})
    }

    // MARK: Stub arms

    private static func fixture(_ name: String) -> String {
        AdbClient.shellQuoted(fixtures.appendingPathComponent(name).path)
    }

    /// Every read the poll and the reconciles make, answered with its
    /// capture. The legacy `media volume` binary is missing on API 37
    /// (`media-volume-stream-3-get.stderr.txt`), so it has no arm.
    private static var readArms: String {
        let serial = Self.serial
        return """
          "-s \(serial) shell settings list global")
            cat \(fixture("settings-list-global.txt")) ;;
          "-s \(serial) shell settings list system")
            cat \(fixture("settings-list-system.txt")) ;;
          "-s \(serial) shell settings list secure")
            cat \(fixture("settings-list-secure.txt")) ;;
          "-s \(serial) shell cmd media_session volume --stream 3 --get")
            cat \(fixture("cmd-media_session-volume-stream-3-get.txt")) ;;
          "-s \(serial) shell cmd uimode night")
            cat \(fixture("cmd-uimode-night.txt")) ;;
          "-s \(serial) shell cmd netpolicy get restrict-background")
            cat \(fixture("cmd-netpolicy-get-restrict-background.txt")) ;;
          "-s \(serial) shell pm list packages")
            cat \(fixture("pm-list-packages.txt")) ;;
          "-s \(serial) shell sdk="*"@@devicehubpro:wifi-verbose-dump"*)
            cat \(fixture("device-effects-probe-slow.txt")) ;;
          "-s \(serial) shell sdk="*)
            cat \(fixture("device-effects-probe.txt")) ;;
        """
    }

    /// Every write command the rows send, answering with nothing.
    private static var writeArms: String {
        let serial = Self.serial
        return """
          "-s \(serial) shell settings get secure enabled_accessibility_services")
            cat \(fixture("settings-get/secure-enabled_accessibility_services.txt")) ;;
          "-s \(serial) shell settings put "*|"-s \(serial) shell settings delete "*)
            ;;
          "-s \(serial) shell svc "*|"-s \(serial) shell setprop "*|"-s \(serial) shell service call activity "*)
            ;;
          "-s \(serial) shell cmd connectivity airplane-mode "*|"-s \(serial) shell cmd power set-mode "*)
            ;;
          "-s \(serial) shell cmd netpolicy set "*|"-s \(serial) shell cmd uimode night "*)
            ;;
          "-s \(serial) shell cmd media_session volume --stream 3 --set "*|"-s \(serial) shell input keyevent "*)
            ;;
        """
    }

    /// Holds `command` until `gate` exists.
    private static func heldArm(_ command: String, until gate: URL) -> String {
        """
          "-s \(Self.serial) shell \(command)")
            while [ ! -f \(AdbClient.shellQuoted(gate.path)) ]; do sleep 0.02; done ;;
        """
    }

    /// The poll's settings reads in the stub's log so far.
    private static func pollReads(_ adb: StubAdb) -> Int {
        adb.calls.filter { call in
            ["settings list", "pm list packages", "volume --stream 3 --get", "cmd netpolicy get", "sdk="]
                .contains { call.contains($0) }
                || call.hasSuffix("shell cmd uimode night")
        }.count
    }

    private func gateURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ControlsWrite-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("release")
    }

    // MARK: The table

    func testEveryWriteOnTheModel() async throws {
        try await runTable { arms in try await self.modelBench(arms: arms) }
    }

    func testEveryWriteOnTheController() async throws {
        try await runTable { arms in try self.panelBench(arms: arms) }
    }

    private func runTable(bench make: (String) async throws -> WriteBench) async throws {
        XCTAssertEqual(table.count, 14, "the 13 settings writes and the volume commit")
        for row in table {
            try await runSuccess(row, bench: make)
            try await runFailure(row, bench: make)
        }
    }

    /// The write goes through: optimistic while out, fenced, flashed,
    /// reconciled.
    private func runSuccess(_ row: WriteRow, bench make: (String) async throws -> WriteBench) async throws {
        let gate = try gateURL()
        let bench = try await make(Self.heldArm(row.held, until: gate) + "\n" + Self.writeArms + "\n" + Self.readArms)
        defer { bench.finish() }
        row.seed(bench.target)
        row.assertShows(bench.target, .previous, "before the write")

        let write = Task { await row.write(bench.target) }
        await waitUntil("\(row.name): the write never reached `\(row.held)`") {
            !bench.adb.calls(containing: "shell \(row.held)").isEmpty
        }
        row.assertShows(bench.target, .optimistic, "while the write is out")
        XCTAssertEqual(bench.panel.writeFence.depth, 1, "\(row.name): the fence is up")

        let readsBefore = Self.pollReads(bench.adb)
        await bench.target.refreshControls()
        XCTAssertEqual(Self.pollReads(bench.adb), readsBefore, "\(row.name): a poll during the write reads no setting")
        row.assertShows(bench.target, .optimistic, "after a poll during the write")

        FileManager.default.createFile(atPath: gate.path, contents: nil)
        await write.value

        XCTAssertEqual(bench.panel.writeFence.depth, 0, "\(row.name): the fence is down")
        XCTAssertNil(bench.status.errorMessage, "\(row.name)")
        XCTAssertEqual(bench.status.statusMessage, row.flash, "\(row.name): flash")
        row.assertShows(bench.target, .settled, "after the reconcile")
    }

    /// No write command answers: the row rolls back and the error names
    /// the command.
    private func runFailure(_ row: WriteRow, bench make: (String) async throws -> WriteBench) async throws {
        let bench = try await make(Self.readArms)
        defer { bench.finish() }
        row.seed(bench.target)

        await row.write(bench.target)

        row.assertShows(bench.target, .previous, "after a failed write")
        let error = bench.status.errorMessage ?? ""
        XCTAssertTrue(error.contains("shell \(row.failure) failed"), "\(row.name): \(error)")
        XCTAssertNil(bench.status.statusMessage, "\(row.name): a failed write flashes nothing")
        XCTAssertEqual(bench.panel.writeFence.depth, 0, "\(row.name): the fence is down")
    }

    // MARK: Media volume fallback

    /// Current images ignore the absolute volume write (it exits 0 and the
    /// index stays): after two read-backs that still differ, the commit
    /// reads where the device is and walks the rest with the volume keys,
    /// then reads it back. The Kit's own write already stepped once, so the
    /// keys go out twice over a device that never moves.
    func testIgnoredAbsoluteVolumeWriteFallsBackToKeySteps() async throws {
        let bench = try await modelBench(arms: Self.writeArms + "\n" + Self.readArms)
        defer { bench.finish() }
        bench.target.deviceSettings.mediaVolume = MediaVolumeReading(index: 15, minimum: 0, maximum: 15)

        await bench.target.setMediaVolume(12)

        let volumeCalls = bench.adb.calls.filter { $0.contains("input keyevent") || $0.contains("volume --stream 3") }
        let keys = volumeCalls.indices.filter { volumeCalls[$0].hasSuffix("input keyevent 25") }
        XCTAssertEqual(keys.count, 6, "\(volumeCalls)")
        XCTAssertTrue(bench.adb.calls(containing: "input keyevent 24").isEmpty)
        let reads = { (range: Range<Int>) in
            volumeCalls[range].filter { $0.hasSuffix("cmd media_session volume --stream 3 --get") }.count
        }
        if keys.count == 6 {
            XCTAssertEqual(
                reads(keys[2]..<keys[3]), 3,
                "two read-backs and the read the steps start from: \(volumeCalls)"
            )
            XCTAssertEqual(reads(keys[5]..<volumeCalls.endIndex), 1, "the steps' read-back: \(volumeCalls)")
        }
        XCTAssertEqual(bench.target.deviceSettings.mediaVolume, MediaVolumeReading(index: 15, minimum: 0, maximum: 15))
        XCTAssertEqual(bench.status.statusMessage, "Volume set to 12")
        XCTAssertEqual(bench.panel.writeFence.depth, 0)
    }

    /// A write the device takes sends no key.
    func testTakenAbsoluteVolumeWriteSendsNoKey() async throws {
        let bench = try await modelBench(arms: Self.writeArms + "\n" + Self.readArms)
        defer { bench.finish() }
        bench.target.deviceSettings.mediaVolume = MediaVolumeReading(index: 3, minimum: 0, maximum: 15)

        await bench.target.setMediaVolume(15)

        XCTAssertTrue(bench.adb.calls(containing: "input keyevent").isEmpty, "\(bench.adb.calls)")
        XCTAssertEqual(
            bench.adb.calls(containing: "cmd media_session volume --stream 3 --get").count, 2,
            "the Kit's check and one read-back"
        )
        XCTAssertEqual(bench.target.deviceSettings.mediaVolume, MediaVolumeReading(index: 15, minimum: 0, maximum: 15))
        XCTAssertEqual(bench.status.statusMessage, "Volume set to 15")
    }

    // MARK: Live volume

    /// A drag from 5 to 8 on a bench whose volume-up presses the stub
    /// holds: the knob shows 8 at once, and the worker starts from 5 and is
    /// out on its first press when this returns.
    private func dragUp(_ bench: WriteBench) async throws -> Task<Void, Never> {
        bench.target.deviceSettings.mediaVolume = MediaVolumeReading(index: 5, minimum: 0, maximum: 15)
        bench.target.setMediaVolumeLive(8)
        XCTAssertEqual(bench.target.deviceSettings.mediaVolume?.index, 8, "the knob shows the drag at once")
        XCTAssertEqual(bench.panel.volumeAppliedIndex, 5)
        XCTAssertEqual(bench.panel.volumeTarget, 8)
        let worker = try XCTUnwrap(bench.panel.volumeStepTask)
        await waitUntil("the live worker never pressed volume up") {
            !bench.adb.calls(containing: "input keyevent 24").isEmpty
        }
        return worker
    }

    private func assertLiveSteppingStopped(_ panel: DeviceControlsController, _ context: String) {
        XCTAssertNil(panel.volumeStepTask, context)
        XCTAssertNil(panel.volumeTarget, context)
        XCTAssertNil(panel.volumeAppliedIndex, context)
    }

    /// Committing the drag cancels its live stepping before the absolute
    /// write: the worker, the target and the applied index are gone, and
    /// the press that was out when the commit started is the worker's last
    /// (the commit itself only steps down, from the captured 15).
    func testCommitCancelsLiveStepping() async throws {
        let gate = try gateURL()
        let bench = try panelBench(
            arms: Self.heldArm("input keyevent 24", until: gate) + "\n" + Self.writeArms + "\n" + Self.readArms
        )
        let worker = try await dragUp(bench)

        await bench.target.setMediaVolume(8)

        assertLiveSteppingStopped(bench.panel, "after the commit")
        XCTAssertEqual(bench.status.statusMessage, "Volume set to 8")
        FileManager.default.createFile(atPath: gate.path, contents: nil)
        await worker.value
        XCTAssertEqual(bench.adb.calls(containing: "input keyevent 24").count, 1, "\(bench.adb.calls)")
        assertLiveSteppingStopped(bench.panel, "after the cancelled press returned")
    }

    /// A worker stopped while its press is out (the teardown hub's
    /// stopLiveVolumeStepping) never writes the applied index when the
    /// press returns, so the next drag seeds it afresh from the knob.
    func testStoppedStepperNeverWritesTheAppliedIndex() async throws {
        let gate = try gateURL()
        let bench = try panelBench(
            arms: Self.heldArm("input keyevent 24", until: gate) + "\n" + Self.writeArms + "\n" + Self.readArms
        )
        let worker = try await dragUp(bench)

        bench.panel.stopLiveVolumeStepping()
        FileManager.default.createFile(atPath: gate.path, contents: nil)
        await worker.value

        assertLiveSteppingStopped(bench.panel, "the stale press must not count for the next drag")
        XCTAssertEqual(bench.adb.calls(containing: "input keyevent 24").count, 1)

        bench.target.setMediaVolumeLive(6)
        XCTAssertEqual(bench.panel.volumeAppliedIndex, 8, "seeded from the knob, not from the stale worker")
        await waitUntil("the next drag's worker never ran out") { bench.panel.volumeStepTask == nil }
        XCTAssertEqual(bench.panel.volumeAppliedIndex, 6)
        XCTAssertEqual(bench.adb.calls(containing: "input keyevent 25").count, 2, "\(bench.adb.calls)")
    }

    /// The teardown hub stops the live stepping through the model's
    /// stopLiveVolumeStepping helper.
    func testTeardownStopsLiveStepping() async throws {
        let gate = try gateURL()
        let bench = try await modelBench(
            arms: Self.heldArm("input keyevent 24", until: gate) + "\n" + Self.writeArms + "\n" + Self.readArms
        )
        let worker = try await dragUp(bench)

        bench.finish()

        assertLiveSteppingStopped(bench.panel, "after the teardown")
        FileManager.default.createFile(atPath: gate.path, contents: nil)
        await worker.value
        XCTAssertEqual(bench.adb.calls(containing: "input keyevent 24").count, 1, "\(bench.adb.calls)")
        assertLiveSteppingStopped(bench.panel, "after the cancelled press returned")
    }
}
