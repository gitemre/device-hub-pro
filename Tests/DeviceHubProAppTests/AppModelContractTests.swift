import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// Characterization of the `AppModel` surface the model split moves: what
/// an emulator session start sets up, what a teardown resets and what it
/// deliberately keeps, where a recording goes for each teardown cause, how
/// a failed settings write rolls back, and the status line's "clear only
/// your own line" rules. These pin today's behaviour, so every extraction
/// step can show it changed nothing.
///
/// Emulator paths only, over `FakeMirrorSession` and a stub adb: the gRPC
/// ports come from discovery files the stub names, each the test's own
/// listener (so no real emulator can serve them), and no command reaches a
/// real device.
@MainActor
final class AppModelContractTests: XCTestCase {
    private let emulator = AndroidDevice.online("emulator-5570", transport: "31")
    private let otherEmulator = AndroidDevice.online("emulator-5572", transport: "32")
    private static let avdName = "DeviceHubPro_Contract_AVD"
    private static let otherAvdName = "DeviceHubPro_Contract_AVD_2"

    /// What the model built and handed out: the fake sessions by serial,
    /// the ports they were built for, and the clips given to the save flow.
    /// `port` and `otherPort` are the two emulators' discovery-file ports.
    private final class Harness {
        let adb: StubAdb
        let autoSaveDirectory: URL
        let port: Int
        let otherPort: Int
        var sessions: [String: FakeMirrorSession] = [:]
        var ports: [Int?] = []
        var saved: [(url: URL, name: String)] = []

        init(adb: StubAdb, autoSaveDirectory: URL, port: Int, otherPort: Int) {
            self.adb = adb
            self.autoSaveDirectory = autoSaveDirectory
            self.port = port
            self.otherPort = otherPort
        }

        var autoSavedClips: [URL] {
            (try? FileManager.default.contentsOfDirectory(
                at: autoSaveDirectory,
                includingPropertiesForKeys: nil
            )) ?? []
        }
    }

    /// A model with both emulators online. Their consoles answer the attach
    /// (discovery file, AVD name) and the session start's `resize-display`
    /// read; `extraArms` are matched first. Recordings never reach a save
    /// panel or the Desktop: the save flow is the harness's, and auto-saves
    /// land in a scratch directory.
    private func makeModel(extraArms: String = "") throws -> (AppModel, Harness) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppModelContract-\(UUID().uuidString)", isDirectory: true)
        let autoSave = directory.appendingPathComponent("AutoSave", isDirectory: true)
        try FileManager.default.createDirectory(at: autoSave, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let discovery = directory.appendingPathComponent("discovery-5570.ini")
        let otherDiscovery = directory.appendingPathComponent("discovery-5572.ini")
        let port = try makeOwnedGrpcPort()
        let otherPort = try makeOwnedGrpcPort()
        try Data("grpc.port=\(port)\n".utf8).write(to: discovery)
        try Data("grpc.port=\(otherPort)\n".utf8).write(to: otherDiscovery)

        let adb = try makeStubAdb(arms: """
        \(extraArms)
          "-s emulator-5570 emu avd discoverypath")
            printf '%s\\r\\nOK\\r\\n' "\(discovery.path)" ;;
          "-s emulator-5572 emu avd discoverypath")
            printf '%s\\r\\nOK\\r\\n' "\(otherDiscovery.path)" ;;
          "-s emulator-5570 emu avd name")
            printf '\(Self.avdName)\\r\\nOK\\r\\n' ;;
          "-s emulator-5572 emu avd name")
            printf '\(Self.otherAvdName)\\r\\nOK\\r\\n' ;;
          "-s emulator-5570 emu resize-display"|"-s emulator-5572 emu resize-display")
            printf 'KO usage: "resize-display <index>" 0: phone\\t1: unfolded\\t2: tablet\\r\\n' ;;
        """)

        let harness = Harness(adb: adb, autoSaveDirectory: autoSave, port: port, otherPort: otherPort)
        let model = AppModel.testing(adb: adb.client)
        pinSessionSettings(of: model)
        // Both AVDs have a resizable display, so each session start reads
        // the presets (MirrorAttachTests covers the AVDs that do not).
        model.workspace.hardware.isResizableAvd = { [Self.avdName, Self.otherAvdName].contains($0) }
        model.workspace.mirror.sessionFactoryOverride = { serial, port in
            let session = FakeMirrorSession()
            harness.sessions[serial] = session
            harness.ports.append(port)
            return session
        }
        model.recordingFinalizer.recordingSaveOverride = { url, name in
            harness.saved.append((url, name))
        }
        model.recordingFinalizer.recordingAutoSaveDirectory = autoSave
        addTeardownBlock { @MainActor in
            for clip in harness.saved {
                try? FileManager.default.removeItem(at: clip.url.deletingLastPathComponent())
            }
        }
        model.inventory.applyWatcherSnapshot([emulator, otherEmulator], degraded: false)
        return (model, harness)
    }

