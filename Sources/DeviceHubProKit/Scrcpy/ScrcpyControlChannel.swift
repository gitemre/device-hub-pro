import Darwin
import Foundation

/// The control socket of one scrcpy session.
///
/// Control messages are serialized by the caller's thread and written in
/// order on a private serial queue, so a slow socket never blocks input
/// producers. Device messages (the clipboard autosync, clipboard ACKs) are
/// read on another queue for the whole session: the server writes them
/// unprompted, and a socket nobody drains would eventually block it. The
/// reader only reads and parses; callbacks run on a third queue, so no
/// caller code ever runs on the thread that holds the descriptor.
///
/// Only ``close()`` releases the descriptor, and only once both the writer
/// and the reader are done with it (a reader that outlives close's wait
/// closes it itself when it exits); ``shutdown()`` merely wakes blocked I/O.
/// A write or read can therefore never land on a recycled descriptor number.
public final class ScrcpyControlChannel: @unchecked Sendable {
    private let handle: FileHandle
    private let descriptor: Int32
    private let writeQueue = DispatchQueue(label: "com.devicehubpro.scrcpy.control-write")
    private let readQueue = DispatchQueue(label: "com.devicehubpro.scrcpy.control-read")
    private let deliveryQueue = DispatchQueue(label: "com.devicehubpro.scrcpy.control-deliver")
    private let reading = DispatchGroup()

    private let lock = NSLock()
    private var closed = false
    private var failed = false
    private var readerStarted = false
    private var readerRunning = false
    /// Set once the reader lost the device-message framing: it only drains
    /// from then on, so no ACK will be recognised.
    private var readerStoppedParsing = false
    /// Set by a ``close()`` that stopped waiting for a reader still running:
    /// the reader releases the descriptor on its way out instead.
    private var readerClosesDescriptor = false
    /// The next clipboard sequence; `ScrcpyControl.sequenceInvalid` (0) is
    /// never used, since it asks for no ACK.
    private var nextSequence: UInt64 = 1
    private var acknowledgementWaiters: [UInt64: CheckedContinuation<Bool, Never>] = [:]

    /// Takes ownership of `handle`, a connected stream socket.
    init(handle: FileHandle) {
        self.handle = handle
        descriptor = handle.fileDescriptor
        // A write to a peer that went away must fail with EPIPE, not raise
        // SIGPIPE and kill the app.
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// False once the socket failed or was closed; callers then fall back to
    /// another input path.
    public var isUsable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !closed && !failed
    }

    /// Queues `messages` for writing, in order. Dropped when the channel is
    /// no longer usable; a write error marks it unusable.
    public func send(_ messages: [ScrcpyControlMessage]) {
        guard !messages.isEmpty, isUsable else { return }
        var bytes = Data()
        for message in messages {
            bytes.append(message.serialized)
        }
        let payload = bytes
        writeQueue.async { [self] in
            lock.lock()
            let skip = closed || failed
            lock.unlock()
            guard !skip else { return }
            if !writeAll(payload) {
                lock.lock()
                failed = true
                let waiters = takeAcknowledgementWaitersLocked()
                lock.unlock()
                waiters.forEach { $0.resume(returning: false) }
            }
        }
    }

    public func send(_ message: ScrcpyControlMessage) {
        send([message])
    }

