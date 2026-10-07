import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// The first-run audit's plain-language and discoverability fixes: what the
/// sidebar offers for iPhones, the plain failure texts, the Android phone
/// guidance, the quit confirmation and the small pure rules behind them.
@MainActor
final class FirstRunGuidanceTests: XCTestCase {
    private func tooling(
        probed: Bool = true,
        tier: AppleToolchain.Tier = .t1,
        guidance: AppleToolchain.XcodeGuidance? = nil
    ) -> AppleToolingStatus {
        AppleToolingStatus(
            isProbed: probed, tier: tier, setupAdvice: guidance?.message, guidance: guidance,
            xcodeVersion: nil, xcodeBuild: nil
        )
    }

    // MARK: - iPhone card

    func testTheIPhoneCardOffersToShowIPhonesOnlyWhenXcodeWorksAndThePreferenceIsOff() {
        XCTAssertTrue(DeviceSidebarView.iphoneCardShows(
            tooling: tooling(), showsPhysicalDevices: false, dismissed: false, hasQuery: false))
        XCTAssertFalse(DeviceSidebarView.iphoneCardShows(
            tooling: tooling(), showsPhysicalDevices: true, dismissed: false, hasQuery: false), "already on")
        XCTAssertFalse(DeviceSidebarView.iphoneCardShows(
            tooling: tooling(), showsPhysicalDevices: false, dismissed: true, hasQuery: false), "closed")
        XCTAssertFalse(DeviceSidebarView.iphoneCardShows(
            tooling: tooling(), showsPhysicalDevices: false, dismissed: false, hasQuery: true), "searching")
        XCTAssertFalse(DeviceSidebarView.iphoneCardShows(
            tooling: tooling(probed: false), showsPhysicalDevices: false, dismissed: false, hasQuery: false))
        XCTAssertFalse(DeviceSidebarView.iphoneCardShows(
            tooling: tooling(tier: .t0, guidance: .notInstalled),
            showsPhysicalDevices: false, dismissed: false, hasQuery: false), "the Xcode card speaks instead")
    }

    func testShowingIPhonesFromTheCardSetsThePreferenceAndTheCardGoesAway() {
        let model = AppModel.testing(defaults: .scratch())
        XCTAssertFalse(model.preferences.showPhysicalAppleDevices)
        model.physicalInventory.setShowing(true)
        XCTAssertTrue(model.preferences.showPhysicalAppleDevices)
        XCTAssertFalse(DeviceSidebarView.iphoneCardShows(
            tooling: tooling(), showsPhysicalDevices: model.preferences.showPhysicalAppleDevices,
            dismissed: false, hasQuery: false))
        model.physicalInventory.setShowing(false)
    }

    func testTheCardsHaveTheirOwnDismissFlags() {
        let defaults = UserDefaults.scratch()
        let preferences = AppPreferences(defaults: defaults)
        preferences.setIOSPlatformCardDismissed(true)
        XCTAssertFalse(preferences.xcodeHintDismissed, "closing the platform card keeps the Xcode card")
        XCTAssertFalse(preferences.iphoneCardDismissed)
        preferences.setIPhoneCardDismissed(true)
        let reloaded = AppPreferences(defaults: defaults)
        XCTAssertTrue(reloaded.iosPlatformCardDismissed)
        XCTAssertTrue(reloaded.iphoneCardDismissed)
        XCTAssertFalse(reloaded.xcodeHintDismissed)
    }

    // MARK: - Listing failure

    func testAFailedIPhoneListingIsAPlainSentenceWithTheRawTextBehindDetails() {
        let raw = "devicectl list devices failed (1): ERROR: The operation couldn\u{2019}t be completed. (CoreDeviceError error 2.)"
        let failure = ApplePhysicalInventory.listFailure(raw)
        XCTAssertEqual(failure.summary, "Couldn\u{2019}t look for iPhones connected to this Mac.")
        XCTAssertEqual(failure.details, raw)
    }

    // MARK: - Android phone guidance (items 3, 15)

    func testTheUnauthorizedPanelTellsHowToGetThePromptBack() {
        let text = DeviceStagePanelText.unauthorized(name: "Pixel 8")
        XCTAssertTrue(text.contains("Always allow from this computer"))
        XCTAssertTrue(text.contains("unplug and replug"))
        XCTAssertTrue(text.contains("Revoke USB debugging authorizations"))
    }