    /// The session start reads three persisted settings: host audio (so
    /// in-app audio stays off), the replay ring (on) and clipboard auto-sync
    /// (off, so nothing touches the Mac pasteboard). The testing model's
    /// defaults are its own and empty, so it has a fresh install's values;
    /// this pins that the contracts below run on them.
    private func pinSessionSettings(of model: AppModel) {
        XCTAssertEqual(model.preferences.emulatorAudioMode, .enabled)
        XCTAssertTrue(model.preferences.replayEnabled)
        XCTAssertFalse(model.preferences.clipboardAutoSyncEnabled)
    }

    /// New frames, one every 40 ms (the recorder paces at 30 fps).
    private func feed(_ session: FakeMirrorSession?, count: Int = 12) async throws {
        let session = try XCTUnwrap(session, "no session was built")
        for index in 0..<count {
            session.putFrame(width: 128, height: 256, shade: UInt8((index * 20) % 256))
            try await Task.sleep(for: .milliseconds(40))
        }
    }

    /// Mirrors `device` and records a few frames of it.
    private func startRecording(
        _ model: AppModel,
        _ harness: Harness,
        on device: AndroidDevice
    ) async throws {
        await model.mirror(device: device)
        XCTAssertEqual(model.activeDeviceSerial, device.serial)
        await model.workspace.media.toggleRecording()
        XCTAssertTrue(model.workspace.media.isRecording)
        try await feed(harness.sessions[device.serial])
    }

    private func assertNonEmptyClip(
        _ url: URL?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let url = try XCTUnwrap(url, "no clip was handed on", file: file, line: line)
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        XCTAssertGreaterThan(size?.intValue ?? 0, 0, file: file, line: line)
    }

    // MARK: (a) Teardown contract

