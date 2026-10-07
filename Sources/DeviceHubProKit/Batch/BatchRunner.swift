import Foundation

/// How one device's part of a batch ended.
public enum BatchItemOutcome<Output: Sendable>: Sendable {
    case succeeded(Output)
    case failed(String)
    /// Not run, and why: the plan skipped it, or its mechanism found at run
    /// time that it cannot take the action (`BatchSkip`).
    case skipped(String)
    /// Stopped by a cancel, before or while it ran.
    case cancelled

    public var isSuccess: Bool {
        if case .succeeded = self { return true }
        return false
    }
}

/// Thrown by a device's work when it finds, as it runs, that the device
/// cannot take the action (a simulator build of another platform): a skip,
/// not a failure.
public struct BatchSkip: Error, Equatable, Sendable, CustomStringConvertible {
    public let reason: String

    public init(_ reason: String) {
        self.reason = reason
    }

    public var description: String { reason }
}

/// Runs one piece of work per device side by side, at most `maxConcurrent`
/// at a time, in the order given, and reports each device as it starts and
/// ends. A cancel of the calling task stops the work in flight (a
/// `ProcessRunner` child is terminated) and starts no more: those devices
/// end `cancelled`.
public enum BatchRunner {
    /// Four at a time:'s bound is four mixed devices in 5 s, and
    /// every device's work is a child process or two.
    public static let defaultConcurrency = 4

    public static func run<ID: Hashable & Sendable, Output: Sendable>(
        _ ids: [ID],
        maxConcurrent: Int = defaultConcurrency,
        describe: @escaping @Sendable (any Error) -> String = { "\($0)" },
        onStart: @escaping @Sendable (ID) async -> Void = { _ in },
        onFinish: @escaping @Sendable (ID, BatchItemOutcome<Output>) async -> Void = { _, _ in },
        work: @escaping @Sendable (ID) async throws -> Output
    ) async -> [ID: BatchItemOutcome<Output>] {
        var outcomes: [ID: BatchItemOutcome<Output>] = [:]
        let limit = max(1, maxConcurrent)
        await withTaskGroup(of: (ID, BatchItemOutcome<Output>).self) { group in
            var next = ids.startIndex
            var running = 0
            while next < ids.endIndex, running < limit {
                let id = ids[next]
                group.addTask { await runOne(id, describe: describe, onStart: onStart, work: work) }
                next += 1
                running += 1
            }
            while let (id, outcome) = await group.next() {
                running -= 1
                outcomes[id] = outcome
                await onFinish(id, outcome)
                if !Task.isCancelled, next < ids.endIndex {
                    let id = ids[next]
                    group.addTask { await runOne(id, describe: describe, onStart: onStart, work: work) }
                    next += 1
                    running += 1
                }
            }
        }
        for id in ids where outcomes[id] == nil {
            outcomes[id] = .cancelled
            await onFinish(id, .cancelled)
        }
        return outcomes
    }

    private static func runOne<ID: Sendable, Output: Sendable>(
        _ id: ID,
        describe: @Sendable (any Error) -> String,
        onStart: @Sendable (ID) async -> Void,
        work: @Sendable (ID) async throws -> Output
    ) async -> (ID, BatchItemOutcome<Output>) {
        guard !Task.isCancelled else { return (id, .cancelled) }
        await onStart(id)
        do {
            let output = try await work(id)
            return (id, Task.isCancelled ? .cancelled : .succeeded(output))
        } catch let skip as BatchSkip {
            return (id, .skipped(skip.reason))
        } catch is CancellationError {
            return (id, .cancelled)
        } catch {
            // A child process a cancel terminated fails in its own words.
            return (id, Task.isCancelled ? .cancelled : .failed(describe(error)))
        }
    }
}

/// What a batch did, device by device, in the selection's order: Device
/// Hub's aggregated result (successes plus one error naming each
/// device that failed).
public struct BatchReport: Sendable, Equatable {
    /// A device and what happened to it.
    public struct Entry: Sendable, Equatable {
        public let name: String
        public let message: String

        public init(name: String, message: String) {
            self.name = name
            self.message = message
        }
    }

    public var succeeded: [String] = []
    public var failed: [Entry] = []
    public var skipped: [Entry] = []
    public var cancelled: [String] = []

    public init(succeeded: [String] = [], failed: [Entry] = [], skipped: [Entry] = [], cancelled: [String] = []) {
        self.succeeded = succeeded
        self.failed = failed
        self.skipped = skipped
        self.cancelled = cancelled
    }

    /// Collects `outcomes` in the order of `ids`, each named by `name`.
    public init<ID: Hashable, Output>(
        _ ids: [ID],
        outcomes: [ID: BatchItemOutcome<Output>],
        name: (ID) -> String
    ) {
        for id in ids {
            switch outcomes[id] {
            case .succeeded?: succeeded.append(name(id))
            case .failed(let message)?: failed.append(Entry(name: name(id), message: message))
            case .skipped(let reason)?: skipped.append(Entry(name: name(id), message: reason))
            case .cancelled?, nil: cancelled.append(name(id))
            }
        }
    }

    public var total: Int { succeeded.count + failed.count + skipped.count + cancelled.count }

    /// The failures as one error, nil when none failed.
    public var error: BatchAggregateError? {
        failed.isEmpty ? nil : BatchAggregateError(failures: failed)
    }

    /// One line: "Done on all 4 devices", "Done on 3 of 4 devices · 1
    /// failed", "Skipped all 2 devices", "Done on 1 of 3 devices · 2
    /// cancelled".
    public var headline: String {
        var parts: [String] = []
        if succeeded.count == total, total > 0 {
            parts.append(total == 1 ? "Done on 1 device" : "Done on all \(total) devices")
        } else if skipped.count == total, total > 0 {
            parts.append(total == 1 ? "Skipped the device" : "Skipped all \(total) devices")
        } else {
            parts.append("Done on \(succeeded.count) of \(total) \(total == 1 ? "device" : "devices")")
            if !failed.isEmpty { parts.append("\(failed.count) failed") }
            if !skipped.isEmpty { parts.append("\(skipped.count) skipped") }
            if !cancelled.isEmpty { parts.append("\(cancelled.count) cancelled") }
        }
        return parts.joined(separator: " · ")
    }
}

/// The devices a batch failed on, each with its own error: Device Hub's
/// aggregated error ("Failed to start 2 devices").
public struct BatchAggregateError: Error, Equatable, Sendable, CustomStringConvertible {
    public let failures: [BatchReport.Entry]

    public init(failures: [BatchReport.Entry]) {
        self.failures = failures
    }

    public var description: String {
        let count = failures.count == 1 ? "1 device" : "\(failures.count) devices"
        return (["Failed on \(count):"] + failures.map { "\($0.name): \($0.message)" }).joined(separator: "\n")
    }
}
