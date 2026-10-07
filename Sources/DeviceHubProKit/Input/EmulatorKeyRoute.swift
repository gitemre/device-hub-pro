import Foundation

/// Where an emulator session's keys go: the frame's side buttons and the
/// Mac keyboard's typing.
///
/// Every key the emulator injects (gRPC `sendKey` with any code type, its
/// text, the console's `event send`) goes through QEMU's input queue, and on
/// the arm64 `virt` machine the queue's only key sink is the
/// `virtio-keyboard-pci` device, which the guest names "qwerty2". The
/// emulator adds that device only for an AVD whose `config.ini` says
/// `hw.keyboard=yes` (SOURCE-DERIVED: `platform/external/qemu`
/// emu-master-dev, `android/android-emu/android/main.cpp`
/// `if (hw->hw_keyboard) args.add("virtio-keyboard-pci")`, and
/// `hw/input/virtio-input-hid.c`, which names it "qwerty2"). Without it the
/// keys are dropped while the calls still answer OK. Android Studio creates
/// AVDs with the keyboard; `avdmanager` copies the emulator's own default,
/// `no`, so every AVD it made (Device Hub Pro's create sheet included, before
/// Device Hub Pro wrote the key itself) presses nothing. `adb shell input` injects
/// in the guest's input manager instead and needs no keyboard device.
public enum EmulatorKeyRoute: Sendable, Equatable {
    /// The emulator's own keyboard (`qwerty2`): gRPC `sendKey`, real key
    /// edges, the guest's own repeat and long press.
    case emulatorKeyboard
    /// No such keyboard: `adb shell input`, one complete press per call
    /// (`AdbHardwareKeys` stands in for a held key).
    case adbInput
}

/// One run's routes: the frame's side buttons and the Mac keyboard's typing
/// are decided apart, because a key sink can take the one and not the
/// other (`GuestInputDevices.routes(for:)`).
struct EmulatorKeyRoutes: Sendable, Equatable {
    var sideButtons: EmulatorKeyRoute
    var typing: EmulatorKeyRoute

    /// Both on the emulator's keyboard: today's route, the one every
    /// Android Studio AVD takes.
    static let emulatorKeyboard = EmulatorKeyRoutes(sideButtons: .emulatorKeyboard, typing: .emulatorKeyboard)
}

/// The guest's input devices as `getevent -lp` lists them.
enum GuestInputDevices {
    /// The name the guest gives the emulator's key sink: the
    /// `virtio-keyboard-pci` device on the `virt` machine, the
    /// `goldfish-events` device on the older `ranchu` one (SOURCE-DERIVED:
    /// `hw/input/virtio-input-hid.c`, `hw/input/goldfish_events.c`).
    static let emulatorKeyboardName = "qwerty2"

    /// The keys the frame's buttons press, as `getevent -l` labels them.
    static let sideButtonLabels: Set<String> = ["KEY_POWER", "KEY_VOLUMEUP", "KEY_VOLUMEDOWN"]

    /// The keys typing needs from the emulator's keyboard: a letter for the
    /// typed text and Ctrl+V for the paste of non-ASCII text. The older
    /// machine's `goldfish-events` "qwerty2" always reports power and
    /// volume but reports the letter keys only with `hw.keyboard=yes`
    /// (SOURCE-DERIVED: `platform/external/qemu` emu-master-dev,
    /// `hw/input/goldfish_events.c`: HOME, BACK, VOLUMEUP, VOLUMEDOWN,
    /// POWER and the other fixed keys always, `goldfish_events_set_bits(s,
    /// EV_KEY, 1, 0xff)` only `if (s->have_keyboard)`), and the guest's
    /// kernel drops a key its device does not report.
    static let typingLabels: Set<String> = ["KEY_A", "KEY_LEFTCTRL", "KEY_V"]

    /// One `add device` block: its name and the `KEY` codes it reports.
    struct Device: Equatable {
        var name: String
        var keys: Set<String>
    }