    /// `stopMirror` → `tearDownMirror(.userStop)` → `cancelDeviceWork`:
    /// every piece of per-session state is reset, every per-device worker is
    /// cancelled, and the user's per-device drafts survive.
    ///
    /// Also reset, but not observable from here (each is pinned elsewhere or
    /// is private state with no outside effect in a stubbed run):
    /// `controlsGeneration` (ControlsPollTests' stale-poll test),
    /// `resizePresetsTask` (MirrorAttachTests' late-preset test),
    /// `lastTransportError` (only the physical transport and a failed resume
    /// set it; DeviceLifecycleCoordinatorTests pins its reset), the gRPC port
    /// cache entry, the frame feed, clipboard sync, extended-controls and
    /// stats poll tasks, `reportedMirrorError`, `pendingHingeAngle`, the live
    /// volume stepping and `primedSensor`. Also kept but private: the
    /// clipboard echo state, `physicalDeviceClipboard` and `frameFeedPending`.
    func testTeardownResetsTheSessionAndKeepsTheDeviceDrafts() async throws {
        let (model, harness) = try makeModel()
        await model.mirror(device: emulator)
        let session = try XCTUnwrap(harness.sessions[emulator.serial])
        XCTAssertEqual(harness.ports, [harness.port])
        XCTAssertEqual(model.activeDeviceSerial, emulator.serial)
        XCTAssertEqual(model.workspace.context.port, harness.port)

        // Everything the teardown resets, in a non-default state.
        await waitUntil("the session start never read the resize presets") {
            !model.workspace.hardware.resizePresets.isEmpty
        }
        model.workspace.hardware.selectedResizePreset = 1
        // A resizable AVD's session can enter resize mode (the toolbar's
        // aspect-ratio button, Device > Enter Resize Mode); the teardown
        // takes the presets, and with them the mode, away.
        XCTAssertTrue(model.workspace.canEnterResizeMode)
        model.workspace.window.toggleResizeMode()
        XCTAssertTrue(model.workspace.isInResizeMode)
        await waitUntil("the console never named the AVD") { model.activeAvdName == Self.avdName }
        await waitUntil("the stats poll never ran") { !model.workspace.mirror.statsText.isEmpty }
        model.workspace.mirror.noteEmulatorStream(isStreaming: false, lastError: "stream ended")
        model.workspace.mirror.noteCleanStatsPoll(
            serial: emulator.serial,
            stats: MirrorStats(fps: 0, totalFrames: 0, dropped: 0, averageLatencyMs: 0)
        )
        model.workspace.mirror.noteCleanStatsPoll(
            serial: emulator.serial,
            stats: MirrorStats(fps: 30, totalFrames: 5, dropped: 0, averageLatencyMs: 0)
        )
        XCTAssertEqual(model.workspace.mirror.healthGate.cleanPolls, 2)
        XCTAssertTrue(model.workspace.mirror.healthGate.reported)
        // Nothing listens on the port, so the gRPC half answers nothing.
        await model.workspace.controlsPanel.refreshControls()
        XCTAssertTrue(model.workspace.controlsPanel.controlsLoaded)
        XCTAssertEqual(model.workspace.controlsPanel.emulatorUnresponsivePolls, 1)
        model.workspace.controlsPanel.controls.wifiEnabled = true
        model.workspace.controlsPanel.controls.isBooted = true
        model.workspace.controlsPanel.controls.battery = BatteryInfo(level: 50, isCharging: true, chargerName: "AC", statusName: "Charging")
        model.workspace.controlsPanel.controls.location = GpsFix(latitude: 37.422, longitude: -122.084)
        model.workspace.controlsPanel.deviceSettings.talkBackPackage = "com.google.android.marvin.talkback"
        model.workspace.extras.sensorReadings = [.acceleration: [0, 9.8, 0]]
        model.workspace.extras.isVmPaused = true
        // The Location sheet is open and the user is typing.
        model.workspace.location.isLocationSheetPresented = true
        XCTAssertEqual(model.workspace.location.locationLatText, "37.4220")
        model.workspace.location.locationLatText = "48.8566"

        await model.workspace.media.toggleRecording()
        try await feed(session)
        await waitUntil("the replay ring never filled") { model.workspace.media.canSaveReplay }
        XCTAssertTrue(model.workspace.media.isRecording)
        XCTAssertNotNil(model.workspace.media.recordingTimerTask)

        // What the teardown deliberately keeps, in a non-default state.
        model.workspace.extras.callNumber = "5551234"
        model.workspace.extras.smsFrom = "5550000"
        model.workspace.extras.smsText = "Hello"
        model.workspace.extras.emulatorPhoneNumber = "5559876"
        model.workspace.extras.fingerprintTouchId = "3"
        model.workspace.extras.selectedSensor = .gyroscope
        model.workspace.extras.sensorDraft = ["1.000", "2.000", "3.000"]
        model.workspace.logcat.logcatSerial = emulator.serial
        let presets = model.workspace.location.locationPresets
        XCTAssertFalse(presets.isEmpty)

        // The per-device workers, started without a suspension in between
        // so none can finish on its own before the teardown.
        model.workspace.hardware.setBatteryLevel(42)
        model.workspace.hardware.setHingeAngle(90)
        model.workspace.hardware.setPostureAnimated(.opened)
        XCTAssertNotNil(model.workspace.hardware.batteryApplyTask)
        XCTAssertNotNil(model.workspace.hardware.hingeSendTask)
        XCTAssertNotNil(model.workspace.hardware.postureAnimationTask)
        let generation = model.mirrorSessionGeneration

        model.stopMirror()

        // The session and its identity.
        XCTAssertEqual(session.stopCount, 1)
        XCTAssertNil(model.workspace.mirror.session)
        XCTAssertEqual(model.mirrorSessionGeneration, generation + 1)
        XCTAssertNil(model.activeDeviceSerial)
        XCTAssertNil(model.workspace.context.port)
        XCTAssertNil(model.activeAvdName)
        XCTAssertEqual(model.workspace.context.hingeCount, 0)
        XCTAssertFalse(model.workspace.controlsPanel.canUseEmulatorControls)
        XCTAssertFalse(model.workspace.mirror.audioPlayer.isRunning)
        // Stream health.
        XCTAssertEqual(model.workspace.mirror.statsText, "")
        XCTAssertNil(model.workspace.mirror.lastTransportError)
        XCTAssertNil(model.workspace.mirror.mirrorStreamWarning)
        XCTAssertEqual(model.workspace.mirror.healthGate.cleanPolls, 0)
        XCTAssertFalse(model.workspace.mirror.healthGate.reported)
        // Controls.
        XCTAssertNil(model.workspace.controlsPanel.controls.wifiEnabled)
        XCTAssertNil(model.workspace.controlsPanel.controls.isBooted)
        XCTAssertNil(model.workspace.controlsPanel.controls.battery)
        XCTAssertNil(model.workspace.controlsPanel.controls.location)
        XCTAssertNil(model.workspace.controlsPanel.controls.hingeAngle)
        XCTAssertNil(model.workspace.controlsPanel.controls.posture)
        XCTAssertNil(model.workspace.controlsPanel.deviceSettings.talkBackPackage, "the next device must not show this one's settings rows")
        XCTAssertFalse(model.workspace.controlsPanel.showsTalkBackRow)
        XCTAssertFalse(model.workspace.controlsPanel.controlsLoaded)
        XCTAssertEqual(model.workspace.controlsPanel.emulatorUnresponsivePolls, 0)
        XCTAssertFalse(model.workspace.controlsPanel.needsRecovery)
        XCTAssertTrue(model.workspace.hardware.resizePresets.isEmpty)
        XCTAssertFalse(model.workspace.canEnterResizeMode)
        XCTAssertFalse(model.workspace.isInResizeMode)
        XCTAssertNil(model.workspace.hardware.selectedResizePreset)
        XCTAssertTrue(model.workspace.extras.sensorReadings.isEmpty)
        XCTAssertFalse(model.workspace.extras.isVmPaused)
        XCTAssertNil(model.workspace.hardware.batteryApplyTask, "a pending battery write must not land on the next device")
        XCTAssertNil(model.workspace.hardware.hingeSendTask)
        XCTAssertNil(model.workspace.hardware.postureAnimationTask)
        // Replay and recording.
        XCTAssertFalse(model.workspace.media.canSaveReplay)
        XCTAssertNil(model.workspace.media.replayBuffer)
        XCTAssertFalse(model.workspace.media.isRecording)
        XCTAssertEqual(model.workspace.media.recordingElapsedText, "")
        XCTAssertNil(model.workspace.media.recordingDeviceName)
        XCTAssertNil(model.workspace.media.recordingStartedAt)
        XCTAssertNil(model.workspace.media.recordingTimerTask)

        // The survivors.
        XCTAssertEqual(model.workspace.extras.callNumber, "5551234")
        XCTAssertEqual(model.workspace.extras.smsFrom, "5550000")
        XCTAssertEqual(model.workspace.extras.smsText, "Hello")
        XCTAssertEqual(model.workspace.extras.emulatorPhoneNumber, "5559876")
        XCTAssertEqual(model.workspace.extras.fingerprintTouchId, "3")
        XCTAssertEqual(model.workspace.extras.selectedSensor, .gyroscope)
        XCTAssertEqual(model.workspace.extras.sensorDraft, ["1.000", "2.000", "3.000"])
        XCTAssertEqual(model.workspace.location.locationPresets, presets)
        XCTAssertEqual(model.workspace.logcat.logcatSerial, emulator.serial)
        XCTAssertEqual(model.deviceSelection, .device(emulator.serial), "a teardown never moves the selection")
        XCTAssertTrue(model.workspace.location.isLocationSheetPresented)
        XCTAssertEqual(model.workspace.location.locationLatText, "48.8566", "the teardown itself leaves the draft alone")

        // ...but it hands the draft back to the device: the next fix fills
        // it even though the sheet is still open.
        model.workspace.location.primeLocationDraft(from: GpsFix(latitude: 1, longitude: 2))
        XCTAssertEqual(model.workspace.location.locationLatText, "1.0000")

        // The recording's finalization outlives the teardown.
        await waitUntil("the clip never reached the save flow") { !harness.saved.isEmpty }
        XCTAssertNil(model.status.errorMessage)
    }

