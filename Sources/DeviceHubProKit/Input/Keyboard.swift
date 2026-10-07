import Foundation
import GRPCCore
import GRPCProtobuf

/// A keyboard input forwarded to the device.
public enum KeyboardCommand: Sendable {
    /// Text to type. Printable ASCII is typed as key presses on the
    /// emulator's en-US layout; any other character (Turkish ş/ğ/İ, emoji,
    /// accented letters) has no key there, so it is pasted through the
    /// emulator clipboard instead, which is restored shortly afterwards.
    /// Control characters (Ctrl+letter) and AppKit function-key characters
    /// are not text and are dropped.
    case text(String)
    /// A macOS virtual key code (e.g. 51 = delete, 36 = return).
    case specialKey(UInt16)
}

/// One run of a `.text` command: what the en-US key map can type, or what
/// has to be pasted.
enum TextRun: Equatable, Sendable {
    case typed(String)
    case pasted(String)

    /// Splits text into typed and pasted runs. The emulator translates
    /// `KeyboardEvent.text` through the en-US layout and only printable ASCII
    /// [32, 127) (plus newline and tab) survives it (emulator_controller.proto:
    /// "Do not expect arbitrary UTF symbols to arrive in the emulator").
    /// Characters that are not text at all are dropped (`isDropped`).
    static func split(_ text: String) -> [TextRun] {
        var runs: [TextRun] = []
        var current = ""
        var currentIsTyped = true
        for character in text {
            let scalars = character.unicodeScalars.filter { !isDropped($0) }
            guard !scalars.isEmpty else { continue }
            let typed = scalars.allSatisfy(isTypeable)
            if !current.isEmpty, typed != currentIsTyped {
                runs.append(currentIsTyped ? .typed(current) : .pasted(current))
                current = ""
            }
            current.unicodeScalars.append(contentsOf: scalars)
            currentIsTyped = typed
        }
        if !current.isEmpty {
            runs.append(currentIsTyped ? .typed(current) : .pasted(current))
        }
        return runs
    }

    private static func isTypeable(_ scalar: Unicode.Scalar) -> Bool {
        (0x20..<0x7F).contains(scalar.value) || scalar == "\n" || scalar == "\t"
    }

    /// Scalars a key press can produce that are not text: control
    /// characters other than newline and tab (Ctrl+A is U+0001, DEL, C1)
    /// and the private-use characters AppKit reports for function keys
    /// (F1–F12, Help, keypad Clear: U+F700–U+F8FF). Typed as text the
    /// emulator dropped them; pasted they would put invisible characters or
    /// tofu into the test data.
    private static func isDropped(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "\n" || scalar == "\t" { return false }
        return scalar.properties.generalCategory == .control
            || (0xF700...0xF8FF).contains(scalar.value)
    }
}

/// The emulator clipboards a keyboard paste has borrowed, by port. A paste
/// puts its text on the emulator clipboard and gives the user's clipboard
/// back `KeyboardInjector.Timing.restoreDelay` later; meanwhile
/// `EmulatorControls.clipboard(port:)` reports the user's clipboard, not the
/// typed characters, and `EmulatorControls.setClipboard(port:text:)`
/// replaces what the paste will put back instead of racing it. Without this
/// the app's clipboard sync would copy the typed characters to the Mac
/// pasteboard, then copy the restored (older) text over whatever the Mac
/// pasteboard held.
final class BorrowedClipboards: @unchecked Sendable {
    static let shared = BorrowedClipboards()

    private let lock = NSLock()
    private var originals: [Int: String] = [:]

    /// The clipboard a paste on `port` will put back, while one is borrowed.
    func original(port: Int) -> String? {
        lock.withLock { originals[port] }
    }

    /// Borrows `port`'s clipboard, whose content is `original`. A borrow
    /// that is already running keeps its original: that is still the
    /// user's clipboard, the emulator now holds pasted text.
    func borrow(port: Int, original: String) {
        lock.withLock {
            if originals[port] == nil {
                originals[port] = original
            }
        }
    }

    /// Makes `text` what the paste puts back; false when nothing is borrowed.
    func replaceOriginal(port: Int, with text: String) -> Bool {
        lock.withLock {
            guard originals[port] != nil else { return false }
            originals[port] = text
            return true
        }
    }

