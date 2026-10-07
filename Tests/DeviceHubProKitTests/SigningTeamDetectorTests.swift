import XCTest
@testable import DeviceHubProKit

/// The team detector and the resolution order, against injected fake
/// certificates (the real keychain is never read here).
final class SigningTeamDetectorTests: XCTestCase {
    private struct FakeSource: CodeSigningCertificateSource {
        var result: Result<[CodeSigningCertificate], SigningTeamDetectionError>
        func certificates() throws -> [CodeSigningCertificate] { try result.get() }
    }

    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func cert(
        _ cn: String = "Apple Development: Test User (QQQQQQQQQQ)",
        team: String = "AAAAAAAAAA",
        org: String = "Test Org",
        from: TimeInterval = -1000,
        to: TimeInterval = 1000
    ) -> CodeSigningCertificate {
        CodeSigningCertificate(
            commonName: cn, organizationalUnit: team, organization: org,
            notBefore: now.addingTimeInterval(from), notAfter: now.addingTimeInterval(to)
        )
    }

    private func teams(_ certs: [CodeSigningCertificate]) throws -> [SigningTeam] {
        try SigningTeamDetector.teams(from: FakeSource(result: .success(certs)), now: now)
    }

    func testTheTeamIsTheOrganizationalUnitNotTheIdInTheCommonName() throws {
        let found = try teams([cert()])
        XCTAssertEqual(found, [SigningTeam(id: "AAAAAAAAAA", organization: "Test Org")])
        XCTAssertNotEqual(found.first?.id, "QQQQQQQQQQ")
    }

    func testOnlyDevelopmentCertificatesCount() throws {
        let found = try teams([
            cert("Developer ID Application: Someone (QQQQQQQQQQ)", team: "BBBBBBBBBB"),
            cert("Apple Distribution: Someone (QQQQQQQQQQ)", team: "CCCCCCCCCC"),
            cert("iPhone Developer: Old Name (QQQQQQQQQQ)", team: "DDDDDDDDDD", org: "Old"),
            cert("Apple Development: New Name (QQQQQQQQQQ)", team: "EEEEEEEEEE", org: "New"),
        ])
        XCTAssertEqual(found.map(\.id), ["EEEEEEEEEE", "DDDDDDDDDD"], "New before Old")
    }

    func testExpiredAndNotYetValidCertificatesAreIgnored() throws {
        XCTAssertEqual(try teams([cert(from: -2000, to: -1)]), [])
        XCTAssertEqual(try teams([cert(from: 1, to: 2000)]), [])
    }

    func testTheSameTeamAppearsOnce() throws {
        let found = try teams([cert(), cert("Apple Development: Other (RRRRRRRRRR)"), cert()])
        XCTAssertEqual(found.count, 1)
    }

    func testMalformedTeamIdentifiersAreIgnored() throws {
        XCTAssertEqual(try teams([cert(team: ""), cert(team: "SHORT"), cert(team: "TOOLONG12345"), cert(team: "bad-chars!")]), [])
    }

    func testTeamsAreSortedByOrganization() throws {
        let found = try teams([cert(team: "BBBBBBBBBB", org: "Zeta"), cert(team: "CCCCCCCCCC", org: "Alpha")])
        XCTAssertEqual(found.map(\.organization), ["Alpha", "Zeta"])
    }

    func testAKeychainErrorPropagatesWithoutAStatusOrIdentifier() {
        XCTAssertThrowsError(try SigningTeamDetector.teams(from: FakeSource(result: .failure(.keychainUnavailable)), now: now)) {
            XCTAssertEqual($0 as? SigningTeamDetectionError, .keychainUnavailable)
        }
    }

    func testTheTextualFormsLeaveTheIdentifierOut() {
        let team = SigningTeam(id: "AAAAAAAAAA", organization: "Test Org")
        XCTAssertFalse("\(team)".contains("AAAAAAAAAA"))
        XCTAssertFalse(String(reflecting: team).contains("AAAAAAAAAA"))
    }

