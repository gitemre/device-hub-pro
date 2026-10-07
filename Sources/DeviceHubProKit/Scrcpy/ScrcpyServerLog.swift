import Darwin
import Foundation

/// The recent output of one device-side scrcpy server (its `adb shell`
/// stdout and stderr) and whether that process has exited.
///
/// The server explains its own failures ("Could not open video stream",
/// encoder exceptions, a version mismatch) only on its console, so the
/// launcher keeps the last lines here and launch and stream errors quote
/// them. Memory is bounded: at most ``maximumLines`` lines of at most
/// ``maximumLineLength`` bytes are kept.
public final class ScrcpyServerLog: @unchecked Sendable {
    public static let defaultMaximumLines = 64
    public static let maximumLineLength = 512

    public let maximumLines: Int

    private let lock = NSLock()
    private var ring: [String] = []
    private var pending: [UInt8] = []
    private var _exitStatus: Int32?
    private var ended = false
    private var _injectionDenied = false
    private let outputEnded = DispatchGroup()

    public init(maximumLines: Int = ScrcpyServerLog.defaultMaximumLines) {
        self.maximumLines = max(1, maximumLines)
        outputEnded.enter()
    }

    /// The kept lines, oldest first.
    public var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return ring
    }

    /// Whether the server printed the refusal of an injected input event
    /// (`SecurityException` naming `INJECT_EVENTS`, what a Xiaomi phone with
    /// "USB debugging (Security settings)" off answers) since the last
    /// ``clearInjectionDenied()``.
    public var injectionDenied: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _injectionDenied
    }

    /// Forgets a seen refusal, so a later one is told apart from it.
    public func clearInjectionDenied() {
        lock.lock()
        _injectionDenied = false
        lock.unlock()
    }

    /// The server process's exit status, once it has exited.
    public var exitStatus: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return _exitStatus
    }

    /// The last `count` lines on one line, for an error message; empty when
    /// the server printed nothing.
    public func tail(_ count: Int = 4) -> String {
        lines.suffix(count).joined(separator: " | ")
    }

    /// Appends `message` with the server's last lines, when there are any.
    func annotate(_ message: String) -> String {
        let tail = tail()
        return tail.isEmpty ? message : "\(message) (scrcpy server: \(tail))"
    }

    /// Feeds raw console bytes; lines end at `\n` or `\r`.
    func append(_ bytes: UnsafeRawBufferPointer) {
        lock.lock()
        defer { lock.unlock() }
        for byte in bytes {
            if byte == 0x0A || byte == 0x0D {
                flushPendingLocked()
            } else if pending.count < Self.maximumLineLength {
                pending.append(byte)
            }
        }
    }

    func append(_ text: String) {
        Array(text.utf8).withUnsafeBytes { append($0) }
    }

    func markExited(status: Int32) {
        lock.lock()
        _exitStatus = status
        lock.unlock()
    }

    /// The console reached EOF (the process closed its output).
    func finishOutput() {
        lock.lock()
        flushPendingLocked()
        let first = !ended
        ended = true
        lock.unlock()
        if first {
            outputEnded.leave()
        }
    }

    /// Waits until the console reached EOF, so an error composed right after
    /// the process exited still sees its last words.
    @discardableResult
    func waitForOutputEnd(timeout: TimeInterval) -> Bool {
        outputEnded.wait(timeout: .now() + max(0, timeout)) == .success
    }

    /// Reads `handle` to EOF on a background queue, then closes it. The
    /// reader must run for the whole session: a console pipe nobody drains
    /// fills up and blocks the adb client (and with it the server's writes).
    func capture(_ handle: FileHandle) {
        let descriptor = handle.fileDescriptor
        let box = CapturedHandle(handle: handle)
        DispatchQueue.global(qos: .utility).async { [self] in
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = buffer.withUnsafeMutableBytes { raw in
                    Darwin.read(descriptor, raw.baseAddress, raw.count)
                }
                if count > 0 {
                    buffer.withUnsafeBytes { raw in
                        append(UnsafeRawBufferPointer(rebasing: raw[0..<count]))
                    }
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    break
                }
            }
            try? box.handle.close()
            finishOutput()
        }
    }

    private func flushPendingLocked() {
        guard !pending.isEmpty else { return }
        let line = String(decoding: pending, as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
        pending.removeAll(keepingCapacity: true)
        guard !line.isEmpty else { return }
        if XiaomiInputBlock.isInjectionDenied(logLine: line) {
            _injectionDenied = true
        }
        ring.append(line)
        if ring.count > maximumLines {
            ring.removeFirst(ring.count - maximumLines)
        }
    }
}

private struct CapturedHandle: @unchecked Sendable {
    let handle: FileHandle
}