    /// Sets the device clipboard (pasting it into the focused field when
    /// `paste` is set) and waits until the server acknowledges the request.
    ///
    /// The ACK comes after the server has injected `KEYCODE_PASTE`, so a
    /// caller that waits for it never replaces the clipboard before the
    /// paste key is on its way. Returns false when no ACK arrived within
    /// `timeout`, the channel failed or closed, or the task was cancelled.
    /// ACKs are parsed by the device-message reader, so it needs
    /// ``startReading(onMessage:)``.
    func setClipboard(_ text: String, paste: Bool, timeout: Duration) async -> Bool {
        guard let sequence = takeSequence() else { return false }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                lock.lock()
                guard !closed, !failed else {
                    lock.unlock()
                    continuation.resume(returning: false)
                    return
                }
                // Without a parsing reader no ACK can be recognised: the
                // request still goes out, but there is nothing to wait for.
                let readerGone = readerStarted && (!readerRunning || readerStoppedParsing)
                let waits = !readerGone && !Task.isCancelled
                if waits {
                    acknowledgementWaiters[sequence] = continuation
                }
                lock.unlock()

                send(.setClipboard(sequence: sequence, paste: paste, text: text))
                guard waits else {
                    continuation.resume(returning: false)
                    return
                }
                DispatchQueue.global(qos: .userInitiated).asyncAfter(
                    deadline: .now() + Self.seconds(from: timeout)
                ) { [weak self] in
                    self?.resolveAcknowledgement(sequence, acknowledged: false)
                }
            }
        } onCancel: {
            resolveAcknowledgement(sequence, acknowledged: false)
        }
    }

    /// Starts draining device messages. `onMessage` runs on the channel's
    /// delivery queue, in order, never on the thread reading the socket, so
    /// a slow callback delays later messages but never holds the descriptor
    /// (it should still not block for long). Only the first call starts a
    /// reader. A malformed message loses the framing, so the rest of the
    /// stream is drained unparsed.
    func startReading(onMessage: @escaping @Sendable (ScrcpyDeviceMessage) -> Void) {
        lock.lock()
        guard !closed, !readerStarted else {
            lock.unlock()
            return
        }
        readerStarted = true
        readerRunning = true
        reading.enter()
        lock.unlock()

        let descriptor = self.descriptor
        let deliveryQueue = self.deliveryQueue
        readQueue.async { [self] in
            defer { readerFinished() }
            var parser = ScrcpyDeviceMessageReader()
            var parsing = true
            var buffer = [UInt8](repeating: 0, count: 1 << 14)
            while true {
                lock.lock()
                let isClosed = closed
                lock.unlock()
                guard !isClosed else { return }

                let count = buffer.withUnsafeMutableBytes { raw in
                    Darwin.read(descriptor, raw.baseAddress, raw.count)
                }
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return }
                guard parsing else { continue }
                buffer.withUnsafeBytes { raw in
                    parser.append(UnsafeRawBufferPointer(rebasing: raw[0..<count]))
                }
                do {
                    while let message = try parser.nextMessage() {
                        if case .ackClipboard(let sequence) = message {
                            resolveAcknowledgement(sequence, acknowledged: true)
                        }
                        deliveryQueue.async { onMessage(message) }
                    }
                } catch {
                    parsing = false
                    lock.lock()
                    readerStoppedParsing = true
                    let waiters = takeAcknowledgementWaitersLocked()
                    lock.unlock()
                    waiters.forEach { $0.resume(returning: false) }
                }
            }
        }
    }

    /// Wakes a blocked write or read without releasing the descriptor.
    /// Idempotent; a no-op once closed.
    public func shutdown() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        Darwin.shutdown(descriptor, SHUT_RDWR)
    }

    /// Shuts the socket down, waits for the writer and the reader to let go
    /// of it, then closes it. Idempotent. Blocks briefly (the reader never
    /// runs caller code, so shutting the socket down always ends it); if
    /// the reader still has not exited after the wait, it closes the
    /// descriptor itself when it does.
    func close() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        Darwin.shutdown(descriptor, SHUT_RDWR)
        let waiters = takeAcknowledgementWaitersLocked()
        lock.unlock()
        waiters.forEach { $0.resume(returning: false) }

        writeQueue.sync {}
        _ = reading.wait(timeout: .now() + 2)

        lock.lock()
        if readerRunning {
            readerClosesDescriptor = true
            lock.unlock()
            return
        }
        lock.unlock()
        try? handle.close()
    }

    private func readerFinished() {
        lock.lock()
        readerRunning = false
        let closesDescriptor = readerClosesDescriptor
        let waiters = takeAcknowledgementWaitersLocked()
        lock.unlock()
        // No ACK can arrive any more.
        waiters.forEach { $0.resume(returning: false) }
        if closesDescriptor {
            try? handle.close()
        }
        reading.leave()
    }

    /// A fresh clipboard sequence, or nil once the channel is unusable.
    private func takeSequence() -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, !failed else { return nil }
        let sequence = nextSequence
        nextSequence &+= 1
        if nextSequence == ScrcpyControl.sequenceInvalid {
            nextSequence = 1
        }
        return sequence
    }

    /// Resumes the waiter of `sequence`, if it is still waiting. Each waiter
    /// is resumed exactly once: whoever removes it from the table resumes it.
    private func resolveAcknowledgement(_ sequence: UInt64, acknowledged: Bool) {
        lock.lock()
        let waiter = acknowledgementWaiters.removeValue(forKey: sequence)
        lock.unlock()
        waiter?.resume(returning: acknowledged)
    }

    private func takeAcknowledgementWaitersLocked() -> [CheckedContinuation<Bool, Never>] {
        let waiters = Array(acknowledgementWaiters.values)
        acknowledgementWaiters.removeAll()
        return waiters
    }

    private func writeAll(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(descriptor, base + offset, raw.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }

    private static func seconds(from duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}
