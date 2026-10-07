import XCTest
import CoreImage
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// The Pair Nearby Device sheet's logic: the
/// inventory's pairing of a listed, unpaired iPhone (`devicectl manage pair`,
/// a stub devicectl; nothing here reaches a device), the QR flow of the
/// wireless controller (a stub adb), and the QR image itself.
@MainActor
final class PairNearbyTests: XCTestCase {
    /// The list capture with the test iPhone edited to `pairingState`
    /// "unpaired" over the local network (SOURCE-DERIVED, see
    /// `ApplePhysicalManagementTests.unpairedDevice`).
    private func unpairedListFile() throws -> URL {
        var text = try XCTUnwrap(String(data: try PhysicalFixtures.data("devicectl-list-devices.json"), encoding: .utf8))
        text = text.replacingOccurrences(of: "\"pairingState\" : \"paired\"", with: "\"pairingState\" : \"unpaired\"")
        text = text.replacingOccurrences(of: "\"transportType\" : \"wired\"", with: "\"transportType\" : \"localNetwork\"")
        let url = try makeTemporaryFolder("unpaired").appendingPathComponent("list.json")
        try Data(text.utf8).write(to: url)
        return url
    }

    private func makePairStub(listing: URL) throws -> StubTool {
        try makePhysicalStub(
            extra: """
              *"manage pair"*)
                \(PhysicalFixtures.json("devicectl-simulate-location-clear.json")) ;;
            """,
            listBody: PhysicalFixtures.json(from: listing.path)
        )
    }

    func testAnUnpairedPhoneIsACandidateAndPairingRunsTheOneCommandThenEnablesIt() async throws {
        let stub = try makePairStub(listing: try unpairedListFile())
        let preferences = AppPreferences(defaults: .scratch())
        let inventory = try makePhysicalInventory(stub: stub, preferences: preferences, pollInterval: .seconds(60))
        inventory.setShowing(true)
        let listed = await physicalWait { inventory.pairCandidates.count == 1 }
        XCTAssertTrue(listed)
        let candidate = try XCTUnwrap(inventory.pairCandidates.first)
        XCTAssertFalse(preferences.isPhysicalAppleDeviceEnabled(candidate.udid))
        XCTAssertEqual(stub.deviceCalls, [], "listing is all a candidate gets")

        try await inventory.pairNearby(udid: candidate.udid)

        let paired = stub.deviceCalls
        XCTAssertEqual(paired.count, 1)
        XCTAssertTrue(paired[0].hasPrefix("manage pair --device \(PhysicalFixtures.coreDeviceIdentifier) "), paired[0])
        XCTAssertTrue(preferences.isPhysicalAppleDeviceEnabled(candidate.udid), "a paired phone is enabled")
        XCTAssertEqual(inventory.entry(udid: candidate.udid)?.isEnabled, true)
    }

    func testAnUnpairedPhoneIsNotInThePairedList() async throws {
        let stub = try makePairStub(listing: try unpairedListFile())
        let inventory = try makePhysicalInventory(stub: stub, pollInterval: .seconds(60))
        inventory.setShowing(true)
        let listed = await physicalWait { inventory.pairCandidates.count == 1 }
        XCTAssertTrue(listed)
        XCTAssertEqual(inventory.pairedPhones, [])
    }

    func testAPairedPhoneIsNotACandidateAndCannotBePaired() async throws {
        let stub = try makePhysicalStub()
        let inventory = try makePhysicalInventory(stub: stub, pollInterval: .seconds(60))
        inventory.setShowing(true)
        let listed = await physicalWait { inventory.entries.count == 1 }
        XCTAssertTrue(listed)
        XCTAssertEqual(inventory.pairCandidates, [])

        do {
            try await inventory.pairNearby(udid: PhysicalFixtures.udid)
            XCTFail("a paired phone is never paired again")
        } catch let error as ApplePhysicalInventory.PairNearbyError {
            XCTAssertEqual(error, .unavailable)
        }
        XCTAssertEqual(stub.deviceCalls, [])
    }

    func testWithTheShowPreferenceOffNothingIsListedOrPaired() async throws {
        let stub = try makePairStub(listing: try unpairedListFile())
        let inventory = try makePhysicalInventory(stub: stub, pollInterval: .seconds(60))
        XCTAssertFalse(inventory.isShowing)
        XCTAssertEqual(inventory.pairCandidates, [])
        do {
            try await inventory.pairNearby(udid: PhysicalFixtures.udid)
            XCTFail("nothing is paired while the preference is off")
        } catch is ApplePhysicalInventory.PairNearbyError {
        }
        XCTAssertEqual(stub.calls, [])
    }

    // MARK: - QR flow