    /// The TalkBack package is read once per device, and a teardown forgets
    /// which device that was: the next session on the same serial reads it
    /// again (a new VM can reuse the serial).
    func testTeardownForgetsTheTalkBackPackageRead() async throws {
        let (model, harness) = try makeModel(extraArms: """
          "-s emulator-5570 shell pm list packages")
            printf 'package:com.android.settings\\npackage:com.google.android.marvin.talkback\\n' ;;
        """)
        await model.mirror(device: emulator)
        await model.workspace.controlsPanel.refreshControls()
        await model.workspace.controlsPanel.refreshControls()
        XCTAssertEqual(harness.adb.calls(containing: "pm list packages").count, 1)

        model.stopMirror()
        await model.mirror(device: emulator)
        await model.workspace.controlsPanel.refreshControls()

        XCTAssertEqual(harness.adb.calls(containing: "pm list packages").count, 2, "\(harness.adb.calls)")
        XCTAssertEqual(model.workspace.controlsPanel.deviceSettings.talkBackPackage, "com.google.android.marvin.talkback")
        model.stopMirror()
    }

    // MARK: (b) Recording end per teardown cause

    /// The user's Stop Mirror hands the clip to the save flow.
    func testUserStopHandsTheRecordingToTheSaveFlow() async throws {
        let (model, harness) = try makeModel()
        try await startRecording(model, harness, on: emulator)

        model.stopMirror()

        XCTAssertFalse(model.workspace.media.isRecording)
        await waitUntil("the clip never reached the save flow") { !harness.saved.isEmpty }
        XCTAssertEqual(harness.saved.count, 1)
        XCTAssertTrue(harness.saved[0].name.hasPrefix("emulator-5570-"), harness.saved[0].name)
        try assertNonEmptyClip(harness.saved.first?.url)
        XCTAssertNil(model.status.errorMessage)
        XCTAssertTrue(harness.autoSavedClips.isEmpty)
    }