    func testTheUnreachablePanelGivesAConcreteNextStep() {
        let text = DeviceStagePanelText.unreachable(name: "Pixel 8")
        XCTAssertTrue(text.contains("replug"))
        XCTAssertTrue(text.contains("Rescan"))
    }

    func testTheConnectSheetCoversDeveloperOptionsUsbDebuggingAndAllow() {
        let steps = ConnectAndroidPhoneSheet.usbSteps.joined(separator: " ")
        XCTAssertTrue(steps.contains("Build number 7 times"))
        XCTAssertTrue(steps.contains("USB debugging"))
        XCTAssertTrue(steps.contains("Always allow"))
        XCTAssertTrue(ConnectAndroidPhoneSheet.wirelessNote.contains("Pair Nearby Device"))
        // MIUI / HyperOS: the second switch that lets taps and keys through.
        XCTAssertTrue(ConnectAndroidPhoneSheet.xiaomiNote.contains("USB debugging (Security settings)"))
    }

    func testSetUpAndroidToolsStaysInThePlusMenuUntilTheToolsExist() {
        XCTAssertTrue(LeadingToolbarCluster.offersAndroidSetup(adbAvailable: false))
        XCTAssertFalse(LeadingToolbarCluster.offersAndroidSetup(adbAvailable: true))
    }

    // MARK: - Missing tools alert

    func testTheMissingEmulatorSentenceIsPlainAndOffersSetup() {
        XCTAssertEqual(EmulatorError.emulatorNotFound.description, "The Android Emulator isn\u{2019}t installed.")
        XCTAssertFalse(EmulatorError.emulatorNotFound.description.contains("ANDROID_HOME"))
        XCTAssertTrue(UserFacingText.offersAndroidSetup(EmulatorError.emulatorNotFound.description))
        XCTAssertTrue(UserFacingText.offersAndroidSetup(UserFacingText.androidToolsMissing))
        XCTAssertFalse(UserFacingText.offersAndroidSetup("Something else failed."))
        XCTAssertFalse(UserFacingText.offersAndroidSetup(nil))
    }

    // MARK: - Setup card (items 7, 10, 17)

    func testTheCardCopyDoesNotPromiseNothingIsDownloadedAndNamesTheSizes() {
        XCTAssertFalse(AndroidSetupView.licenseNote.contains("Nothing is downloaded"))
        XCTAssertTrue(AndroidSetupView.licenseNote.contains("Android packages"))
        let size = AndroidSetupView.sizeNote(installRoot: "~/Library/Android/sdk")
        XCTAssertTrue(size.contains("about 600 MB"))
        XCTAssertTrue(size.contains("about 1.5 GB"))
        for text in [AndroidSetupView.javaNote, AndroidSetupView.licenseNote, size] {
            XCTAssertFalse(text.contains("Temurin"))
            XCTAssertFalse(text.contains("sdkmanager"))
        }
    }

    func testAFailedSetupIsAPlainSentenceWithDetails() {
        let failure = PlainFailure.make(
            "The download failed: The Internet connection appears to be offline.",
            fallback: "Android setup couldn\u{2019}t finish.")
        XCTAssertEqual(failure.summary, PlainFailure.offlineSummary)
        XCTAssertNotNil(failure.details)
    }

    // MARK: - Create sheet (items 4, 5, 6, 18)

    func testTheStillWorkingHintAppearsAfterTwentySeconds() {
        XCTAssertNil(AvdCreateSheet.loadingHint(elapsed: 19.9))
        let hint = AvdCreateSheet.loadingHint(elapsed: 21)
        XCTAssertNotNil(hint)
        XCTAssertTrue(hint?.hasPrefix("Still working") == true)
    }

    func testAFailedImageListingIsPlainWithDetails() {
        let raw = "sdkmanager --list failed with exit code 1.\njava.net.UnknownHostException: dl.google.com"
        let failure = AvdCreateSheet.listFailure(raw)
        XCTAssertEqual(failure.summary, PlainFailure.offlineSummary)
        XCTAssertEqual(failure.details, raw)
        let proxy = AvdCreateSheet.listFailure("javax.net.ssl.SSLHandshakeException: PKIX path building failed")
        XCTAssertEqual(proxy.summary, PlainFailure.proxySummary)
    }

