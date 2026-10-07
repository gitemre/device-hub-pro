import XCTest
@testable import DeviceHubProKit

/// Integration tests that run only when a local emulator with gRPC enabled is
/// available (they are skipped otherwise).
final class IntegrationTests: XCTestCase {
    private let emulatorPort = 8554

    private struct EmulatorInfo {
        let serial: String
        let port: Int
    }

    /// Resolves the running emulator and its gRPC endpoint, or nil when there
    /// is nothing to test against.
    private func emulatorInfo() async throws -> EmulatorInfo? {
        guard let adb = AdbClient.locate() else { return nil }
        let devices = try await adb.listDevices()
        guard let device = devices.first(where: { $0.isOnline && $0.isEmulator }) else { return nil }
        guard let info = await EmulatorDiscovery.grpcInfo(serial: device.serial, adbClient: adb) else {
            return nil
        }
        return EmulatorInfo(serial: device.serial, port: info.port)
    }

    func testMirrorSessionReceivesFramesFromRunningEmulator() async throws {
        guard await EmulatorProbe.status(port: emulatorPort) != nil else {
            throw XCTSkip("no emulator with gRPC on port \(emulatorPort)")
        }

        let session = MirrorSession(port: emulatorPort)
        session.start()
        defer { session.stop() }

        // MMAP is reported only once the emulator has written a mapped frame.
        XCTAssertEqual(session.transport, .raw, "no mapped frame can have arrived yet")

        var received: Frame?
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(100))
            if let frame = session.frames.take() {
                received = frame
                break
            }
        }

        let frame = try XCTUnwrap(received, "no frame received within 10 seconds")
        XCTAssertGreaterThan(frame.width, 0)
        XCTAssertGreaterThan(frame.height, 0)
        XCTAssertEqual(frame.data.count, frame.width * frame.height * 4)
        XCTAssertFalse(frame.data.isEmpty)
    }

    func testEmulatorManagerListsAvds() async throws {
        guard let manager = EmulatorManager.locate(processScope: .ownProcesses) else {
            throw XCTSkip("emulator binary not found")
        }
        let avds = try await manager.listAvds()
        guard !avds.isEmpty else {
            throw XCTSkip("no AVDs on this machine")
        }
        XCTAssertFalse(avds.contains(where: \.isEmpty), "every listed AVD has a name")
    }

    func testRunningEmulatorsAreDetected() async throws {
        // Reads (never signals) the VMs someone else runs: the app's view.
        guard let manager = EmulatorManager.locate(processScope: .everyVM) else {
            throw XCTSkip("emulator binary not found")
        }
        let running = try await manager.runningEmulators()
        guard let first = running.first else {
            throw XCTSkip("no running emulator")
        }
        XCTAssertFalse(first.avd.isEmpty)
        XCTAssertGreaterThan(first.processID, 0)
    }

    func testAdbListsDevices() async throws {
        guard let adb = AdbClient.locate() else {
            throw XCTSkip("adb not found")
        }
        let devices = try await adb.listDevices()
        // No assertion on count: the machine may have no devices attached.
        for device in devices {
            XCTAssertFalse(device.serial.isEmpty)
        }
    }

    /// Wireless pairing needs a phone in pairing mode, which this environment
    /// does not have. What can be live-verified is the error mapping against
    /// the real adb: pairing/connecting to a closed local port must throw with
    /// the tool's own message, and `adb connect`'s zero-exit failure must not
    /// read as success.
    func testWirelessPairingFailuresAreMappedFromTheRealAdb() async throws {
        guard let adb = AdbClient.locate() else {
            throw XCTSkip("adb not found")
        }

        // Port 1 is privileged and closed, so both commands fail deterministically.
        do {
            _ = try await adb.pair(address: "127.0.0.1:1", code: "123456")
            XCTFail("pairing to a closed port must throw")
        } catch let error as AdbError {
            XCTAssertTrue(
                error.description.contains("pair 127.0.0.1:1 123456"),
                "the failure must carry the argv: \(error.description)"
            )
        }

        do {
            _ = try await adb.connect(address: "127.0.0.1:1")
            XCTFail("connecting to a closed port must throw despite adb's zero exit")
        } catch let error as AdbError {
            XCTAssertTrue(
                error.description.lowercased().contains("connect"),
                "the failure must carry adb's message: \(error.description)"
            )
        }
    }

    func testLogcatStreamReceivesEntries() async throws {
        guard let adb = AdbClient.locate() else {
            throw XCTSkip("adb not found")
        }
        // Emulators only unless a phone is pinned (LiveTestDevices): reading
        // logcat is read-only, but a plugged-in phone is not ours to use.
        guard let device = LiveTestDevices.allowed(try await adb.listDevices()).first else {
            throw XCTSkip("no online emulator")
        }

        let stream = LogcatStream(adbURL: adb.adbURL, serial: device.serial)
        stream.start()
        defer { stream.stop() }

        var entries: [LogcatEntry] = []
        for _ in 0..<60 {
            try await Task.sleep(for: .milliseconds(100))
            entries = stream.snapshot()
            if !entries.isEmpty { break }
        }

        XCTAssertFalse(entries.isEmpty, "expected logcat entries within 6 seconds")
    }

    func testAdbEmuCommands() async throws {
        guard let adb = AdbClient.locate() else {
            throw XCTSkip("adb not found")
        }
        let devices = try await adb.listDevices()
        guard let device = devices.first(where: { $0.isOnline && $0.isEmulator }) else {
            throw XCTSkip("no online emulator")
        }
        // `fold`/`unfold` answer KO on an emulator without a hinge.
        guard let avd = try? await adb.avdName(serial: device.serial),
              AvdConfig.hingeCount(avdName: avd) > 0
        else {
            throw XCTSkip("the running emulator is not a foldable")
        }

        // `rotate` is intentionally not exercised: on the foldable image it
        // changes the emulator's hardware rotation without updating the
        // framework, leaving the mirror stream rotated until a cold boot.
        let fold = try await adb.emuCommand(serial: device.serial, ["fold"])
        XCTAssertTrue(fold.contains("OK"))
        let unfold = try await adb.emuCommand(serial: device.serial, ["unfold"])
        XCTAssertTrue(unfold.contains("OK"))

        // The console lists its presets on every AVD (a KO usage line);
        // `AvdConfig.isResizable` decides whether this one offers them.
        let presets = try await adb.resizeDisplayPresets(serial: device.serial)
        XCTAssertGreaterThanOrEqual(presets.count, 2)
    }

    /// Regression test for rotated input: a pull from the *displayed* top must
    /// open the notification shade in landscape too, because touches are
    /// converted from the logical frame to native panel coordinates.
    /// Requires a running emulator already rotated to landscape.
    func testLandscapePullOpensNotificationShade() async throws {
        guard let adb = AdbClient.locate() else {
            throw XCTSkip("adb not found")
        }
        let devices = try await adb.listDevices()
        guard let device = devices.first(where: { $0.isOnline && $0.isEmulator }) else {
            throw XCTSkip("no online emulator")
        }
        guard let info = await EmulatorDiscovery.grpcInfo(serial: device.serial, adbClient: adb) else {
            throw XCTSkip("no gRPC discovery info")
        }

        let session = MirrorSession(port: info.port)
        session.start()
        defer { session.stop() }

        var received: Frame?
        for _ in 0..<80 {
            try await Task.sleep(for: .milliseconds(100))
            if let frame = session.frames.current {
                received = frame
                break
            }
        }
        guard let frame = received else {
            throw XCTSkip("no frame received")
        }
        guard frame.rotation % 2 == 1 else {
            throw XCTSkip("emulator is not landscape; rotate it to run this test")
        }

        func shadeIsOpen() async -> Bool {
            let output = (try? await adb.shell(serial: device.serial, ["dumpsys", "window"])) ?? ""
            return output.contains("NotificationShade")
        }

        _ = try? await adb.shell(serial: device.serial, ["cmd", "statusbar", "collapse"])
        try await Task.sleep(for: .milliseconds(700))

        // The user's gesture: pull down from the top of the displayed frame.
        let centerX = Int32(frame.width / 2)
        session.send(TouchCommand(phase: .down, x: centerX, y: 40))
        for step in 1...24 {
            let y = Int32(40 + (Double(frame.height) - 240) * Double(step) / 24)
            session.send(TouchCommand(phase: .move, x: centerX, y: y))
            try await Task.sleep(for: .milliseconds(8))
        }
        session.send(TouchCommand(phase: .up, x: centerX, y: Int32(frame.height) - 200))

        try await Task.sleep(for: .milliseconds(800))
        let opened = await shadeIsOpen()
        _ = try? await adb.shell(serial: device.serial, ["cmd", "statusbar", "collapse"])
        XCTAssertTrue(opened, "pulling down from the displayed top must open the notification shade")
    }

    /// Regression test for multi-touch: two contacts moving apart must reach
    /// Android as one pinch gesture (same path the trackpad pinch uses).
    /// Requires Chrome on the running emulator.
    func testMultiTouchPinchChangesTheScreen() async throws {
        guard let adb = AdbClient.locate() else {
            throw XCTSkip("adb not found")
        }
        let devices = try await adb.listDevices()
        guard let device = devices.first(where: { $0.isOnline && $0.isEmulator }) else {
            throw XCTSkip("no online emulator")
        }
        guard let info = await EmulatorDiscovery.grpcInfo(serial: device.serial, adbClient: adb) else {
            throw XCTSkip("no gRPC discovery info")
        }

        // Chrome on a web page zooms with a two-finger pinch. The explicit
        // component makes the launch reliable.
        let url = "https://example.com/?devicehubpro=\(UUID().uuidString.prefix(6))"
        _ = try? await adb.shell(
            serial: device.serial,
            [
                "am", "start",
                "-n", "com.example.browser/com.example.browser.app.Main",
                "-a", "android.intent.action.VIEW",
                "-d", url,
            ]
        )
        try await Task.sleep(for: .seconds(4))

        let focus = (try? await adb.shell(serial: device.serial, ["dumpsys", "window"])) ?? ""
        guard focus.contains("chrome") else {
            throw XCTSkip("Chrome did not come to the foreground")
        }

        let session = MirrorSession(port: info.port)
        session.start()
        defer { session.stop() }

        var received: Frame?
        for _ in 0..<80 {
            try await Task.sleep(for: .milliseconds(100))
            if let frame = session.frames.current {
                received = frame
                break
            }
        }
        guard let frame = received else {
            throw XCTSkip("no frame received")
        }

        let before = try await adb.screenshot(serial: device.serial)

        let centerX = Int32(frame.width / 2)
        let centerY = Int32(frame.height / 2)

        func pinch(from startSpread: Int32, to endSpread: Int32) async throws {
            session.send(contacts: [
                TouchCommand(phase: .down, x: centerX - startSpread, y: centerY, id: 1),
                TouchCommand(phase: .down, x: centerX + startSpread, y: centerY, id: 2),
            ])
            for step in 1...20 {
                let spread = startSpread + (endSpread - startSpread) * Int32(step) / 20
                session.send(contacts: [
                    TouchCommand(phase: .move, x: centerX - spread, y: centerY, id: 1),
                    TouchCommand(phase: .move, x: centerX + spread, y: centerY, id: 2),
                ])
                try await Task.sleep(for: .milliseconds(16))
            }
            session.send(contacts: [
                TouchCommand(phase: .up, x: centerX - endSpread, y: centerY, id: 1),
                TouchCommand(phase: .up, x: centerX + endSpread, y: centerY, id: 2),
            ])
            try await Task.sleep(for: .milliseconds(700))
        }

        // Zoom out first; if the page was already at the minimum zoom, zoom in.
        try await pinch(from: 700, to: 180)
        var after = try await adb.screenshot(serial: device.serial)
        if after == before {
            try await pinch(from: 180, to: 700)
            after = try await adb.screenshot(serial: device.serial)
        }

        _ = try? await adb.shell(serial: device.serial, ["input", "keyevent", "3"])
        XCTAssertNotEqual(before, after, "pinch must change the rendered screen")
    }

    func testClipboardRoundTrip() async throws {
        guard let adb = AdbClient.locate() else {
            throw XCTSkip("adb not found")
        }
        let devices = try await adb.listDevices()
        guard let device = devices.first(where: { $0.isOnline && $0.isEmulator }) else {
            throw XCTSkip("no online emulator")
        }
        guard let info = await EmulatorDiscovery.grpcInfo(serial: device.serial, adbClient: adb) else {
            throw XCTSkip("no gRPC discovery info")
        }

        let token = "devicehubpro-clip-\(UUID().uuidString.prefix(8))"
        let stored = await EmulatorControls.setClipboard(port: info.port, text: token)
        XCTAssertTrue(stored, "setClipboard must succeed")
        let read = await EmulatorControls.clipboard(port: info.port)
        XCTAssertEqual(read, token)
    }

    /// The emulator only emits audio packets while something is playing, so the
    /// test rings the device and expects PCM bytes to arrive.
    func testAudioStreamDeliversPacketsWhileRinging() async throws {
        guard let adb = AdbClient.locate() else {
            throw XCTSkip("adb not found")
        }
        let devices = try await adb.listDevices()
        guard let device = devices.first(where: { $0.isOnline && $0.isEmulator }) else {
            throw XCTSkip("no online emulator")
        }
        guard let info = await EmulatorDiscovery.grpcInfo(serial: device.serial, adbClient: adb) else {
            throw XCTSkip("no gRPC discovery info")
        }

        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var total = 0

            func add(_ count: Int) {
                lock.lock()
                total += count
                lock.unlock()
            }

            var bytes: Int {
                lock.lock()
                defer { lock.unlock() }
                return total
            }
        }

        let counter = Counter()
        let stream = AudioStream(port: info.port)
        stream.start { data in counter.add(data.count) }
        defer { stream.stop() }

        func cancelCall() async {
            _ = try? await adb.emuCommand(serial: device.serial, ["gsm", "cancel", "5551234"])
        }

        _ = try? await adb.emuCommand(serial: device.serial, ["gsm", "call", "5551234"])
        try await Task.sleep(for: .seconds(3))
        await cancelCall()

        // A muted or `-no-audio` emulator (and a device with ringing turned
        // off) produces no packets at all; that says nothing about the stream.
        guard counter.bytes > 0 else {
            throw XCTSkip("the emulator produced no audio while ringing (muted or -no-audio)")
        }
        XCTAssertNil(stream.lastError)
    }

    /// With a 37.2.3+ emulator the default session must negotiate the
    /// shared-memory transport (MMAP) and read real frames from the mapping;
    /// older builds skip.
    func testMMAPTransportWhenEmulatorSupportsIt() async throws {
        guard let adb = AdbClient.locate() else {
            throw XCTSkip("adb not found")
        }
        let devices = try await adb.listDevices()

        // Any running emulator new enough to support MMAP qualifies; the first
        // one may be an older build while another one is 37.x.
        for device in devices where device.isOnline && device.isEmulator {
            guard let info = await EmulatorDiscovery.grpcInfo(serial: device.serial, adbClient: adb),
                  let status = await EmulatorProbe.status(port: info.port),
                  EmulatorVersion.supportsMMAP(status.version) else {
                continue
            }

            guard ProcessInfo.processInfo.environment[MMAPPolicy.disableVariable] != "1" else {
                throw XCTSkip("DHP_DISABLE_MMAP=1 is set")
            }

            let session = MirrorSession(port: info.port)
            session.start()
            defer { session.stop() }

            // The first frame is a consistent snapshot; only frames read from
            // the mapping switch the transport to MMAP, so keep the screen
            // changing until one arrives.
            var transport = session.transport
            for step in 0..<60 {
                try await Task.sleep(for: .milliseconds(150))
                transport = session.transport
                if transport == .mmap { break }
                let command = step.isMultiple(of: 2) ? "expand-notifications" : "collapse"
                _ = try? await adb.shell(serial: device.serial, ["cmd", "statusbar", command])
            }
            _ = try? await adb.shell(serial: device.serial, ["cmd", "statusbar", "collapse"])

            XCTAssertEqual(transport, .mmap, "emulator \(status.version) should negotiate MMAP")
            let frame = try XCTUnwrap(session.frames.current)
            XCTAssertTrue(MappedFrameCheck.isWritten(frame.data), "a mapped frame must hold pixels")
            XCTAssertNil(session.lastError)
            return
        }

        throw XCTSkip("no MMAP-capable emulator is running")
    }

    func testSensorWriteReadRoundTrip() async throws {
        guard let info = try await emulatorInfo() else {
            throw XCTSkip("no emulator with gRPC discovery")
        }

        let values: [Float] = [1.5, 2.5, 3.5]
        let stored = await EmulatorSensors.set(port: info.port, kind: .acceleration, values: values)
        XCTAssertTrue(stored, "setSensor must succeed")

        let read = await EmulatorSensors.reading(port: info.port, kind: .acceleration)
        XCTAssertEqual(read?.count, values.count)
        if let read {
            for (actual, expected) in zip(read, values) {
                XCTAssertEqual(actual, expected, accuracy: 0.01)
            }
        }
    }

    func testBrightnessRoundTrip() async throws {
        guard let info = try await emulatorInfo() else {
            throw XCTSkip("no emulator with gRPC discovery")
        }

        let original = await EmulatorDeviceControls.brightness(port: info.port) ?? 128
        let stored = await EmulatorDeviceControls.setBrightness(port: info.port, value: 200)
        XCTAssertTrue(stored)
        let read = await EmulatorDeviceControls.brightness(port: info.port)
        XCTAssertEqual(read, 200)
        _ = await EmulatorDeviceControls.setBrightness(port: info.port, value: original)
    }

    func testVmPauseResumeRoundTrip() async throws {
        guard let info = try await emulatorInfo() else {
            throw XCTSkip("no emulator with gRPC discovery")
        }

        let paused = await EmulatorDeviceControls.setRunning(port: info.port, false)
        XCTAssertTrue(paused)
        try await Task.sleep(for: .milliseconds(300))
        let resumed = await EmulatorDeviceControls.setRunning(port: info.port, true)
        XCTAssertTrue(resumed)
    }

    func testTelephonyActions() async throws {
        guard let info = try await emulatorInfo(), let adb = AdbClient.locate() else {
            throw XCTSkip("no emulator with gRPC discovery")
        }

        let called = await EmulatorTelephony.placeCall(port: info.port, number: "5551234")
        XCTAssertTrue(called, "incoming call must be accepted")
        _ = try? await adb.emuCommand(serial: info.serial, ["gsm", "cancel", "5551234"])

        let smsBefore = await Self.inboxCount(adb: adb, serial: info.serial, from: "5559999")
        let sms = await EmulatorTelephony.sendSMS(port: info.port, from: "5559999", text: "hello")
        XCTAssertTrue(sms, "incoming SMS must be accepted")
        await Self.settleIncomingSMS(adb: adb, serial: info.serial, from: "5559999", after: smsBefore)

        // Some images reject changing the SIM number at runtime; only exercise
        // the call so the assertion stays deterministic.
        _ = await EmulatorTelephony.setPhoneNumber(port: info.port, number: "+15551234567")
    }

    /// The SMS reaches the inbox a few seconds after the console accepts it,
    /// and on an image whose Messages app is not set up it then opens the
    /// Messages welcome screen over whatever the next test drives (the scrcpy
    /// input tests tap the Settings search bar). Wait for it to land, then
    /// leave the device as we found it.
    private static func settleIncomingSMS(adb: AdbClient, serial: String, from address: String, after count: Int?) async {
        if let count {
            for _ in 0..<30 {
                if let now = await inboxCount(adb: adb, serial: serial, from: address), now > count { break }
                try? await Task.sleep(for: .milliseconds(500))
            }
            // Messages launches its welcome screen just after the insert.
            try? await Task.sleep(for: .seconds(1))
        }
        _ = try? await adb.shell(serial: serial, ["am", "force-stop", "com.example.messages"])
        _ = try? await adb.shell(serial: serial, ["cmd", "statusbar", "collapse"])
    }

    private static func inboxCount(adb: AdbClient, serial: String, from address: String) async -> Int? {
        guard let output = try? await adb.shell(serial: serial, [
            "content", "query", "--uri", "content://sms/inbox", "--projection", "_id",
            "--where", AdbClient.shellQuoted("address='\(address)'"),
        ]) else { return nil }
        return output.split(separator: "\n").filter { $0.hasPrefix("Row:") }.count
    }

    func testEmulatorControlsRoundTrip() async throws {
        guard await EmulatorProbe.status(port: emulatorPort) != nil else {
            throw XCTSkip("no emulator with gRPC on port \(emulatorPort)")
        }

        let batterySet = await EmulatorControls.setBattery(port: emulatorPort, level: 42, charging: false)
        XCTAssertTrue(batterySet)
        var state = await EmulatorControls.state(port: emulatorPort)
        XCTAssertEqual(state.battery?.level, 42)
        XCTAssertEqual(state.battery?.isCharging, false)
        XCTAssertFalse(state.displays.isEmpty)
        XCTAssertEqual(state.isBooted, true)

        let locationSet = await EmulatorControls.setLocation(
            port: emulatorPort,
            latitude: 41.01,
            longitude: 28.97
        )
        XCTAssertTrue(locationSet)
        state = await EmulatorControls.state(port: emulatorPort)
        XCTAssertEqual(state.location?.latitude ?? 0, 41.01, accuracy: 0.01)
        XCTAssertEqual(state.location?.longitude ?? 0, 28.97, accuracy: 0.01)

        // Foldability comes from the AVD hinge sensors; the gRPC posture alone
        // is answered by every emulator.
        var foldable = state.isFoldable
        if !foldable, let adb = AdbClient.locate() {
            let devices = (try? await adb.listDevices()) ?? []
            for device in devices where device.isOnline && device.isEmulator {
                guard let info = await EmulatorDiscovery.grpcInfo(serial: device.serial, adbClient: adb),
                      info.port == emulatorPort,
                      let avd = try? await adb.avdName(serial: device.serial) else {
                    continue
                }
                foldable = AvdConfig.hingeCount(avdName: avd) > 0
                break
            }
        }

        if foldable, state.hingeAngle != nil {
            // Step the hinge like the UI animation does and settle on opened.
            for angle in stride(from: 0.0, through: 180.0, by: 30.0) {
                _ = await EmulatorControls.setHingeAngle(port: emulatorPort, degrees: angle)
            }

            let angle = await EmulatorControls.hingeAngle(port: emulatorPort)
            XCTAssertEqual(angle ?? 0, 180, accuracy: 2)

            let finalPosture = await EmulatorControls.posture(port: emulatorPort)
            XCTAssertEqual(finalPosture, .opened)
        }

        // Restore a sane battery state for subsequent manual testing.
        let restored = await EmulatorControls.setBattery(port: emulatorPort, level: 100, charging: true)
        XCTAssertTrue(restored)
    }
}