    /// The devices of `getevent -lp`'s listing, in its order. A device's
    /// `KEY (0001):` list runs over indented continuation lines until the
    /// next event type (`ABS (0003):`) or `input props:`.
    static func parse(_ output: String) -> [Device] {
        var devices: [Device] = []
        var inKeyList = false
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("add device ") {
                devices.append(Device(name: "", keys: []))
                inKeyList = false
                continue
            }
            guard !devices.isEmpty else { continue }
            if line.hasPrefix("name:") {
                let value = line.dropFirst("name:".count).trimmingCharacters(in: .whitespaces)
                devices[devices.count - 1].name = value.count >= 2 && value.hasPrefix("\"") && value.hasSuffix("\"")
                    ? String(value.dropFirst().dropLast())
                    : value
                continue
            }
            var tokens = Substring(line)
            if let type = eventType(of: line) {
                inKeyList = type.name == "KEY"
                tokens = type.rest
            } else if line.hasPrefix("input props:") || line.hasPrefix("events:") {
                inKeyList = false
                continue
            }
            guard inKeyList else { continue }
            for token in tokens.split(whereSeparator: \.isWhitespace) {
                devices[devices.count - 1].keys.insert(String(token))
            }
        }
        return devices
    }

    /// `KEY (0001): …` → ("KEY", the text after the colon); nil for a line
    /// that does not open an event type.
    private static func eventType(of line: String) -> (name: Substring, rest: Substring)? {
        guard let open = line.firstIndex(of: "("),
              let close = line[open...].firstIndex(of: ")"),
              line[line.index(after: close)...].hasPrefix(":")
        else { return nil }
        let name = line[..<open].trimmingCharacters(in: .whitespaces)
        let code = line[line.index(after: open)..<close]
        guard !name.isEmpty, name.allSatisfy({ $0.isUppercase }),
              code.count == 4, code.allSatisfy(\.isHexDigit)
        else { return nil }
        return (Substring(name), line[line.index(close, offsetBy: 2)...])
    }

    /// The routes the devices call for, each on the emulator's keyboard
    /// when a "qwerty2" device reports its keys and on adb otherwise: the
    /// side buttons need power and both volume keys (`sideButtonLabels`),
    /// typing needs `typingLabels`. Nil for no device at all (an empty or
    /// failed read decides nothing).
    static func routes(for devices: [Device]) -> EmulatorKeyRoutes? {
        guard !devices.isEmpty else { return nil }
        func route(needing labels: Set<String>) -> EmulatorKeyRoute {
            let hasKeys = devices.contains {
                $0.name == emulatorKeyboardName && labels.isSubset(of: $0.keys)
            }
            return hasKeys ? .emulatorKeyboard : .adbInput
        }
        return EmulatorKeyRoutes(sideButtons: route(needing: sideButtonLabels), typing: route(needing: typingLabels))
    }

    /// `routes(for:)` of the listing's devices.
    static func routes(fromGeteventLp output: String) -> EmulatorKeyRoutes? {
        routes(for: parse(output))
    }
}

