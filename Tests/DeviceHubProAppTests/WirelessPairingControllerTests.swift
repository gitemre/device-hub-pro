import XCTest
@testable import DeviceHubProApp
import DeviceHubProKit

/// `WirelessPairingController` on its own, with a stub adb and a refresh
/// spy instead of an AppModel. The device list is refreshed only after an
/// attempt paired, and only while that attempt is still the current one; a
/// cancel that lands while the refresh runs drops the result.
@MainActor
final class WirelessPairingControllerTests: XCTestCase {
    /// A pair and connect refresh once, after adb connect answered, and
    /// flash the connected address.
    func testAConnectedAttemptRefreshesOnceAfterTheConnect() async throws {
        let adb = try makeStubAdb(arms: Self.pairSucceeds + Self.connectSucceeds)
        let status = StatusCenter()
        let spy = RefreshSpy()
        let pairing = WirelessPairingController(adbClient: adb.client, status: status) {
            await spy.refresh(adbCalls: adb.calls)
        }

        let result = await pairing.pairWirelessDevice(
            address: "192.168.1.42:37000",
            code: "123456",
            connectPort: "5555"
        )

        XCTAssertEqual(result, .connected)
        XCTAssertEqual(
            spy.adbCallsAtEachRefresh,
            [["pair 192.168.1.42:37000 123456", "devices -l", "mdns services", "connect 192.168.1.42:5555"]],
            "one refresh, once adb connect has answered"
        )
        XCTAssertEqual(status.statusMessage, "Paired 192.168.1.42:5555")
        XCTAssertEqual(status.statusKind, .outcome)
        XCTAssertFalse(pairing.isPairingDevice)
    }

    /// A pair whose connect failed still paired: adb's own mDNS auto-connect
    /// may attach the phone, so the list is refreshed, but nothing flashes.
    func testAPairWhoseConnectFailedStillRefreshes() async throws {
        let adb = try makeStubAdb(arms: Self.pairSucceeds + """
          "connect 192.168.1.42:5555")
            printf 'failed to connect to 192.168.1.42:5555: Connection refused\\n' ;;
        """)
        let status = StatusCenter()
        let spy = RefreshSpy()
        let pairing = WirelessPairingController(adbClient: adb.client, status: status) {
            await spy.refresh(adbCalls: adb.calls)
        }

        let result = await pairing.pairWirelessDevice(
            address: "192.168.1.42:37000",
            code: "123456",
            connectPort: "5555"
        )

        guard case .paired(let host, _) = result else {
            return XCTFail("expected a paired result, got \(result)")
        }
        XCTAssertEqual(host, "192.168.1.42")
        XCTAssertEqual(spy.count, 1)
        XCTAssertNil(status.statusMessage, "only a connected attempt flashes")
    }

    /// Nothing was paired: no refresh.
    func testAFailedPairNeverRefreshes() async throws {
        let adb = try makeStubAdb(arms: """
          "pair 192.168.1.42:37000 123456")
            printf 'error: protocol fault (couldn'\\''t read status message): Success\\n' >&2
            exit 1 ;;
        """)
        let status = StatusCenter()
        let spy = RefreshSpy()
        let pairing = WirelessPairingController(adbClient: adb.client, status: status) {
            await spy.refresh(adbCalls: adb.calls)
        }

        let result = await pairing.pairWirelessDevice(
            address: "192.168.1.42:37000",
            code: "123456",
            connectPort: "5555"
        )

        guard case .failed = result else { return XCTFail("expected a failure, got \(result)") }
        XCTAssertEqual(spy.count, 0)
        XCTAssertNil(status.statusMessage)
        XCTAssertFalse(pairing.isPairingDevice)
    }

    /// Without adb the attempt fails before it starts: no busy state, no
    /// refresh.
    func testWithoutAdbTheAttemptFailsAndNeverRefreshes() async {
        let spy = RefreshSpy()
        let pairing = WirelessPairingController(adbClient: nil, status: StatusCenter()) {
            await spy.refresh(adbCalls: [])
        }

        let result = await pairing.pairWirelessDevice(
            address: "192.168.1.42:37000",
            code: "123456",
            connectPort: "5555"
        )

        XCTAssertEqual(result, .failed(AdbError.adbNotFound.description))
        XCTAssertEqual(spy.count, 0)
        XCTAssertFalse(pairing.isPairingDevice)
    }

