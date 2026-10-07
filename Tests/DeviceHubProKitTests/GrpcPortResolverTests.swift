import XCTest
@testable import DeviceHubProKit

final class GrpcPortResolverTests: XCTestCase {
    private func vm(_ avd: String, pid: Int32, port: Int?) -> RunningEmulator {
        RunningEmulator(avd: avd, processID: pid, grpcPort: port)
    }

    // MARK: Ladder

    func testDiscoveryWinsEvenWithRunningVMs() {
        let resolution = GrpcPortResolver.resolve(
            discovery: EmulatorGRPCInfo(port: 8556, token: "jwt"),
            avdName: "Pixel_7_API_34",
            running: [vm("Pixel_7_API_34", pid: 1, port: 8554)],
            liveScanPorts: [8558]
        )
        XCTAssertEqual(resolution, .discovery(8556))
    }

    func testProcessMatchBindsByName() {
        let resolution = GrpcPortResolver.resolve(
            discovery: nil,
            avdName: "Pixel_7_API_34",
            running: [vm("Pixel_7_API_34", pid: 1, port: 8558), vm("Pixel_Tablet", pid: 2, port: 8556)],
            liveScanPorts: []
        )
        XCTAssertEqual(resolution, .processMatch(8558))
    }

    func testMixedIdentityEmulatorsNeverCrossBind() {
        // Android-Studio VM (no `-grpc`, discovery read failed) next to an
        // app-started one: two identities, no unique answer — fail closed.
        let resolution = GrpcPortResolver.resolve(
            discovery: nil,
            avdName: "Studio_VM",
            running: [vm("Studio_VM", pid: 1, port: nil), vm("Pixel_7_API_34", pid: 2, port: 8554)],
            liveScanPorts: [8554, 8556]
        )
        XCTAssertEqual(resolution.port, nil)
        guard case .unresolved = resolution else {
            return XCTFail("expected .unresolved, got \(resolution)")
        }
    }

    /// The target's name is known but its VM is not in the parsed list (a
    /// command line `ps` parsing misses, no discovery file): the one VM that
    /// *is* listed is another AVD, and its port must not be taken (F9).
    func testKnownNameMatchingNoVMNeverBindsTheOnlyOtherVM() {
        let resolution = GrpcPortResolver.resolve(
            discovery: nil,
            avdName: "A",
            running: [vm("B", pid: 2, port: 8554)],
            liveScanPorts: [8554]
        )
        guard case .unresolved = resolution else {
            return XCTFail("A's serial must not bind B's port, got \(resolution)")
        }
        XCTAssertFalse(GrpcPortResolver.needsScan(
            discovery: nil,
            avdName: "A",
            running: [vm("B", pid: 2, port: nil)]
        ), "a scan could only find B's port")
        guard case .unresolved = GrpcPortResolver.resolve(
            discovery: nil,
            avdName: "A",
            running: [vm("B", pid: 2, port: nil)],
            liveScanPorts: [8554]
        ) else {
            return XCTFail("a scanned port of B's must not bind A either")
        }
    }

    /// The lone VM that is the named target still resolves, by its parsed
    /// port or — without one — by a single live scanned port.
    func testKnownNameMatchingTheOnlyVMStillResolves() {
        XCTAssertEqual(
            GrpcPortResolver.resolve(
                discovery: nil, avdName: "A",
                running: [vm("A", pid: 1, port: 8556)], liveScanPorts: []
            ),
            .processMatch(8556)
        )
        XCTAssertTrue(GrpcPortResolver.needsScan(
            discovery: nil, avdName: "A", running: [vm("A", pid: 1, port: nil)]
        ))
        XCTAssertEqual(
            GrpcPortResolver.resolve(
                discovery: nil, avdName: "A",
                running: [vm("A", pid: 1, port: nil)], liveScanPorts: [8558]
            ),
            .scan(8558)
        )
    }

    func testSingleVMScanAcceptsOneLivePort() {
        let resolution = GrpcPortResolver.resolve(
            discovery: nil,
            avdName: nil,
            running: [vm("Pixel_7_API_34", pid: 1, port: nil)],
            liveScanPorts: [8558]
        )
        XCTAssertEqual(resolution, .scan(8558))
    }

    func testSingleVMWithParsedPortBindsWithoutScan() {
        let resolution = GrpcPortResolver.resolve(
            discovery: nil,
            avdName: nil,
            running: [vm("Pixel_7_API_34", pid: 1, port: 8554)],
            liveScanPorts: []
        )
        XCTAssertEqual(resolution, .processMatch(8554))
    }

    func testScanWithZeroOrManyHitsFailsClosed() {
        XCTAssertEqual(
            GrpcPortResolver.resolve(
                discovery: nil, avdName: nil,
                running: [vm("A", pid: 1, port: nil)], liveScanPorts: [8554, 8556]
            ).port,
            nil
        )
        XCTAssertEqual(
            GrpcPortResolver.resolve(
                discovery: nil, avdName: nil,
                running: [vm("A", pid: 1, port: nil)], liveScanPorts: []
            ).port,
            nil
        )
    }

    func testNeedsScanMatrix() {
        XCTAssertFalse(GrpcPortResolver.needsScan(
            discovery: EmulatorGRPCInfo(port: 8556, token: nil), avdName: nil, running: []
        ))
        XCTAssertTrue(GrpcPortResolver.needsScan(
            discovery: nil, avdName: nil, running: [vm("A", pid: 1, port: nil)]
        ))
        XCTAssertFalse(GrpcPortResolver.needsScan(
            discovery: nil, avdName: nil, running: [vm("A", pid: 1, port: 8554)]
        ))
        XCTAssertFalse(GrpcPortResolver.needsScan(
            discovery: nil, avdName: nil,
            running: [vm("A", pid: 1, port: nil), vm("B", pid: 2, port: nil)]
        ))
    }

    // MARK: Cache

    func testCacheStoresAndInvalidatesPerSerial() {
        var cache = GrpcPortCache()
        cache.store(8554, for: "emulator-5554")
        cache.store(8556, for: "emulator-5556")
        cache.invalidate(serial: "emulator-5554")
        XCTAssertNil(cache.port(for: "emulator-5554"))
        XCTAssertEqual(cache.port(for: "emulator-5556"), 8556)
    }

    func testInvalidateMissingFromDropsAbsentSerials() {
        var cache = GrpcPortCache()
        cache.store(8554, for: "emulator-5554")
        cache.store(8556, for: "emulator-5556")
        cache.invalidate(missingFrom: ["emulator-5556"])
        XCTAssertNil(cache.port(for: "emulator-5554"))
        XCTAssertEqual(cache.port(for: "emulator-5556"), 8556)
    }

    func testInvalidateAllDropsEveryEntry() {
        var cache = GrpcPortCache()
        cache.store(8554, for: "emulator-5554")
        cache.invalidateAll()
        XCTAssertNil(cache.port(for: "emulator-5554"))
    }
}