    func testTheDownloadNoteSaysCancelDiscardsAndWarnsOnLowDiskSpace() {
        let roomy = AvdCreateSheet.downloadNote(freeBytes: 50_000_000_000)
        XCTAssertEqual(roomy.count, 1)
        XCTAssertTrue(roomy[0].contains("Cancelling a download discards"))
        let tight = AvdCreateSheet.downloadNote(freeBytes: 2_500_000_000)
        XCTAssertEqual(tight.count, 2)
        XCTAssertTrue(tight[1].contains("Only"))
        XCTAssertEqual(AvdCreateSheet.downloadNote(freeBytes: nil).count, 1)
    }

    func testADownloadThatCannotFitFailsInWordsBeforeStarting() async {
        let slot = SDKInstallSlot()
        let sdk = SDKComponentModel(
            locateClient: { SdkmanagerClient(sdkmanagerURL: URL(fileURLWithPath: "/nonexistent/sdkmanager")) },
            locateSdkRoot: { nil },
            installSlot: slot,
            freeSpace: { _ in 500_000_000 }
        )
        let outcome = await sdk.startDownload(package: "system-images;android-35;google_apis;arm64-v8a")
        guard case .failed(let message) = outcome else { return XCTFail("expected a refusal, got \(outcome)") }
        XCTAssertTrue(message.contains("Only"), message)
        XCTAssertNil(slot.package, "the install slot was never taken")
    }

    // MARK: - Downloads popover

    func testAFailedJobIsOneSentenceWithDetailsBehind() {
        let job = AvdCreationJob(
            id: UUID(),
            request: AvdCreationRequest(
                name: "Pixel", displayName: nil, deviceID: "pixel", deviceName: "Pixel",
                image: SystemImage(package: "system-images;android-35;google_apis;arm64-v8a", api: "android-35", tag: "google_apis", abi: "arm64-v8a")
            ),
            phase: .failed("sdkmanager system-images failed with exit code 1.\nFetched failed: UnknownHostException")
        )
        XCTAssertEqual(job.plainFailure?.summary, PlainFailure.offlineSummary)
        XCTAssertNotNil(job.plainFailure?.details)
        var working = job
        working.phase = .downloading
        XCTAssertNil(working.plainFailure)
    }

    // MARK: - Quit

    func testQuitIsOnlyQuestionedWhileSomethingLongRunningIsUnderWay() {
        XCTAssertNil(AppModel.quitInterruptionNotice(jobPhases: [], directDownload: false, setupRunning: false))
        XCTAssertNil(AppModel.quitInterruptionNotice(jobPhases: [.failed("x")], directDownload: false, setupRunning: false))
        XCTAssertTrue(AppModel.quitInterruptionNotice(jobPhases: [.downloading], directDownload: false, setupRunning: false)?
            .contains("download") == true)
        XCTAssertTrue(AppModel.quitInterruptionNotice(jobPhases: [], directDownload: true, setupRunning: false)?
            .contains("discarded") == true)
        XCTAssertTrue(AppModel.quitInterruptionNotice(jobPhases: [.creating], directDownload: false, setupRunning: false)?
            .contains("emulator") == true)
        XCTAssertTrue(AppModel.quitInterruptionNotice(jobPhases: [], directDownload: false, setupRunning: true)?
            .contains("Android tools") == true)
    }

    // MARK: - Xcode (items 11, 13)

    func testTheXcodePollEndsWhenItsTaskIsCancelled() async {
        let model = AppModel.testing(defaults: .scratch())
        XCTAssertNotNil(model.simulators.tooling.guidance, "a model without Apple tooling shows the Xcode hint")
        let poll = Task { await model.pollXcodeSetup(every: .milliseconds(10)) }
        try? await Task.sleep(for: .milliseconds(80))
        poll.cancel()
        await poll.value
    }

    func testAMissingXcodeLinkHandlerOpensXcodeInstead() {
        var opened = 0
        SimulatorCreateSheet.openAddPlatforms(open: { _ in false }, openXcode: { opened += 1 })
        XCTAssertEqual(opened, 1)
        SimulatorCreateSheet.openAddPlatforms(open: { _ in true }, openXcode: { opened += 1 })
        XCTAssertEqual(opened, 1, "a link that opened needs no fallback")
    }

    func testTheFirstLaunchHintTellsWhatToDo() {
        XCTAssertEqual(
            AppleToolchain.XcodeGuidance.finishInstalling(app: nil).message,
            "Open Xcode, accept the license and let it install its components (a few minutes), then come back."
        )
    }
}
