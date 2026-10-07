import XCTest
import GRPCCore
@testable import DeviceHubProKit

/// The shared control connection's lifetime rules. No emulator is needed: a
/// client to a port nothing serves is created (and torn down) without any
/// RPC.
final class EmulatorConnectionPoolTests: XCTestCase {
    /// Port 0: nothing can listen on it, so nothing ever answers — and no
    /// process on the Mac receives these clients' connections (any user may
    /// listen on port 1, which these tests used to dial).
    private let port = EmulatorManager.unreachableGrpcPort

    func testCallsToOnePortShareOneConnection() async throws {
        let pool = EmulatorConnectionPool()
        let first = try await pool.lease(port: port, token: nil)
        await pool.release(first.connection, discard: false)
        let second = try await pool.lease(port: port, token: nil)
        await pool.release(second.connection, discard: false)

        XCTAssertFalse(first.reused)
        XCTAssertTrue(second.reused)
        XCTAssertEqual(first.connection.id, second.connection.id)
        await pool.closeAll()
    }

    func testADiscardedConnectionIsReplaced() async throws {
        let pool = EmulatorConnectionPool()
        let first = try await pool.lease(port: port, token: nil)
        await pool.release(first.connection, discard: true)
        let second = try await pool.lease(port: port, token: nil)

        XCTAssertFalse(second.reused)
        XCTAssertNotEqual(first.connection.id, second.connection.id)
        await pool.closeAll()
    }

    func testATokenChangeOpensANewConnection() async throws {
        let pool = EmulatorConnectionPool()
        let old = try await pool.lease(port: port, token: "old")
        await pool.release(old.connection, discard: false)
        let new = try await pool.lease(port: port, token: "new")

        XCTAssertFalse(new.reused)
        XCTAssertNotEqual(old.connection.id, new.connection.id)
        XCTAssertEqual(new.connection.token, "new")
        await pool.closeAll()
    }

    func testClosingAPortDropsOnlyThatConnection() async throws {
        let pool = EmulatorConnectionPool()
        // A second key, reaching only a listener this test owns.
        let other = try makeOwnedGrpcPort()
        let a = try await pool.lease(port: port, token: nil)
        let b = try await pool.lease(port: other, token: nil)
        await pool.release(a.connection, discard: false)
        await pool.release(b.connection, discard: false)

        await pool.close(port: port)

        let closed = await pool.connectionID(port: port)
        let kept = await pool.connectionID(port: other)
        XCTAssertNil(closed)
        XCTAssertEqual(kept, b.connection.id)
        await pool.closeAll()
    }

    func testAnIdleConnectionClosesByItself() async throws {
        let pool = EmulatorConnectionPool(idleTimeout: .milliseconds(60))
        let lease = try await pool.lease(port: port, token: nil)
        await pool.release(lease.connection, discard: false)

        var closed = false
        for _ in 0..<50 where !closed {
            try await Task.sleep(for: .milliseconds(20))
            closed = await pool.connectionID(port: port) == nil
        }
        XCTAssertTrue(closed, "an unused connection must not stay open")
    }

    func testAConnectionInUseIsNotSweptAsIdle() async throws {
        let pool = EmulatorConnectionPool(idleTimeout: .milliseconds(40))
        let lease = try await pool.lease(port: port, token: nil)
        try await Task.sleep(for: .milliseconds(200))

        let id = await pool.connectionID(port: port)
        XCTAssertEqual(id, lease.connection.id, "a leased connection is busy, not idle")
        await pool.release(lease.connection, discard: false)
        await pool.closeAll()
    }

    func testAStaleSharedConnectionIsRetriedOnceOnAFreshOne() async throws {
        let pool = EmulatorConnectionPool()
        // Warm the connection so the next call runs on a reused one.
        _ = try await EmulatorControl.withSharedClient(port: port, pool: pool) { _ in 0 }
        let warmID = await pool.connectionID(port: port)

        final class Calls: @unchecked Sendable { var count = 0 }
        let calls = Calls()
        let value = try await EmulatorControl.withSharedClient(
            port: port,
            pool: pool,
            retryOnStaleConnection: true
        ) { _ in
            calls.count += 1
            if calls.count == 1 {
                throw RPCError(code: .unavailable, message: "connection reset")
            }
            return 42
        }

        XCTAssertEqual(value, 42)
        XCTAssertEqual(calls.count, 2)
        let freshID = await pool.connectionID(port: port)
        XCTAssertNotNil(freshID)
        XCTAssertNotEqual(freshID, warmID)
        await pool.closeAll()
    }

    func testACallThatIsNotSafeToRepeatIsNeverRetried() async throws {
        // An incoming SMS, a rotation by a delta or typed text: the emulator
        // may have acted before the connection dropped, so a rerun could
        // apply it twice.
        let pool = EmulatorConnectionPool()
        _ = try await EmulatorControl.withSharedClient(port: port, pool: pool) { _ in 0 }
        let warmID = await pool.connectionID(port: port)

        final class Calls: @unchecked Sendable { var count = 0 }
        let calls = Calls()
        do {
            _ = try await EmulatorControl.withSharedClient(port: port, pool: pool) { _ -> Int in
                calls.count += 1
                throw RPCError(code: .unavailable, message: "connection reset")
            }
            XCTFail("the failure must reach the caller")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, .unavailable)
        }
        XCTAssertEqual(calls.count, 1)
        let id = await pool.connectionID(port: port)
        XCTAssertNotEqual(id, warmID, "the stale connection is still dropped, so the next call reconnects")
        await pool.closeAll()
    }

    func testAFailureOnAFreshConnectionIsNotRetried() async throws {
        let pool = EmulatorConnectionPool()
        final class Calls: @unchecked Sendable { var count = 0 }
        let calls = Calls()
        do {
            _ = try await EmulatorControl.withSharedClient(
                port: port,
                pool: pool,
                retryOnStaleConnection: true
            ) { _ -> Int in
                calls.count += 1
                throw RPCError(code: .unavailable, message: "refused")
            }
            XCTFail("an unreachable port must throw")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, .unavailable)
        }
        XCTAssertEqual(calls.count, 1)
        let id = await pool.connectionID(port: port)
        XCTAssertNil(id, "the refused connection is dropped")
    }

    func testOtherErrorsKeepTheConnection() async throws {
        let pool = EmulatorConnectionPool()
        _ = try await EmulatorControl.withSharedClient(port: port, pool: pool) { _ in 0 }
        let before = await pool.connectionID(port: port)
        _ = try? await EmulatorControl.withSharedClient(port: port, pool: pool) { _ -> Int in
            throw RPCError(code: .deadlineExceeded, message: "slow")
        }
        let after = await pool.connectionID(port: port)
        XCTAssertEqual(before, after, "a slow call is not a dead connection")
        await pool.closeAll()
    }

    func testOnlyUnavailableCountsAsAConnectionFailure() {
        XCTAssertTrue(EmulatorControl.isConnectionFailure(RPCError(code: .unavailable, message: "")))
        XCTAssertFalse(EmulatorControl.isConnectionFailure(RPCError(code: .deadlineExceeded, message: "")))
        XCTAssertFalse(EmulatorControl.isConnectionFailure(RPCError(code: .internalError, message: "")))
        XCTAssertFalse(EmulatorControl.isConnectionFailure(AdbError.adbNotFound))
    }
}