    /// Ends the borrow once `restored` is back on the clipboard. False when
    /// the original changed while it was written (a clipboard sync replaced
    /// it); the new original must be written too.
    func finish(port: Int, restored: String) -> Bool {
        lock.withLock {
            guard let original = originals[port], original != restored else {
                originals[port] = nil
                return true
            }
            return false
        }
    }

    /// Ends the borrow without restoring (the restore write failed).
    func abandon(port: Int) {
        lock.withLock { originals[port] = nil }
    }
}

/// The emulator calls the keyboard queue makes (a test seam).
struct KeyboardSender: Sendable {
    var text: @Sendable (String) async throws -> Void
    var specialKey: @Sendable (UInt16) async throws -> Void
    var pasteShortcut: @Sendable () async throws -> Void
    var clipboard: @Sendable () async throws -> String
    var setClipboard: @Sendable (String) async throws -> Void
}

/// Drives one session's keyboard queue over the emulator's shared control
/// connection. Steps run strictly in order, so a paste and the clipboard
/// restore after it can never interleave.
enum KeyboardInjector {
    /// One queued step: a command, or the delayed clipboard restore that a
    /// paste schedules for itself.
    enum Step: Sendable {
        case command(KeyboardCommand)
        case restoreClipboard(generation: Int)
    }

    /// When a paste may touch the clipboard. The guest reads the emulator
    /// clipboard asynchronously twice: its clipboard monitor picks a new
    /// text up from the emulator, and the focused app reads it only when it
    /// handles Ctrl+V, after the key went through the input pipeline.
    struct Timing: Sendable {
        /// From setting the clipboard to sending Ctrl+V, so the guest has
        /// the new text before the app asks for it.
        var clipboardDelivery: Duration = .milliseconds(30)
        /// From a Ctrl+V to the next clipboard change, so the app has read
        /// this paste's text before the next one replaces it (fast typing
        /// of adjacent Turkish letters would paste the next letter twice).
        var pasteSettle: Duration = .milliseconds(100)
        /// How long the last paste keeps the clipboard before the user's is
        /// put back; a burst of typed characters shares one restore.
        var restoreDelay: Duration = .milliseconds(500)

        static let standard = Timing()
    }

    /// Set by the session's `stop()` before it finishes the step stream.
    /// The keys still queued behind it are dropped — a stopped or replaced
    /// session must not keep typing into the emulator, each step waiting up
    /// to the control timeout against a hung one — and only the clipboard
    /// restore still runs.
    final class StopSignal: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false

        var isStopped: Bool {
            lock.withLock { stopped }
        }