    /// Another session replacing the recorded one is the user's doing too.
    func testReplacedSessionHandsTheRecordingToTheSaveFlow() async throws {
        let (model, harness) = try makeModel()
        try await startRecording(model, harness, on: emulator)

        await model.mirror(device: otherEmulator)

        XCTAssertEqual(model.activeDeviceSerial, otherEmulator.serial)
        XCTAssertEqual(model.workspace.context.port, harness.otherPort)
        XCTAssertFalse(model.workspace.media.isRecording, "the next device is not being recorded")
        await waitUntil("the clip never reached the save flow") { !harness.saved.isEmpty }
        XCTAssertTrue(harness.saved[0].name.hasPrefix("emulator-5570-"), harness.saved[0].name)
        XCTAssertNil(model.status.errorMessage)
        XCTAssertTrue(harness.autoSavedClips.isEmpty)
        model.stopMirror()
    }

    /// A disconnect auto-saves what was recorded and the alert names where.
    func testDisconnectAutoSavesTheRecordingAndNamesThePath() async throws {
        let (model, harness) = try makeModel()
        try await startRecording(model, harness, on: emulator)

        model.tearDownMirror(cause: .disconnected)

        await waitUntil("the interrupted clip was not reported") { model.status.errorMessage != nil }
        let clips = harness.autoSavedClips
        XCTAssertEqual(clips.count, 1)
        let clip = try XCTUnwrap(clips.first)
        let saved = harness.autoSaveDirectory.appendingPathComponent(clip.lastPathComponent)
        XCTAssertEqual(
            model.status.errorMessage,
            "Recording of emulator-5570 stopped: emulator-5570 disconnected. The clip was saved to \(saved.path)."
        )
        try assertNonEmptyClip(clip)
        XCTAssertTrue(harness.saved.isEmpty, "no save panel for a recording the user did not stop")
    }

