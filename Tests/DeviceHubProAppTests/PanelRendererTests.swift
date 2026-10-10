import Foundation
import Synchronization
import XCTest
@testable import DeviceHubProApp

/// The 3D stage's panel renderer calls its handler after every drawn frame.
final class PanelRendererTests: XCTestCase {
    /// Thousands of frames leave the handler's call as shallow as the first:
    /// a closure read out of a `Mutex` with `withLock { $0 }` gained two
    /// thunk frames a read and overflowed the drawing thread's stack.
    func testTheHandlerDoesNotDeepenFrameAfterFrame() {
        let renderer = PanelRenderer()
        let depths = Mutex<[Int]>([])
        renderer.setPresented { depths.withLock { $0.append(Thread.callStackReturnAddresses.count) } }
        renderer.notifyPresented()
        for _ in 0..<5_000 { renderer.notifyPresented() }
        let seen = depths.withLock { $0 }
        XCTAssertEqual(seen.count, 5_001)
        XCTAssertEqual(seen.last, seen.first)
    }
}
