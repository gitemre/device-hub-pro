import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// `GrpcPortService` on its own, over a stub adb: which answer wins, what
/// it records, and what a cancelled or unresolvable lookup reports.
@MainActor
final class GrpcPortServiceTests: XCTestCase {
    private let emulator = AndroidDevice.online("emulator-5554", transport: "3")

    /// A service on `adb` and an emulator binary that is never run (the
    /// process list is read with `ps`, and holds only this process's VMs, so
    /// no VM running on the Mac is matched or probed); the console's AVD name
    /// comes from `avdName`, and each lookup is counted.
    private func makeService(
        adb: StubAdb,
        avdName: @escaping @MainActor () -> String?
    ) -> (GrpcPortService, LookupCounter) {
        let service = GrpcPortService(adbClient: adb.client)
        let lookups = LookupCounter()
        service.emulatorManagerProvider = { EmulatorManager.inert }
        service.consoleAvdName = { _ in
            lookups.count += 1
            return avdName()
        }
        return (service, lookups)
    }

    /// How often the service asked for a console's AVD name.
    @MainActor
    private final class LookupCounter {
        var count = 0
    }

    /// An adb whose console points `emulator-5554` at a discovery file
    /// naming `port` (no token).
    private func discoveryAdb(port: Int) throws -> StubAdb {
        let discovery = FileManager.default.temporaryDirectory
            .appendingPathComponent("discovery-\(UUID().uuidString).ini")
        try Data("grpc.port=\(port)\n".utf8).write(to: discovery)
        addTeardownBlock { try? FileManager.default.removeItem(at: discovery) }
        return try makeStubAdb(arms: """
          "-s emulator-5554 emu avd discoverypath")
            printf '%s\\r\\nOK\\r\\n' "\(discovery.path)" ;;
        """)
    }

    /// A recorded port is the answer: nothing is asked, not the console,
    /// not the process list.
    func testARecordedPortWins() async throws {
        let adb = try makeStubAdb(arms: "")
        let (service, lookups) = makeService(adb: adb) { "Pixel_A" }
        service.store(8601, for: emulator.serial)

        let result = await service.resolveGrpcPort(for: emulator)

        XCTAssertEqual(try result.get(), 8601)
        XCTAssertTrue(adb.calls.isEmpty, "a recorded port asks adb nothing")
        XCTAssertEqual(lookups.count, 0)
    }

    /// The discovery file's port wins and is recorded: the next lookup asks
    /// nothing.
    func testADiscoveredPortIsRecorded() async throws {
        let adb = try discoveryAdb(port: 8697)
        let (service, _) = makeService(adb: adb) { "Pixel_A" }

        let first = await service.resolveGrpcPort(for: emulator)
        XCTAssertEqual(try first.get(), 8697)
        XCTAssertEqual(service.port(for: emulator.serial), 8697)

        let second = await service.resolveGrpcPort(for: emulator)
        XCTAssertEqual(try second.get(), 8697)
        XCTAssertEqual(adb.calls(containing: "avd discoverypath").count, 1)
    }

    /// A lookup cancelled while it resolves reports no port and records
    /// none, although the discovery file named one: its answers may be the
    /// cancellation's, not the emulator's.
    func testACancelledResolutionIsNotRecorded() async throws {
        let adb = try discoveryAdb(port: 8697)
        // The console lookup runs after the discovery read and the process
        // list; the lookup cancels its own task there.
        let (service, lookups) = makeService(adb: adb) {
            withUnsafeCurrentTask { $0?.cancel() }
            return "Pixel_A"
        }

        let result = await Task { await service.resolveGrpcPort(for: emulator) }.value

        XCTAssertEqual(lookups.count, 1, "the lookup ran, and cancelled the resolution")
        guard case .failure(let failure) = result else {
            return XCTFail("a cancelled resolution reported \(result)")
        }
        XCTAssertNil(failure.reason, "a cancelled resolution stays silent")
        XCTAssertNil(service.port(for: emulator.serial))
    }

    /// With no discovery file and no running VM of the console's AVD, the
    /// resolver's reason is reported (the lookup fails closed) and nothing
    /// is recorded.
    func testAnUnidentifiedEmulatorSurfacesTheResolversReason() async throws {
        let adb = try makeStubAdb(arms: "")
        let avd = "DeviceHubPro_NotRunning_\(UUID().uuidString.prefix(8))"
        let (service, _) = makeService(adb: adb) { avd }

        let result = await service.resolveGrpcPort(for: emulator)

        guard case .failure(let failure) = result else {
            return XCTFail("an unidentified emulator resolved to \(result)")
        }
        XCTAssertEqual(failure.reason, GrpcPortResolver.unresolvedMessage)
        XCTAssertNil(service.port(for: emulator.serial))
    }

    /// Without adb or an emulator there is nothing to ask: no reason, and
    /// not even a recorded port.
    func testWithoutToolsNothingResolves() async throws {
        let service = GrpcPortService(adbClient: nil)
        service.emulatorManagerProvider = { EmulatorManager.inert }
        service.store(8601, for: emulator.serial)

        let result = await service.resolveGrpcPort(for: emulator)

        guard case .failure(let failure) = result else {
            return XCTFail("a service without adb resolved to \(result)")
        }
        XCTAssertNil(failure.reason)
    }

    /// The recorded ports are forgotten per serial, for the serials missing
    /// from a snapshot, or all at once.
    func testRecordedPortsAreForgotten() {
        let service = GrpcPortService(adbClient: nil)
        service.store(8554, for: "emulator-5554")
        service.store(8556, for: "emulator-5556")
        service.store(8558, for: "emulator-5558")

        service.invalidate(serial: "emulator-5554")
        XCTAssertNil(service.port(for: "emulator-5554"))
        XCTAssertEqual(service.port(for: "emulator-5556"), 8556)

        service.invalidate(missingFrom: ["emulator-5556"])
        XCTAssertEqual(service.port(for: "emulator-5556"), 8556)
        XCTAssertNil(service.port(for: "emulator-5558"))

        service.invalidateAll()
        XCTAssertNil(service.port(for: "emulator-5556"))
    }
}
