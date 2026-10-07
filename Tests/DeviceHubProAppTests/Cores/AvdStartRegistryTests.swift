import XCTest
@testable import DeviceHubProApp

/// Claims, booting panels and user stops of in-app AVD starts.
final class AvdStartRegistryTests: XCTestCase {
    func testASecondClaimOfTheSameAvdIsANoOp() {
        var registry = AvdStartRegistry()
        XCTAssertTrue(registry.claim("Pixel_9"))
        registry.markBooting("Pixel_9")
        let claimed = registry

        XCTAssertFalse(registry.claim("Pixel_9"), "a second Start would shut the booting VM down")
        XCTAssertEqual(registry, claimed, "the refused claim changes nothing")
        XCTAssertTrue(registry.claim("Pixel_8"), "another AVD starts independently")
    }

    func testAClaimAloneShowsNoBootingPanel() {
        // Attaching to a running AVD claims it but never shows its panel.
        var registry = AvdStartRegistry()
        XCTAssertTrue(registry.claim("Pixel_9"))
        XCTAssertTrue(registry.isInFlight("Pixel_9"))
        XCTAssertFalse(registry.isStarting("Pixel_9"))
        XCTAssertTrue(registry.starting.isEmpty)
    }

    func testAStopBeforeTheLaunchWins() {
        // Power On: the Stop lands while the broken VM is being killed,
        // before `bootEmulator` launches anything.
        var registry = AvdStartRegistry()
        XCTAssertTrue(registry.claim("Pixel_9"))
        registry.markBooting("Pixel_9")
        registry.requestStop("Pixel_9")

        XCTAssertTrue(registry.isStoppedByUser("Pixel_9"), "the boot sees the stop and launches nothing")
        registry.finish("Pixel_9")
        XCTAssertEqual(registry, AvdStartRegistry(), "the finished start leaves nothing behind")
    }

    func testAStopAfterTheBootKeepsTheSessionOff() {
        // The boot completed; a Stop lands during the reads before the
        // session would start.
        var registry = AvdStartRegistry()
        XCTAssertTrue(registry.claim("Pixel_9"))
        registry.markBooting("Pixel_9")
        registry.markBooted("Pixel_9")
        XCTAssertFalse(registry.isStarting("Pixel_9"), "the booting panel ends with the boot")
        XCTAssertTrue(registry.isInFlight("Pixel_9"), "the claim holds until the start finishes")

        registry.requestStop("Pixel_9")
        XCTAssertTrue(registry.isStoppedByUser("Pixel_9"), "no session starts on the VM being shut down")
        registry.finish("Pixel_9")
        XCTAssertFalse(registry.isStoppedByUser("Pixel_9"))
        XCTAssertFalse(registry.isInFlight("Pixel_9"))
    }

    func testAStopWithNoStartInFlightMarksNothing() {
        var registry = AvdStartRegistry()
        registry.requestStop("Pixel_9")
        XCTAssertFalse(registry.isStoppedByUser("Pixel_9"))

        XCTAssertTrue(registry.claim("Pixel_8"))
        registry.requestStop("Pixel_9")
        XCTAssertFalse(registry.isStoppedByUser("Pixel_9"), "only the stopped AVD's own start counts")
    }

    func testAFailedStopIsWithdrawn() {
        var registry = AvdStartRegistry()
        XCTAssertTrue(registry.claim("Pixel_9"))
        registry.requestStop("Pixel_9")
        registry.withdrawStop("Pixel_9")
        XCTAssertFalse(registry.isStoppedByUser("Pixel_9"), "the VM lives on, so the boot reports as usual")
        XCTAssertTrue(registry.isInFlight("Pixel_9"))
    }

    func testAnExitDuringStartupConsumesTheStopOnce() {
        var registry = AvdStartRegistry()
        XCTAssertTrue(registry.claim("Pixel_9"))
        XCTAssertFalse(registry.consumeStop("Pixel_9"), "an exit with no stop is a failure to report")

        registry.requestStop("Pixel_9")
        XCTAssertTrue(registry.consumeStop("Pixel_9"), "the user's stop ends the boot silently")
        XCTAssertFalse(registry.consumeStop("Pixel_9"), "consumed")
        XCTAssertFalse(registry.isStoppedByUser("Pixel_9"))
    }

    func testTwoBootsEndIndependently() {
        var registry = AvdStartRegistry()
        XCTAssertTrue(registry.claim("Pixel_9"))
        XCTAssertTrue(registry.claim("Pixel_8"))
        registry.markBooting("Pixel_9")
        registry.markBooting("Pixel_8")
        registry.finish("Pixel_8")
        XCTAssertEqual(registry.starting, ["Pixel_9"], "one finishing must not end the other's panel")
        XCTAssertEqual(registry.inFlight, ["Pixel_9"])
    }
}
