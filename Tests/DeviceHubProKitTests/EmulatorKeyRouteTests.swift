import XCTest
@testable import DeviceHubProKit

/// Real `adb -s <serial> shell getevent -lp` output, byte for byte, from the
/// `T2_Medium_Phone` test AVD (API 37 `sdk_gphone16k_arm64`
/// CP31.260623.012, emulator 36.6.11), 2026-09-26: once as avdmanager
/// created it (`hw.keyboard=no`) and once after the cold boot with
/// `hw.keyboard=yes`. Each was captured twice, on `emulator-5558` and on
/// `emulator-5554`, with identical bytes. Device names only; no personal
/// identifier to replace.
enum InputFixtures {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/api37-emulator/input", isDirectory: true)

    static let keyboardless = "shell-getevent-lp-hw-keyboard-no.txt"
    static let withKeyboard = "shell-getevent-lp-hw-keyboard-yes.txt"

    static func text(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        try XCTUnwrap(
            try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8),
            "missing fixture \(name)",
            file: file,
            line: line
        )
    }
}

/// How a session picks its key route: the guest's input devices
/// (`GuestInputDevices`), the once-per-run probe
/// (`EmulatorKeyRouteProbe`) and the adb calls behind them
/// (`AdbInputFallback`).
final class EmulatorKeyRouteTests: XCTestCase {
    // MARK: - The guest's devices

    /// avdmanager's AVD: eleven virtio touch devices and the guest's own
    /// `gpio-keys` (power only). No "qwerty2": the emulator's keys have
    /// nowhere to go, so the route is adb.
    func testAKeyboardlessGuestHasNoEmulatorKeyboard() throws {
        let devices = GuestInputDevices.parse(try InputFixtures.text(InputFixtures.keyboardless))

        XCTAssertEqual(devices.count, 12)
        XCTAssertEqual(devices.filter { $0.name.hasPrefix("virtio_input_multi_touch_") }.count, 11)
        XCTAssertFalse(devices.contains { $0.name == "qwerty2" })
        let gpio = try XCTUnwrap(devices.first { $0.name == "gpio-keys" })
        XCTAssertEqual(gpio.keys, ["KEY_POWER"])
        let touch = try XCTUnwrap(devices.first { $0.name == "virtio_input_multi_touch_1" })
        XCTAssertEqual(touch.keys, ["BTN_TOOL_RUBBER", "BTN_STYLUS"], "only the KEY list, not ABS or SW")

        XCTAssertEqual(
            GuestInputDevices.routes(fromGeteventLp: try InputFixtures.text(InputFixtures.keyboardless)),
            EmulatorKeyRoutes(sideButtons: .adbInput, typing: .adbInput)
        )
    }

    /// With `hw.keyboard=yes` the guest has "qwerty2" first, whose KEY list
    /// (over 25 continuation lines) carries power and both volume keys, the
    /// letters and Ctrl: the emulator's keys land, so both routes stay on
    /// it.
    func testAGuestWithTheKeyboardKeepsTheEmulatorRoute() throws {
        let output = try InputFixtures.text(InputFixtures.withKeyboard)
        let devices = GuestInputDevices.parse(output)

        XCTAssertEqual(devices.count, 13)
        XCTAssertEqual(devices.first?.name, "qwerty2")
        let keyboard = try XCTUnwrap(devices.first)
        XCTAssertTrue(GuestInputDevices.sideButtonLabels.isSubset(of: keyboard.keys))
        XCTAssertTrue(GuestInputDevices.typingLabels.isSubset(of: keyboard.keys))
        XCTAssertTrue(["KEY_A", "KEY_V", "KEY_LEFTCTRL", "KEY_ENTER"].allSatisfy(keyboard.keys.contains))
        XCTAssertEqual(devices.last?.name, "gpio-keys")

        XCTAssertEqual(GuestInputDevices.routes(fromGeteventLp: output), .emulatorKeyboard)
    }

    /// The older machine's key sink, `goldfish-events`, is "qwerty2" with or
    /// without the keyboard, but without it reports only its fixed keys
    /// (power and volume among them), no letter and no Ctrl: the buttons
    /// stay on the emulator and the typing goes through adb.
    ///
    /// SOURCE-DERIVED (no such image to capture on this Mac): the key set is
    /// `platform/external/qemu` emu-master-dev `hw/input/goldfish_events.c`'s
    /// always-on `goldfish_events_set_bit(s, EV_KEY, …)` calls for HOME,
    /// BACK, VOLUMEUP, VOLUMEDOWN, POWER, SEARCH and SLEEP (its other fixed
    /// keys left out), with `getevent -l`'s labels.
    func testGoldfishEventsWithoutTheKeyboardKeepsTheButtonsButTypesThroughAdb() {
        let goldfish = GuestInputDevices.Device(
            name: "qwerty2",
            keys: ["KEY_HOME", "KEY_BACK", "KEY_VOLUMEUP", "KEY_VOLUMEDOWN", "KEY_POWER", "KEY_SEARCH", "KEY_SLEEP"]
        )
        XCTAssertEqual(
            GuestInputDevices.routes(for: [goldfish]),
            EmulatorKeyRoutes(sideButtons: .emulatorKeyboard, typing: .adbInput)
        )

        // A "qwerty2" without power (and any other device) takes neither.
        let gpio = GuestInputDevices.Device(name: "gpio-keys", keys: ["KEY_POWER"])
        XCTAssertEqual(
            GuestInputDevices.routes(for: [gpio]),
            EmulatorKeyRoutes(sideButtons: .adbInput, typing: .adbInput)
        )
    }