/// Decides one session run's key routes and keeps them: a VM's keyboard
/// cannot come or go while it runs (`hw.keyboard` is read at launch), so the
/// guest is asked until it answers once. The session starts the first read
/// when its run starts (`prefetch`): `getevent -lp` takes about 150 ms
/// (measured on API 37), which the first key would otherwise wait for.
///
/// Until a read answers, keys take the emulator's keyboard: today's route,
/// the one every Android Studio AVD takes. Keys wait only for the run's
/// first read. A read that fails or lists no device decides nothing; the
/// next one starts with a later key, at once after the first failure and
/// then no sooner than `retryDelays` after the one before, and those keys do
/// not wait for it: a guest (or adb) that keeps failing costs no key a
/// delay and adb no read per keystroke, and a guest that answers later
/// still gets its route.
actor EmulatorKeyRouteProbe {
    /// The wait after the n-th failed read before a key starts the next
    /// (the last one repeats): the first retry goes with the next key (the
    /// guest may not have been ready when the run started).
    static let retryDelays: [Duration] = [.zero, .seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(15)]

    private let readInputDevices: @Sendable () async throws -> String
    private let now: @Sendable () -> ContinuousClock.Instant
    private var decided: EmulatorKeyRoutes?
    private var reading: Task<Void, Never>?
    private var failedReads = 0
    private var nextReadAt: ContinuousClock.Instant?

    /// `now` is a test seam for the retry delays.
    init(
        readInputDevices: @escaping @Sendable () async throws -> String,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }
    ) {
        self.readInputDevices = readInputDevices
        self.now = now
    }

    /// Starts the first read without waiting for it.
    nonisolated func prefetch() {
        Task { _ = await self.routes() }
    }

    /// The routes: the decided ones; else, while no read has failed, the
    /// answer of the run's first read (started here if the prefetch has not
    /// yet); else the emulator's keyboard, starting the next read in the
    /// background when its time has come. A read runs in a task of its own,
    /// so a caller that is cancelled does not cut it short.
    func routes() async -> EmulatorKeyRoutes {
        if let decided { return decided }
        if failedReads == 0 {
            let read = reading ?? startRead()
            await read.value
            return decided ?? .emulatorKeyboard
        }
        if reading == nil, let nextReadAt, now() >= nextReadAt {
            startRead()
        }
        return .emulatorKeyboard
    }

    /// Waits for the read in flight, if any (a test seam).
    func settle() async {
        await reading?.value
    }

    @discardableResult
    private func startRead() -> Task<Void, Never> {
        let read = readInputDevices
        let task = Task {
            let output = try? await read()
            self.readFinished(output.flatMap(GuestInputDevices.routes(fromGeteventLp:)))
        }
        reading = task
        return task
    }

    private func readFinished(_ answer: EmulatorKeyRoutes?) {
        reading = nil
        if let answer {
            decided = answer
            return
        }
        failedReads += 1
        let delays = Self.retryDelays
        nextReadAt = now() + delays[min(failedReads, delays.count) - 1]
    }
}

/// The adb side of an emulator session's keys (a test seam): the guest's
/// input devices, its API level, and one `input …` command in its shell.
struct AdbKeyInput: Sendable {
    /// `getevent -lp`'s output.
    var readInputDevices: @Sendable () async throws -> String
    /// `ro.build.version.sdk`; nil when it is not a number.
    var readSdkLevel: @Sendable () async throws -> Int?
    /// Runs `input` with these arguments (`["input", "keyevent", "26"]`).
    var run: @Sendable (_ arguments: [String]) async throws -> Void
}

/// What an emulator session needs to reach a guest that has no keyboard
/// device: the emulator's adb serial and an adb client.
public struct AdbInputFallback: Sendable {
    public let serial: String
    public let adb: AdbClient

    public init(serial: String, adb: AdbClient) {
        self.serial = serial
        self.adb = adb
    }

    /// Bounds the device list read: it lists a dozen devices at once.
    static let probeTimeout: Duration = .seconds(5)
    /// Bounds one `input` command: a long press holds the key 0.4 s, and a
    /// pasted run of text types one key after another.
    static let inputTimeout: Duration = .seconds(10)

    var keyInput: AdbKeyInput {
        let serial = serial
        let adb = adb
        return AdbKeyInput(
            readInputDevices: {
                try await adb.shell(serial: serial, ["getevent", "-lp"], timeout: Self.probeTimeout)
            },
            readSdkLevel: {
                try await adb.sdkLevel(serial: serial)
            },
            run: { arguments in
                _ = try await adb.shell(serial: serial, arguments, timeout: Self.inputTimeout)
            }
        )
    }
}