        func stop() {
            lock.withLock { stopped = true }
        }
    }

    /// Runs the queue until `steps` finishes, then puts back a clipboard a
    /// paste borrowed. `reportError` receives failed sends (the queue keeps
    /// going); `schedule` feeds the delayed restore back into the queue.
    /// Once `stopSignal` is stopped, queued commands are skipped.
    static func run(
        port: Int,
        steps: AsyncStream<Step>,
        schedule: @escaping @Sendable (Step) -> Void,
        reportError: @escaping @Sendable (String) -> Void,
        stopSignal: StopSignal = StopSignal(),
        sender: KeyboardSender? = nil,
        timing: Timing = .standard,
        clipboards: BorrowedClipboards = .shared
    ) async {
        let sender = sender ?? .grpc(port: port)
        var holdsClipboard = false
        var pasteGeneration = 0
        var lastPaste: ContinuousClock.Instant?

        /// Puts the user's clipboard back — again if a clipboard sync
        /// replaced it while it was written — and ends the borrow.
        func restoreClipboard() async throws {
            holdsClipboard = false
            while let original = clipboards.original(port: port) {
                do {
                    try await sender.setClipboard(original)
                } catch {
                    clipboards.abandon(port: port)
                    throw error
                }
                if clipboards.finish(port: port, restored: original) { return }
            }
        }

        for await step in steps {
            do {
                switch step {
                case .command where stopSignal.isStopped:
                    continue

                case .command(.specialKey(let keyCode)):
                    try await sender.specialKey(keyCode)

                case .command(.text(let text)):
                    for run in TextRun.split(text) {
                        guard !stopSignal.isStopped else { break }
                        switch run {
                        case .typed(let typed):
                            guard !typed.isEmpty else { continue }
                            try await sender.text(typed)
                        case .pasted(let pasted):
                            if clipboards.original(port: port) == nil {
                                clipboards.borrow(port: port, original: try await sender.clipboard())
                            }
                            holdsClipboard = true
                            // Schedule the restore before touching the
                            // clipboard, so a failed paste still gives it back.
                            pasteGeneration += 1
                            let generation = pasteGeneration
                            let restoreDelay = timing.restoreDelay
                            Task {
                                try? await Task.sleep(for: restoreDelay)
                                schedule(.restoreClipboard(generation: generation))
                            }
                            if let lastPaste {
                                let settled = lastPaste + timing.pasteSettle
                                if settled > .now {
                                    try await Task.sleep(until: settled, clock: .continuous)
                                }
                            }
                            try await sender.setClipboard(pasted)
                            try await Task.sleep(for: timing.clipboardDelivery)
                            try await sender.pasteShortcut()
                            lastPaste = .now
                        }
                    }

                case .restoreClipboard(let generation):
                    guard generation == pasteGeneration, holdsClipboard else { break }
                    try await restoreClipboard()
                }
            } catch {
                reportError("keyboard: \(error)")
            }
        }

        // The session stopped: give the last paste its time, then restore.
        if holdsClipboard {
            try? await Task.sleep(for: timing.restoreDelay)
            try? await restoreClipboard()
        }
    }
}

// MARK: - Sends

extension KeyboardSender {
    /// The real sends, on the emulator's shared control connection. Key and
    /// text sends are never retried on a stale connection (a rerun could
    /// type twice); the clipboard calls are absolute and may be.
    static func grpc(port: Int) -> KeyboardSender {
        KeyboardSender(
            text: { text in
                try await EmulatorControl.withSharedClient(port: port) { controller in
                    _ = try await controller.sendKey(.with { $0.text = text }, options: .controls)
                }
            },
            specialKey: { keyCode in
                try await EmulatorControl.withSharedClient(port: port) { controller in
                    for eventType in [
                        Android_Emulation_Control_KeyboardEvent.KeyEventType.keydown,
                        Android_Emulation_Control_KeyboardEvent.KeyEventType.keyup,
                    ] {
                        _ = try await controller.sendKey(
                            .with {
                                $0.codeType = .mac
                                $0.eventType = eventType
                                $0.keyCode = Int32(keyCode)
                            },
                            options: .controls
                        )
                    }
                }
            },
            pasteShortcut: {
                try await sendPasteShortcut(port: port)
            },
            clipboard: {
                try await EmulatorControl.withSharedClient(port: port, retryOnStaleConnection: true) { controller in
                    let clip: Android_Emulation_Control_ClipData = try await controller.getClipboard(
                        .init(),
                        options: .controls
                    )
                    return clip.text
                }
            },
            setClipboard: { text in
                try await EmulatorControl.withSharedClient(port: port, retryOnStaleConnection: true) { controller in
                    _ = try await controller.setClipboard(.with { $0.text = text }, options: .controls)
                }
            }
        )
    }

    // Linux evdev codes (the emulator's `KeyCodeType.Evdev`).
    private static let evdevLeftControl: Int32 = 29
    private static let evdevV: Int32 = 47

    /// Ctrl+V: every Android text field (TextView, Compose, WebView) pastes
    /// on it, unlike the dedicated paste key, which not every key layout maps.
    private static func sendPasteShortcut(port: Int) async throws {
        let sequence: [(Int32, Android_Emulation_Control_KeyboardEvent.KeyEventType)] = [
            (evdevLeftControl, .keydown),
            (evdevV, .keydown),
            (evdevV, .keyup),
            (evdevLeftControl, .keyup),
        ]
        try await EmulatorControl.withSharedClient(port: port) { controller in
            for (code, eventType) in sequence {
                _ = try await controller.sendKey(
                    .with {
                        $0.codeType = .evdev
                        $0.eventType = eventType
                        $0.keyCode = code
                    },
                    options: .controls
                )
            }
        }
    }
}