    /// A fatal transport is an interruption like a disconnect.
    func testTransportFatalAutoSavesTheRecordingAndNamesThePath() async throws {
        let (model, harness) = try makeModel()
        try await startRecording(model, harness, on: emulator)

        model.tearDownMirror(cause: .transportFatal)

        await waitUntil("the interrupted clip was not reported") { model.status.errorMessage != nil }
        let clip = try XCTUnwrap(harness.autoSavedClips.first)
        let saved = harness.autoSaveDirectory.appendingPathComponent(clip.lastPathComponent)
        XCTAssertEqual(
            model.status.errorMessage,
            "Recording of emulator-5570 stopped: the connection to emulator-5570 failed. The clip was saved to \(saved.path)."
        )
        XCTAssertTrue(harness.saved.isEmpty)
    }

    /// Quitting auto-saves without a word: no alert, no save panel.
    func testQuitAutoSavesTheRecordingSilently() async throws {
        let (model, harness) = try makeModel()
        try await startRecording(model, harness, on: emulator)

        model.tearDownMirror(cause: .quit)
        await model.recordingFinalizer.waitForRecordingsToFinish()

        XCTAssertEqual(harness.autoSavedClips.count, 1)
        try assertNonEmptyClip(harness.autoSavedClips.first)
        XCTAssertNil(model.status.errorMessage)
        XCTAssertTrue(harness.saved.isEmpty)
    }

    // MARK: (c) Begin contract

    /// A session on an emulator port gets the port and the console's AVD
    /// name, reads the resize presets exactly once per session start, and
    /// leaves in-app audio off while the emulator plays through the host.
    func testEmulatorSessionStart() async throws {
        let (model, harness) = try makeModel()
        let resizeReads = { harness.adb.calls(containing: "emu resize-display").count }

        await model.mirror(device: emulator)

        XCTAssertEqual(harness.ports, [harness.port], "the discovery file's port is the one mirrored")
        XCTAssertEqual(model.activeDeviceSerial, emulator.serial)
        XCTAssertEqual(model.workspace.context.port, harness.port)
        XCTAssertTrue(model.workspace.controlsPanel.canUseEmulatorControls)
        XCTAssertNil(model.workspace.mirror.mirrorAttach)
        XCTAssertEqual(model.deviceSelection, .device(emulator.serial))
        XCTAssertEqual(model.preferences.emulatorAudioMode, .enabled)
        XCTAssertFalse(model.workspace.mirror.audioPlayer.isRunning, "host audio: the app plays nothing itself")
        await waitUntil("the console never named the AVD") { model.activeAvdName == Self.avdName }
        await waitUntil("the session start never read the resize presets") { resizeReads() == 1 }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(resizeReads(), 1, "one read per session start")

        // Mirror again on the same emulator: a new session, a new read.
        let generation = model.mirrorSessionGeneration
        await model.mirror(device: emulator)
        XCTAssertEqual(harness.ports, [harness.port, harness.port])
        XCTAssertEqual(model.mirrorSessionGeneration, generation + 2, "one bump for the teardown, one for the start")
        await waitUntil("the re-attach never read the resize presets") { resizeReads() == 2 }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(resizeReads(), 2)
        XCTAssertFalse(model.workspace.mirror.audioPlayer.isRunning)

        model.stopMirror()
        XCTAssertEqual(resizeReads(), 2, "a teardown reads nothing")
    }

    // MARK: (d) Settings write rollback

