import XCTest
@testable import DeviceHubProKit

final class FrameStoreTests: XCTestCase {
    private func frame(seq: UInt32 = 0, fill: UInt8 = 0) -> Frame {
        Frame(data: Data(repeating: fill, count: 16), width: 2, height: 2, seq: seq)
    }

    func testEverySnapshotGetsItsOwnGeneration() throws {
        // One-shot screenshots always carry seq 0; a renderer deduping on seq
        // would never draw the second (the repaired) one.
        let store = FrameStore()
        store.put(frame(seq: 0, fill: 1))
        let first = try XCTUnwrap(store.current)
        store.put(frame(seq: 0, fill: 2))
        let second = try XCTUnwrap(store.current)

        XCTAssertEqual(first.seq, second.seq)
        XCTAssertNotEqual(first.generation, second.generation)
        XCTAssertGreaterThan(second.generation, first.generation)
        XCTAssertEqual(store.currentGeneration, second.generation)
    }

    func testAnUnstoredFrameHasGenerationZero() {
        XCTAssertEqual(frame().generation, 0)
        XCTAssertEqual(FrameStore().currentGeneration, 0)
    }

    func testConditionalPutReplacesAnUnchangedFrame() {
        let store = FrameStore()
        store.put(frame(seq: 7, fill: 1))
        let expected = store.currentGeneration

        XCTAssertTrue(store.put(frame(seq: 0, fill: 9), ifGeneration: expected))
        XCTAssertEqual(store.current?.data.first, 9)
    }

    func testConditionalPutNeverOverwritesANewerFrame() {
        // A repair snapshot requested before a stream frame arrived must not
        // replace that newer frame.
        let store = FrameStore()
        store.put(frame(seq: 7, fill: 1))
        let expected = store.currentGeneration
        store.put(frame(seq: 8, fill: 2))

        XCTAssertFalse(store.put(frame(seq: 0, fill: 9), ifGeneration: expected))
        XCTAssertEqual(store.current?.seq, 8)
        XCTAssertEqual(store.current?.data.first, 2)
    }

    func testANewStoreNeverRepeatsAnotherStoresGeneration() throws {
        // The renderer keeps its last drawn generation when the next
        // session's store is swapped in; a short session's first frame must
        // not look already drawn.
        let previous = FrameStore()
        previous.put(frame(seq: 0, fill: 1))
        let drawn = try XCTUnwrap(previous.current).generation

        let next = FrameStore()
        next.put(frame(seq: 0, fill: 2))
        let first = try XCTUnwrap(next.current).generation
        XCTAssertNotEqual(first, drawn)
        XCTAssertGreaterThan(first, drawn)
        XCTAssertEqual(next.currentGeneration, first)
    }
}
