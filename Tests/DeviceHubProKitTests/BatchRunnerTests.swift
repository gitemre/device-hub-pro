import XCTest
@testable import DeviceHubProKit

/// `BatchRunner`: one piece of work per device, side by side up to a bound,
/// each ending succeeded, failed, skipped or cancelled.
final class BatchRunnerTests: XCTestCase {
    private struct Boom: Error, CustomStringConvertible {
        var description: String { "boom" }
    }

    /// The peak number of pieces of work running at once.
    private actor Gauge {
        private(set) var current = 0
        private(set) var peak = 0

        func enter() {
            current += 1
            peak = max(peak, current)
        }

        func leave() {
            current -= 1
        }
    }

    private actor Journal {
        private(set) var entries: [String] = []

        func note(_ entry: String) {
            entries.append(entry)
        }
    }

    private func label<Output: Sendable>(_ outcome: BatchItemOutcome<Output>?) -> String {
        switch outcome {
        case .succeeded(let output)?: "succeeded \(output)"
        case .failed(let message)?: "failed \(message)"
        case .skipped(let reason)?: "skipped \(reason)"
        case .cancelled?: "cancelled"
        case nil: "missing"
        }
    }

    func testEveryDeviceSucceedsWithItsOwnOutput() async {
        let outcomes = await BatchRunner.run(["a", "b", "c"]) { id -> String in
            id.uppercased()
        }
        XCTAssertEqual(["a", "b", "c"].map { label(outcomes[$0]) }, ["succeeded A", "succeeded B", "succeeded C"])
        XCTAssertTrue(outcomes.values.allSatisfy(\.isSuccess))
    }

    func testASkipIsNotAFailureAndAFailureIsDescribed() async {
        let outcomes = await BatchRunner.run(["ok", "skip", "fail"]) { id -> String in
            switch id {
            case "skip": throw BatchSkip("Needs an iOS simulator")
            case "fail": throw Boom()
            default: return id
            }
        }
        XCTAssertEqual(label(outcomes["ok"]), "succeeded ok")
        XCTAssertEqual(label(outcomes["skip"]), "skipped Needs an iOS simulator")
        XCTAssertEqual(label(outcomes["fail"]), "failed boom")
        XCTAssertFalse(outcomes["skip"]?.isSuccess ?? true)
    }

    func testTheCallerDescribesErrors() async {
        let outcomes = await BatchRunner.run([1], describe: { _ in "described" }) { _ -> Int in
            throw Boom()
        }
        XCTAssertEqual(label(outcomes[1]), "failed described")
    }

    func testNoMoreThanTheBoundRunAtOnce() async {
        let gauge = Gauge()
        let outcomes = await BatchRunner.run(Array(0..<9), maxConcurrent: 3) { id -> Int in
            await gauge.enter()
            try await Task.sleep(for: .milliseconds(30))
            await gauge.leave()
            return id
        }
        let peak = await gauge.peak
        XCTAssertLessThanOrEqual(peak, 3)
        XCTAssertGreaterThan(peak, 1, "the work should overlap")
        XCTAssertEqual(outcomes.count, 9)
        XCTAssertTrue(outcomes.values.allSatisfy(\.isSuccess))
    }

    func testABoundBelowOneRunsOneAtATime() async {
        let gauge = Gauge()
        _ = await BatchRunner.run(Array(0..<4), maxConcurrent: 0) { id -> Int in
            await gauge.enter()
            try await Task.sleep(for: .milliseconds(5))
            await gauge.leave()
            return id
        }
        let peak = await gauge.peak
        XCTAssertEqual(peak, 1)
    }

    func testDevicesStartInTheOrderGivenAndReportTheirEnd() async {
        let journal = Journal()
        _ = await BatchRunner.run(
            ["c", "a", "b"],
            maxConcurrent: 1,
            onStart: { id in await journal.note("start \(id)") },
            onFinish: { (id: String, outcome: BatchItemOutcome<String>) in
                await journal.note("end \(id) \(outcome.isSuccess)")
            }
        ) { id -> String in
            id
        }
        let entries = await journal.entries
        XCTAssertEqual(entries, ["start c", "end c true", "start a", "end a true", "start b", "end b true"])
    }