    /// A listing without a single device decides nothing: an empty answer,
    /// or an error line instead of devices.
    func testAListingWithoutDevicesDecidesNothing() {
        XCTAssertNil(GuestInputDevices.routes(fromGeteventLp: ""))
        XCTAssertNil(GuestInputDevices.routes(fromGeteventLp: "could not open /dev/input, Permission denied\n"))
    }

    // MARK: - The probe

    private final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        var count: Int { lock.withLock { _count } }
        func add() { lock.withLock { _count += 1 } }
    }

    /// A manual clock for the retry delays.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var instant = ContinuousClock.now
        var now: @Sendable () -> ContinuousClock.Instant { { [self] in lock.withLock { instant } } }
        func advance(_ duration: Duration) { lock.withLock { instant += duration } }
    }

    private struct Offline: Error {}

    private static let keyboardless = EmulatorKeyRoutes(sideButtons: .adbInput, typing: .adbInput)

    /// The guest is asked once however many keys ask at once, and the
    /// answer is kept.
    func testTheProbeAsksTheGuestOnceAndKeepsTheRoute() async throws {
        let output = try InputFixtures.text(InputFixtures.keyboardless)
        let reads = Reads()
        let probe = EmulatorKeyRouteProbe {
            reads.add()
            try await Task.sleep(for: .milliseconds(50))
            return output
        }

        let routes = await withTaskGroup(of: EmulatorKeyRoutes.self) { group in
            for _ in 0..<8 {
                group.addTask { await probe.routes() }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        XCTAssertEqual(routes, Array(repeating: Self.keyboardless, count: 8))
        let again = await probe.routes()
        XCTAssertEqual(again, Self.keyboardless)
        XCTAssertEqual(reads.count, 1)
    }

    /// A guest (or adb) that keeps failing: the keys take the emulator's
    /// keyboard, the next read goes with the next key, then no sooner than
    /// 1, 2, 4, 8 and 15 s after the one before, and every 15 s from then
    /// on: the run never gives up, and a later answer is still taken.
    func testAFailingGuestIsReadAgainOnABackoffAndNeverGivenUp() async throws {
        let output = try InputFixtures.text(InputFixtures.keyboardless)
        let reads = Reads()
        let answers = Reads()
        let clock = Clock()
        let probe = EmulatorKeyRouteProbe(
            readInputDevices: {
                reads.add()
                guard answers.count > 0 else { throw Offline() }
                return output
            },
            now: clock.now
        )

        // The run's first read: the key waits for it.
        var route = await probe.routes()
        XCTAssertEqual(route, .emulatorKeyboard)
        XCTAssertEqual(reads.count, 1)

        // The next key starts a read and does not wait for it.
        route = await probe.routes()
        XCTAssertEqual(route, .emulatorKeyboard)
        await probe.settle()
        XCTAssertEqual(reads.count, 2)

        XCTAssertEqual(EmulatorKeyRouteProbe.retryDelays, [.zero, .seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(15)])
        for delay: Duration in [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(15), .seconds(15), .seconds(15)] {
            let before = reads.count
            clock.advance(delay - .milliseconds(1))
            route = await probe.routes()
            await probe.settle()
            XCTAssertEqual(route, .emulatorKeyboard)
            XCTAssertEqual(reads.count, before, "no read \(delay - .milliseconds(1)) after the last")
            clock.advance(.milliseconds(1))
            route = await probe.routes()
            await probe.settle()
            XCTAssertEqual(route, .emulatorKeyboard)
            XCTAssertEqual(reads.count, before + 1, "a read \(delay) after the last")
        }

        // The guest answers at last: the next read decides the run.
        answers.add()
        clock.advance(.seconds(15))
        route = await probe.routes()
        await probe.settle()
        XCTAssertEqual(route, .emulatorKeyboard, "the key that starts the read does not wait for it")
        route = await probe.routes()
        XCTAssertEqual(route, Self.keyboardless)
        let total = reads.count
        clock.advance(.seconds(60))
        route = await probe.routes()
        XCTAssertEqual(route, Self.keyboardless)
        XCTAssertEqual(reads.count, total)
    }

    /// A guest that was not ready for the first read (the run started as it
    /// came online) is read again with the next key, and that answer is
    /// kept.
    func testAReadThatFailsFirstIsAnsweredByALaterOne() async throws {
        let output = try InputFixtures.text(InputFixtures.keyboardless)
        let reads = Reads()
        let probe = EmulatorKeyRouteProbe {
            reads.add()
            if reads.count == 1 { throw Offline() }
            return output
        }
        let first = await probe.routes()
        let second = await probe.routes()
        await probe.settle()
        let third = await probe.routes()
        let fourth = await probe.routes()
        XCTAssertEqual([first, second, third, fourth], [.emulatorKeyboard, .emulatorKeyboard, Self.keyboardless, Self.keyboardless])
        XCTAssertEqual(reads.count, 2)
    }

    /// Only the run's first read holds a key: a retry that hangs (a wedged
    /// adb, up to the probe's timeout) keeps no key waiting.
    func testARetryThatHangsKeepsNoKeyWaiting() async throws {
        let output = try InputFixtures.text(InputFixtures.keyboardless)
        let reads = Reads()
        let (gate, open) = AsyncStream<Void>.makeStream()
        let probe = EmulatorKeyRouteProbe {
            reads.add()
            if reads.count == 1 { throw Offline() }
            for await _ in gate { break }
            return output
        }
        _ = await probe.routes()

        let started = ContinuousClock.now
        for _ in 0..<5 {
            let route = await probe.routes()
            XCTAssertEqual(route, .emulatorKeyboard)
        }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(1))
        let deadline = ContinuousClock.now + .seconds(3)
        while reads.count < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(reads.count, 2, "one retry in flight at a time")

        open.yield()
        await probe.settle()
        let route = await probe.routes()
        XCTAssertEqual(route, Self.keyboardless, "the retry's answer is taken")
        XCTAssertEqual(reads.count, 2)
    }

    /// The prefetch reads at once, and the key after it waits for nothing
    /// more.
    func testThePrefetchReadsBeforeTheFirstKey() async throws {
        let output = try InputFixtures.text(InputFixtures.withKeyboard)
        let reads = Reads()
        let probe = EmulatorKeyRouteProbe {
            reads.add()
            return output
        }
        probe.prefetch()
        let deadline = ContinuousClock.now + .seconds(3)
        while reads.count == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let routes = await probe.routes()
        XCTAssertEqual(routes, .emulatorKeyboard)
        XCTAssertEqual(reads.count, 1)
    }

    /// A caller cancelled while the guest is being read still gets the
    /// answer: the read runs on its own and is not cut short.
    func testACancelledCallerDoesNotCutTheReadShort() async throws {
        let output = try InputFixtures.text(InputFixtures.keyboardless)
        let probe = EmulatorKeyRouteProbe {
            try await Task.sleep(for: .milliseconds(100))
            return output
        }
        let caller = Task { await probe.routes() }
        caller.cancel()
        let routes = await caller.value
        XCTAssertEqual(routes, Self.keyboardless)
    }

    // MARK: - The adb calls

    /// A stand-in adb: logs its arguments, answers `getevent` with the
    /// keyboardless capture and everything else with nothing.
    private func makeStubAdb() throws -> (client: AdbClient, calls: () -> [String]) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmulatorKeyRouteTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("calls.log")
        let fixture = InputFixtures.directory.appendingPathComponent(InputFixtures.keyboardless)
        let script = """
            #!/bin/sh
            printf '%s\\n' "$*" >> '\(log.path)'
            case "$*" in
              *getevent*) cat '\(fixture.path)' ;;
            esac
            exit 0

            """
        let url = directory.appendingPathComponent("adb")
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        let calls = {
            ((try? String(contentsOf: log, encoding: .utf8)) ?? "")
                .split(separator: "\n")
                .map(String.init)
        }
        return (AdbClient(adbURL: url), calls)
    }

    /// The fallback always names the emulator's serial: the probe is
    /// `getevent -lp` in its shell, the API level `getprop`, and a press is
    /// `input` there. (The stand-in answers the `getprop` with nothing,
    /// which reads as no level.)
    func testTheFallbackRunsGeteventAndInputOnItsSerial() async throws {
        let stub = try makeStubAdb()
        let input = AdbInputFallback(serial: "emulator-5558", adb: stub.client).keyInput

        let output = try await input.readInputDevices()
        XCTAssertEqual(output, try InputFixtures.text(InputFixtures.keyboardless))
        let level = try await input.readSdkLevel()
        XCTAssertNil(level)
        try await input.run(AdbHardwareKeys.arguments(for: .power, longPress: false))
        try await input.run(AdbHardwareKeys.arguments(for: .power, longPress: true))

        XCTAssertEqual(stub.calls(), [
            "-s emulator-5558 shell getevent -lp",
            "-s emulator-5558 shell getprop ro.build.version.sdk",
            "-s emulator-5558 shell input keyevent 26",
            "-s emulator-5558 shell input keyevent --longpress 26",
        ])
    }
}
