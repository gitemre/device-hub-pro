import XCTest
@testable import DeviceHubProKit

final class PlainFailureTests: XCTestCase {
    private let fallback = "Couldn\u{2019}t load the list."

    func testAnOfflineListingBecomesAConnectionSentenceWithTheRawTextKept() {
        let raw = "sdkmanager --list failed with exit code 1.\nFetched Android repositories failed: java.net.UnknownHostException: dl.google.com"
        let failure = PlainFailure.make(raw, fallback: fallback)
        XCTAssertEqual(failure.summary, PlainFailure.offlineSummary)
        XCTAssertEqual(failure.details, raw)
    }

    func testACertificateFailureIsAProxyProblemNotAnOfflineOne() {
        let raw = "javax.net.ssl.SSLHandshakeException: PKIX path building failed: unable to find valid certification path"
        XCTAssertEqual(PlainFailure.make(raw, fallback: fallback).summary, PlainFailure.proxySummary)
    }

    func testAListTimeoutReadsAsOffline() {
        let raw = "sdkmanager --list could not finish: timed out after 180 s"
        XCTAssertEqual(PlainFailure.make(raw, fallback: fallback).summary, PlainFailure.offlineSummary)
    }

    func testAFullDiskIsNamed() {
        XCTAssertEqual(
            PlainFailure.make("java.io.IOException: No space left on device", fallback: fallback).summary,
            PlainFailure.diskFullSummary
        )
    }

    func testTheWatchdogMessageIsAlreadyPlain() {
        let failure = PlainFailure.make(SdkmanagerClient.stalledMessage, fallback: fallback)
        XCTAssertEqual(failure.summary, SdkmanagerClient.stalledMessage)
        XCTAssertNil(failure.details)
    }

    func testAnUnknownMultiLineFailureUsesTheFallbackAndKeepsTheText() {
        let raw = "sdkmanager failed with exit code 3.\nsomething odd"
        let failure = PlainFailure.make(raw, fallback: fallback)
        XCTAssertEqual(failure.summary, fallback)
        XCTAssertEqual(failure.details, raw)
    }

    func testAShortPlainSentenceIsKeptAsIs() {
        let failure = PlainFailure.make("The license was declined.", fallback: fallback)
        XCTAssertEqual(failure.summary, "The license was declined.")
        XCTAssertNil(failure.details)
    }

    // MARK: - Disk space

    func testNoWarningWhenTheImageAndTheHeadroomFit() {
        XCTAssertNil(DiskSpaceCheck.warning(freeBytes: 3_500_000_000))
        XCTAssertNil(DiskSpaceCheck.warning(freeBytes: nil))
    }

    func testAWarningWhenLessThanTheImagePlusTwoGigabytesIsFree() throws {
        let text = try XCTUnwrap(DiskSpaceCheck.warning(freeBytes: 3_000_000_000))
        XCTAssertTrue(text.contains("Only"), text)
        XCTAssertTrue(text.contains(DiskSpaceCheck.sizeText(3_500_000_000)), text)
    }

    func testAnExplicitImageSizeMovesTheThreshold() {
        XCTAssertNil(DiskSpaceCheck.warning(freeBytes: 5_000_000_000, imageBytes: 3_000_000_000))
        XCTAssertNotNil(DiskSpaceCheck.warning(freeBytes: 4_900_000_000, imageBytes: 3_000_000_000))
    }

    func testCannotFitOnlyWhenLessThanTheImageItselfIsFree() {
        XCTAssertTrue(DiskSpaceCheck.cannotFit(freeBytes: 1_000_000_000))
        XCTAssertFalse(DiskSpaceCheck.cannotFit(freeBytes: 2_000_000_000))
        XCTAssertFalse(DiskSpaceCheck.cannotFit(freeBytes: nil))
    }

    func testFreeBytesOfAMissingFolderFallsBackToItsParent() {
        XCTAssertNotNil(
            DiskSpaceCheck.freeBytes(at: FileManager.default.temporaryDirectory.appendingPathComponent("missing/deeper"))
        )
    }
}