    func testTheQRFlowPairsAndConnectsAndRefreshesOnce() async throws {
        let adb = try makeStubAdb(arms: """
          "mdns services")
            printf 'List of discovered mdns services\\nstudio-AbCd123456\\t_adb-tls-pairing._tcp\\t192.168.1.42:41117\\nadb-R58M12345AB-yXk7tu\\t_adb-tls-connect._tcp\\t192.168.1.42:37215\\n' ;;
          "pair 192.168.1.42:41117 Zq9xW2mK7vLp")
            printf 'Successfully paired to 192.168.1.42:41117 [guid=adb-test]\\n' ;;
          "connect 192.168.1.42:37215")
            printf 'connected to 192.168.1.42:37215\\n' ;;
        """)
        let status = StatusCenter()
        var refreshes = 0
        let pairing = WirelessPairingController(adbClient: adb.client, status: status) { refreshes += 1 }

        let result = await pairing.pairWithQR(
            .init(serviceName: "studio-AbCd123456", password: "Zq9xW2mK7vLp"),
            scanTimeout: .seconds(2)
        )

        XCTAssertEqual(result, .attempt(.connected))
        XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(status.statusMessage, "Paired 192.168.1.42:37215")
        XCTAssertFalse(pairing.isWaitingForQR)
    }

    func testAnUnscannedCodeExpiresWithoutPairing() async throws {
        let adb = try makeStubAdb(arms: """
          "mdns services") printf 'List of discovered mdns services\\n' ;;
        """)
        let pairing = WirelessPairingController(adbClient: adb.client, status: StatusCenter())

        let result = await pairing.pairWithQR(.init(serviceName: "studio-x", password: "y"), scanTimeout: .milliseconds(300))

        XCTAssertEqual(result, .notScanned)
        XCTAssertFalse(adb.calls.contains { $0.hasPrefix("pair") })
    }

    func testCancellingTheSheetStopsTheWait() async throws {
        let adb = try makeStubAdb(arms: """
          "mdns services") printf 'List of discovered mdns services\\n' ;;
        """)
        let pairing = WirelessPairingController(adbClient: adb.client, status: StatusCenter())
        let attempt = Task {
            await pairing.pairWithQR(.init(serviceName: "studio-x", password: "y"), scanTimeout: .seconds(30))
        }
        await waitUntil("the wait never started") { pairing.isWaitingForQR }

        attempt.cancel()
        let result = await attempt.value

        XCTAssertEqual(result, .cancelled)
        XCTAssertFalse(pairing.isWaitingForQR)
    }

    // MARK: - QR image

    /// The bitmap decodes back to the exact text (CoreImage's own detector).
    func testTheQRImageDecodesToItsPayload() throws {
        let payload = WirelessPairing.QRCredentials(serviceName: "studio-AbCd123456", password: "Zq9xW2mK7vLp").payload
        let image = try XCTUnwrap(QRCodeImage.cgImage(for: payload))
        XCTAssertEqual(image.width, image.height)
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let features = detector.features(in: CIImage(cgImage: image))
        XCTAssertEqual((features.first as? CIQRCodeFeature)?.messageString, payload)
    }
}

// MARK: - iPhone tab hint and paired list

@MainActor
final class PairNearbyHintTests: XCTestCase {
    func testTheHintWaitsFourSecondsThenShows() async {
        let waited = HintLockedBox<[Duration]>([])
        let shows = await PairNearbyHint.waitForHint { waited.append($0) }
        XCTAssertTrue(shows)
        XCTAssertEqual(waited.value, [.seconds(4)])
    }

    func testACancelledWaitNeverShowsTheHint() async {
        let shows = await PairNearbyHint.waitForHint { _ in throw CancellationError() }
        XCTAssertFalse(shows, "a candidate appearing before the delay cancels the hint")
    }

    func testTheHintText() {
        XCTAssertEqual(PairNearbyHint.text, "Paired iPhones appear in the sidebar. To pair a new iPhone, turn on Developer Mode and connect it with a cable or join the same Wi-Fi.")
    }

    func testPairedPhonesListsOnlyPairedIPhones() async throws {
        let stub = try makePhysicalStub()
        let inventory = try makePhysicalInventory(stub: stub, pollInterval: .seconds(60))
        inventory.setShowing(true)
        let listed = await physicalWait { inventory.entries.count == 1 }
        XCTAssertTrue(listed)
        XCTAssertEqual(inventory.pairedPhones.count, 1)
        XCTAssertTrue(inventory.pairedPhones.allSatisfy { $0.device.isPaired })
        XCTAssertEqual(inventory.pairCandidates, [], "a paired phone is never both")
    }
}

private final class HintLockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T { lock.withLock { stored } }
    func append<E>(_ element: E) where T == [E] { lock.withLock { stored.append(element) } }
}