    /// A failed write restores the row's previous value and raises the
    /// error; its fence is released, so the next poll applies the settings
    /// rows again.
    func testFailedSettingsWriteRollsBackAndReleasesTheFence() async throws {
        // `svc wifi disable` has no arm: the stub fails it.
        let (model, harness) = try makeModel(extraArms: """
          "-s emulator-5570 shell settings list global")
            printf 'airplane_mode_on=0\\nwifi_on=0\\n' ;;
        """)
        await model.mirror(device: emulator)
        model.workspace.controlsPanel.controls.wifiEnabled = true

        await model.workspace.controlsPanel.toggleWifi()

        XCTAssertEqual(harness.adb.calls(containing: "svc wifi disable").count, 1)
        XCTAssertEqual(model.workspace.controlsPanel.controls.wifiEnabled, true, "the failed write restores the previous value")
        let error = try XCTUnwrap(model.workspace.status.errorMessage)
        XCTAssertTrue(error.hasPrefix("adb -s emulator-5570 shell svc wifi disable failed"), error)

        await model.workspace.controlsPanel.refreshControls()

        XCTAssertEqual(model.workspace.controlsPanel.controls.wifiEnabled, false, "the poll applied the settings rows")
        XCTAssertEqual(model.workspace.controlsPanel.controls.airplaneModeEnabled, false)
        XCTAssertTrue(model.workspace.controlsPanel.controlsLoaded)
        model.stopMirror()
    }

    // MARK: (e) Status line

    /// A model that runs nothing: no session, adb and the emulator are
    /// `/usr/bin/false`.
    private func statusModel() -> AppModel {
        AppModel.testing(
            adb: AdbClient(adbURL: URL(fileURLWithPath: "/usr/bin/false")),
            emulator: .inert
        )
    }

    /// A flash clears itself after 1.8 s, but only while its own text is
    /// still shown: a newer flash or another writer's line survives it.
    func testFlashClearsOnlyItsOwnLine() async throws {
        let model = statusModel()
        let other = statusModel()
        let started = ContinuousClock.now

        model.status.flash("First")
        other.status.flash("Flashed")
        other.status.showOutcome("Working…")
        XCTAssertEqual(model.status.statusMessage, "First")
        try await Task.sleep(for: .seconds(1))
        model.status.flash("Second")
        try await Task.sleep(for: .seconds(1.2))

        XCTAssertEqual(model.status.statusMessage, "Second", "the first flash's clear must not wipe the second")
        XCTAssertEqual(other.status.statusMessage, "Working…", "a flash never clears another writer's line")
        await waitUntil(timeout: 3, "the second flash never cleared") { model.status.statusMessage == nil }
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - started, .seconds(2.7))
        XCTAssertEqual(other.status.statusMessage, "Working…")
    }

    /// `withElapsedStatus` shows its line, appends the elapsed seconds once
    /// the operation takes longer than a second, and clears only its own
    /// line — also when the operation throws.
    func testElapsedStatusClearsOnlyItsOwnLine() async throws {
        let model = statusModel()

        let value = await model.status.withElapsedStatus("Stopping A…") { () async -> Int in
            XCTAssertEqual(model.status.statusMessage, "Stopping A…")
            return 7
        }
        XCTAssertEqual(value, 7)
        XCTAssertNil(model.status.statusMessage, "its own line is cleared")

        await model.status.withElapsedStatus("Stopping B…") {
            await waitUntil(timeout: 3, "the ticker never appended the seconds") {
                model.status.statusMessage == "Stopping B… 1 s"
            }
        }
        XCTAssertNil(model.status.statusMessage, "a ticked line is still its own")

        try await model.status.withElapsedStatus("Stopping C…") {
            model.status.showOutcome("Another operation")
            try await Task.sleep(for: .milliseconds(1300))
            XCTAssertEqual(model.status.statusMessage, "Another operation", "the ticker leaves another line alone")
        }
        XCTAssertEqual(model.status.statusMessage, "Another operation", "another operation's line is not cleared")

        model.status.clear()
        struct Failure: Error {}
        do {
            try await model.status.withElapsedStatus("Stopping D…") { () async throws -> Void in throw Failure() }
            XCTFail("the error must propagate")
        } catch is Failure {}
        XCTAssertNil(model.status.statusMessage, "a throwing operation clears its line too")
    }
}