    /// An attempt cancelled while adb connect runs is no longer current when
    /// its outcome lands: it refreshes nothing and flashes nothing.
    func testAnAttemptCancelledBeforeItsOutcomeNeverRefreshes() async throws {
        let adb = try makeStubAdb(arms: Self.pairSucceeds + Self.slowConnect)
        let status = StatusCenter()
        let spy = RefreshSpy()
        let pairing = WirelessPairingController(adbClient: adb.client, status: status) {
            await spy.refresh(adbCalls: adb.calls)
        }
        let attempt = Task {
            await pairing.pairWirelessDevice(
                address: "192.168.1.42:37000",
                code: "123456",
                connectPort: "5555"
            )
        }
        await waitUntil("adb connect never started") {
            adb.calls.contains("connect 192.168.1.42:5555")
        }

        pairing.cancelPairing()
        let result = await attempt.value

        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(spy.count, 0, "a cancelled attempt must not refresh the device list")
        XCTAssertNil(status.statusMessage)
        XCTAssertFalse(pairing.isPairingDevice)
    }

    /// A newer attempt supersedes one still in flight: only the newer one
    /// refreshes, and the older one's late outcome is dropped.
    func testASupersededAttemptNeverRefreshes() async throws {
        let adb = try makeStubAdb(arms: Self.pairSucceeds + Self.slowConnect + """
          "connect 192.168.1.42:41234")
            printf 'connected to 192.168.1.42:41234\\n' ;;
        """)
        let status = StatusCenter()
        let spy = RefreshSpy()
        let pairing = WirelessPairingController(adbClient: adb.client, status: status) {
            await spy.refresh(adbCalls: adb.calls)
        }
        let older = Task {
            await pairing.pairWirelessDevice(
                address: "192.168.1.42:37000",
                code: "123456",
                connectPort: "5555"
            )
        }
        await waitUntil("adb connect never started") {
            adb.calls.contains("connect 192.168.1.42:5555")
        }

        let newer = await pairing.pairWirelessDevice(
            address: "192.168.1.42:37000",
            code: "123456",
            connectPort: "41234",
            alreadyPaired: true
        )
        let late = await older.value

        XCTAssertEqual(newer, .connected)
        XCTAssertEqual(late, .cancelled)
        XCTAssertEqual(spy.count, 1, "only the current attempt refreshes")
        XCTAssertFalse(pairing.isPairingDevice)
    }

    /// A cancel that lands while the refresh is awaited drops the result:
    /// the attempt reports `.cancelled` and flashes nothing.
    func testACancelDuringTheRefreshReturnsCancelledAndFlashesNothing() async throws {
        let adb = try makeStubAdb(arms: Self.pairSucceeds + Self.connectSucceeds)
        let status = StatusCenter()
        let spy = RefreshSpy(holdsEachRefresh: true)
        let pairing = WirelessPairingController(adbClient: adb.client, status: status) {
            await spy.refresh(adbCalls: adb.calls)
        }
        let attempt = Task {
            await pairing.pairWirelessDevice(
                address: "192.168.1.42:37000",
                code: "123456",
                connectPort: "5555"
            )
        }
        await waitUntil("the refresh never started") { spy.isHolding }

        pairing.cancelPairing()
        XCTAssertFalse(pairing.isPairingDevice, "cancel clears the busy state while the refresh runs")
        spy.release()
        let result = await attempt.value

        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(spy.count, 1)
        XCTAssertNil(status.statusMessage, "a cancelled attempt must not flash \"Paired …\"")
        XCTAssertFalse(pairing.isPairingDevice)
    }

    // MARK: - Stub adb arms

    private static let pairSucceeds = """
      "pair 192.168.1.42:37000 123456")
        printf 'Successfully paired to 192.168.1.42:37000 [guid=adb-test]\\n' ;;

    """

    private static let connectSucceeds = """
      "connect 192.168.1.42:5555")
        printf 'connected to 192.168.1.42:5555\\n' ;;

    """

    /// Connect takes a second, so a test can act while it runs.
    private static let slowConnect = """
      "connect 192.168.1.42:5555")
        sleep 1
        printf 'connected to 192.168.1.42:5555\\n' ;;

    """
}

/// Stands in for `AppModel.refresh()`: counts the calls and records adb's
/// call log at each one. With `holdsEachRefresh` every refresh waits for
/// `release()`.
@MainActor
private final class RefreshSpy {
    private(set) var count = 0
    private(set) var adbCallsAtEachRefresh: [[String]] = []
    private let holdsEachRefresh: Bool
    private var held: CheckedContinuation<Void, Never>?

    init(holdsEachRefresh: Bool = false) {
        self.holdsEachRefresh = holdsEachRefresh
    }

    var isHolding: Bool { held != nil }

    func refresh(adbCalls: [String]) async {
        count += 1
        adbCallsAtEachRefresh.append(adbCalls)
        if holdsEachRefresh {
            await withCheckedContinuation { held = $0 }
        }
    }

    func release() {
        held?.resume()
        held = nil
    }
}
