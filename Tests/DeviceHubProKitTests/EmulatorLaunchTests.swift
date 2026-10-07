import XCTest
@testable import DeviceHubProKit

/// Emulator launch helpers: the command line and gRPC port allocation.
final class EmulatorLaunchTests: XCTestCase {
    // MARK: Quick boot

    /// Launches boot from the quick-boot snapshot by default: neither
    /// snapshot flag is passed, so the emulator loads its snapshot and saves
    /// one on a clean exit, as Android Studio's Quick Boot does.
    func testLaunchQuickBootsByDefault() {
        let arguments = EmulatorManager.launchArguments(
            avd: "Pixel_9",
            grpcPort: 8554,
            audioEnabled: true,
            coldBoot: false
        )
        XCTAssertEqual(arguments, [
            "-avd", "Pixel_9",
            "-grpc", "8554",
            "-gpu", "host",
            "-no-boot-anim",
            "-qt-hide-window",
        ])
        XCTAssertFalse(arguments.contains("-no-snapshot-load"))
        XCTAssertFalse(arguments.contains("-no-snapshot-save"))
    }

    /// A cold boot skips loading the snapshot for this launch only and still
    /// saves a fresh one, so the next launch is quick again.
    func testColdBootSkipsTheSnapshotLoadButStillSaves() {
        let arguments = EmulatorManager.launchArguments(
            avd: "Pixel_9",
            grpcPort: 8556,
            audioEnabled: false,
            coldBoot: true
        )
        XCTAssertTrue(arguments.contains("-no-snapshot-load"))
        XCTAssertFalse(arguments.contains("-no-snapshot-save"))
        XCTAssertTrue(arguments.contains("-no-audio"))
        XCTAssertEqual(arguments.firstIndex(of: "-grpc").map { arguments[$0 + 1] }, "8556")
    }

    /// Token auth is opt-in until the caller reads the discovery file (F17).
    func testGrpcTokenAuthIsOptIn() {
        XCTAssertFalse(
            EmulatorManager.launchArguments(avd: "A", grpcPort: 8554, audioEnabled: true, coldBoot: false)
                .contains("-grpc-use-token")
        )
        let secured = EmulatorManager.launchArguments(
            avd: "A",
            grpcPort: 8554,
            audioEnabled: true,
            coldBoot: false,
            grpcTokenAuth: true
        )
        XCTAssertTrue(secured.contains("-grpc-use-token"))
        XCTAssertEqual(secured.firstIndex(of: "-grpc").map { secured[$0 + 1] }, "8554")
    }

    // MARK: gRPC port reservation (F10)

    /// The emulator binds its gRPC port seconds after launch, so two launches
    /// inside that window must not both be handed the same still-free port.
    func testConsecutiveLaunchesGetDistinctPortsBeforeEitherBinds() {
        let start = 47_310
        let first = EmulatorManager.firstFreePort(startingAt: start, limit: 8)
        let second = EmulatorManager.firstFreePort(startingAt: start, limit: 8)
        defer {
            EmulatorManager.releasePortReservation(first)
            EmulatorManager.releasePortReservation(second)
        }
        XCTAssertNotEqual(first, second, "a reserved port must not be handed out twice")
        XCTAssertTrue((start..<(start + 8)).contains(first))
        XCTAssertTrue((start..<(start + 8)).contains(second))
    }

    func testReleasedPortIsHandedOutAgain() {
        let start = 47_330
        let first = EmulatorManager.firstFreePort(startingAt: start, limit: 8)
        EmulatorManager.releasePortReservation(first)
        let again = EmulatorManager.firstFreePort(startingAt: start, limit: 8)
        defer { EmulatorManager.releasePortReservation(again) }
        XCTAssertEqual(again, first)
    }

    func testReservationsLapseAndSkipRejectedPorts() {
        let reservations = PortReservations()
        XCTAssertEqual(reservations.reserveFirst(in: 10..<13, for: .seconds(60), where: { $0 != 10 }), 11)
        XCTAssertEqual(reservations.reserveFirst(in: 10..<13, for: .seconds(60), where: { $0 != 10 }), 12)
        XCTAssertNil(reservations.reserveFirst(in: 10..<13, for: .seconds(60), where: { $0 != 10 }))
        // An expired window frees its port without an explicit release.
        XCTAssertEqual(reservations.reserveFirst(in: 20..<21, for: .zero, where: { _ in true }), 20)
        XCTAssertEqual(reservations.reserveFirst(in: 20..<21, for: .seconds(60), where: { _ in true }), 20)
    }
}