    /// A cancel ends the work in flight (a sleep here, a child process in
    /// the app) and starts no more; every device still gets an outcome and
    /// an `onFinish`.
    func testACancelStopsTheWorkInFlightAndStartsNoMore() async {
        let (started, startedContinuation) = AsyncStream.makeStream(of: Int.self)
        let journal = Journal()
        let batch = Task {
            await BatchRunner.run(
                [1, 2, 3, 4],
                maxConcurrent: 2,
                onStart: { id in startedContinuation.yield(id) },
                onFinish: { id, _ in await journal.note("end \(id)") }
            ) { id -> Int in
                try await Task.sleep(for: .seconds(30))
                return id
            }
        }
        var iterator = started.makeAsyncIterator()
        let first = await iterator.next()
        let second = await iterator.next()
        XCTAssertEqual(Set([first, second].compactMap { $0 }), [1, 2])
        batch.cancel()
        let outcomes = await batch.value
        startedContinuation.finish()

        XCTAssertEqual([1, 2, 3, 4].map { label(outcomes[$0]) }, Array(repeating: "cancelled", count: 4))
        let ended = await journal.entries
        XCTAssertEqual(Set(ended), ["end 1", "end 2", "end 3", "end 4"])
        XCTAssertEqual(ended.count, 4)
    }
}

/// `BatchReport`: Device Hub's aggregated result, device by device.
final class BatchReportTests: XCTestCase {
    private func collect(_ outcomes: [String: BatchItemOutcome<Void>], order: [String]) -> BatchReport {
        BatchReport(order, outcomes: outcomes) { $0 }
    }

    func testTheReportKeepsTheSelectionsOrder() {
        let report = collect(
            ["b": .failed("boom"), "a": .succeeded(()), "c": .skipped("Offline"), "d": .cancelled],
            order: ["d", "c", "b", "a", "e"]
        )
        XCTAssertEqual(report.succeeded, ["a"])
        XCTAssertEqual(report.failed, [BatchReport.Entry(name: "b", message: "boom")])
        XCTAssertEqual(report.skipped, [BatchReport.Entry(name: "c", message: "Offline")])
        // A device without an outcome never ran to its end.
        XCTAssertEqual(report.cancelled, ["d", "e"])
        XCTAssertEqual(report.total, 5)
    }

    func testHeadlines() {
        XCTAssertEqual(BatchReport(succeeded: ["a"]).headline, "Done on 1 device")
        XCTAssertEqual(BatchReport(succeeded: ["a", "b", "c", "d"]).headline, "Done on all 4 devices")
        XCTAssertEqual(BatchReport(skipped: [.init(name: "a", message: "Offline")]).headline, "Skipped the device")
        XCTAssertEqual(
            BatchReport(skipped: [.init(name: "a", message: "Offline"), .init(name: "b", message: "Offline")]).headline,
            "Skipped all 2 devices"
        )
        XCTAssertEqual(
            BatchReport(succeeded: ["a", "b", "c"], failed: [.init(name: "d", message: "boom")]).headline,
            "Done on 3 of 4 devices · 1 failed"
        )
        XCTAssertEqual(
            BatchReport(
                succeeded: ["a"],
                failed: [.init(name: "b", message: "boom")],
                skipped: [.init(name: "c", message: "Offline")],
                cancelled: ["d"]
            ).headline,
            "Done on 1 of 4 devices · 1 failed · 1 skipped · 1 cancelled"
        )
        XCTAssertEqual(BatchReport(succeeded: ["a"], cancelled: ["b", "c"]).headline, "Done on 1 of 3 devices · 2 cancelled")
        XCTAssertEqual(BatchReport(failed: [.init(name: "a", message: "boom")]).headline, "Done on 0 of 1 device · 1 failed")
    }

    func testTheFailuresMakeOneError() {
        XCTAssertNil(BatchReport(succeeded: ["a"], skipped: [.init(name: "b", message: "Offline")]).error)
        let one = BatchReport(failed: [.init(name: "Pixel 9", message: "adb: device offline")]).error
        XCTAssertEqual(one?.description, "Failed on 1 device:\nPixel 9: adb: device offline")
        let two = BatchReport(failed: [.init(name: "Pixel 9", message: "boom"), .init(name: "iPhone 17", message: "bang")]).error
        XCTAssertEqual(two?.description, "Failed on 2 devices:\nPixel 9: boom\niPhone 17: bang")
    }
}