    // MARK: Resolution order

    private final class World: @unchecked Sendable {
        private let lock = NSLock()
        var storedValue: String?
        var detected: Result<[SigningTeam], SigningTeamDetectionError> = .success([])
        var choice: SigningTeam?
        var detectCalls = 0
        var pickCalls = 0
        var stores: [String] = []

        func resolver() -> SigningTeamResolver {
            SigningTeamResolver(
                stored: { self.lock.withLock { self.storedValue } },
                store: { team in self.lock.withLock { self.stores.append(team); self.storedValue = team } },
                detect: { try self.lock.withLock { self.detectCalls += 1; return try self.detected.get() } },
                pick: { _ in self.lock.withLock { self.pickCalls += 1; return self.choice } }
            )
        }
    }

    private let alpha = SigningTeam(id: "AAAAAAAAAA", organization: "Alpha")
    private let beta = SigningTeam(id: "BBBBBBBBBB", organization: "Beta")

    func testAStoredTeamWinsAndNothingIsDetected() async throws {
        let world = World()
        world.storedValue = "STORED1234"
        world.detected = .success([alpha])
        let team = try await world.resolver().resolve()
        XCTAssertEqual(team, "STORED1234")
        XCTAssertEqual(world.detectCalls, 0)
        XCTAssertEqual(world.pickCalls, 0)
    }

    func testAnInvalidStoredValueIsIgnored() async throws {
        let world = World()
        world.storedValue = "junk"
        world.detected = .success([alpha])
        let team = try await world.resolver().resolve()
        XCTAssertEqual(team, "AAAAAAAAAA")
    }

    func testOneDetectedTeamIsUsedAndStoredWithoutAsking() async throws {
        let world = World()
        world.detected = .success([alpha])
        let team = try await world.resolver().resolve()
        XCTAssertEqual(team, "AAAAAAAAAA")
        XCTAssertEqual(world.stores, ["AAAAAAAAAA"])
        XCTAssertEqual(world.pickCalls, 0)
        // The second run reads the stored value only.
        _ = try await world.resolver().resolve()
        XCTAssertEqual(world.detectCalls, 1)
    }

    func testSeveralTeamsAskOnceAndTheChoiceIsStored() async throws {
        let world = World()
        world.detected = .success([alpha, beta])
        world.choice = beta
        let team = try await world.resolver().resolve()
        XCTAssertEqual(team, "BBBBBBBBBB")
        XCTAssertEqual(world.pickCalls, 1)
        XCTAssertEqual(world.stores, ["BBBBBBBBBB"])
        _ = try await world.resolver().resolve()
        XCTAssertEqual(world.pickCalls, 1, "asked only once")
    }

    func testDecliningThePickerStoresNothingAndFails() async {
        let world = World()
        world.detected = .success([alpha, beta])
        world.choice = nil
        do {
            _ = try await world.resolver().resolve()
            XCTFail("declined")
        } catch {
            XCTAssertNotEqual(error as? PhysicalControlError, .noTeam)
        }
        XCTAssertTrue(world.stores.isEmpty)
    }

    func testNoTeamOrAKeychainErrorIsTheRunnerUnavailableError() async {
        let world = World()
        for detected: Result<[SigningTeam], SigningTeamDetectionError> in [.success([]), .failure(.keychainUnavailable)] {
            world.detected = detected
            do {
                _ = try await world.resolver().resolve()
                XCTFail("no team")
            } catch {
                XCTAssertEqual(error as? PhysicalControlError, .noTeam)
            }
        }
        XCTAssertEqual(world.pickCalls, 0)
        XCTAssertTrue(world.stores.isEmpty)
        XCTAssertTrue(PhysicalControlError.noTeam.description.contains("Xcode ▸ Settings ▸ Accounts"))
        XCTAssertFalse(PhysicalControlError.noTeam.description.contains("Team ID"))
    }
}
