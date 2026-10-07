import XCTest
@testable import DeviceHubProKit

final class SdkmanagerParsingTests: XCTestCase {
    // MARK: - availableImages

    /// Trimmed from a real `sdkmanager --list` capture (cmdline-tools 22.0,
    /// macOS): the installed section, the head of the available table, and the
    /// updates section. Column padding is trimmed.
    private let listOutput = """
    Loading package information...
    [=========                              ] 25% Loading local repository...
    Installed packages:
      Path                                                             | Version           | Description                                         | Location
      -------                                                          | -------           | -------                                             | -------
      build-tools;35.0.0                                               | 35.0.0            | Android SDK Build-Tools 35                          | build-tools/35.0.0
      cmdline-tools;latest                                             | 22.0              | Android SDK Command-line Tools (latest)             | cmdline-tools/latest
      system-images;android-35;google_apis;arm64-v8a                   | 9                 | Google APIs ARM 64 v8a System Image                 | system-images/android-35/google_apis/arm64-v8a

    Available Packages:
      Path                                                                            | Version           | Description
      -------                                                                         | -------           | -------
      add-ons;addon-google_apis-google-15                                             | 3                 | Google APIs
      build-tools;19.1.0                                                              | 19.1.0            | Android SDK Build-Tools 19.1
      platforms;android-35                                                            | 2                 | Android SDK Platform 35
      system-images;android-10;default;x86                                            | 5                 | Intel x86 Atom System Image
      system-images;android-10;google_apis;armeabi-v7a                                | 6                 | Google APIs ARM EABI v7a System Image
      system-images;android-19;google_apis;x86                                        | 40                | Google APIs Intel x86 Atom System Image
      system-images;android-35;google_apis;arm64-v8a                                  | 9                 | Google APIs ARM 64 v8a System Image
      system-images;android-35;google_apis;x86_64                                     | 9                 | Google APIs Intel x86_64 Atom System Image
      system-images;android-36;google_apis_playstore;arm64-v8a                        | 7                 | Google Play ARM 64 v8a System Image
      system-images;android-36;google_atd;arm64-v8a                                   | 1                 | Google APIs ATD ARM 64 System Image
      system-images;android-37.1;google_apis_playstore_ps16k;arm64-v8a                | 9                 | 16 KB Page Size Google Play ARM 64 v8a System Image
      system-images;android-CANARY;google_apis_ps16k;arm64-v8a                        | 15                | 16 KB Page Size Google APIs ARM 64 v8a System Image

    Available Updates:
      ID                   | Installed | Available
      -------              | -------   | -------
      cmdline-tools;latest | 22.0      | 23.0
      emulator             | 36.6.11   | 37.1.11
      platform-tools       | 37.0.0    | 37.0.1
    """

    func testAvailableImagesParsesOnlyTheAvailableSystemImages() {
        let images = SdkmanagerParsing.availableImages(fromListOutput: listOutput)

        XCTAssertEqual(images.map(\.package), [
            "system-images;android-10;default;x86",
            "system-images;android-10;google_apis;armeabi-v7a",
            "system-images;android-19;google_apis;x86",
            "system-images;android-35;google_apis;arm64-v8a",
            "system-images;android-35;google_apis;x86_64",
            "system-images;android-36;google_apis_playstore;arm64-v8a",
            "system-images;android-36;google_atd;arm64-v8a",
            "system-images;android-37.1;google_apis_playstore_ps16k;arm64-v8a",
            "system-images;android-CANARY;google_apis_ps16k;arm64-v8a",
        ])
        XCTAssertEqual(
            images.first,
            SystemImage(
                package: "system-images;android-10;default;x86",
                api: "android-10",
                tag: "default",
                abi: "x86"
            )
        )
        guard images.count == 9 else { return }
        XCTAssertEqual(images[7].api, "android-37.1")
        XCTAssertEqual(images[8].api, "android-CANARY")
    }

    func testAvailableImagesIgnoresTheCrProgressPreamble() {
        let output = "Loading package information...\r[==] 25% Fetch"
            + "\nInstalled packages:\n  system-images;android-1;default;x86 | 5\n"
            + "\nAvailable Packages:\n"
            + "  system-images;android-35;google_apis;arm64-v8a | 9\n"

        XCTAssertEqual(
            SdkmanagerParsing.availableImages(fromListOutput: output).map(\.package),
            ["system-images;android-35;google_apis;arm64-v8a"]
        )
    }

    func testAvailableImagesHandlesTheCarriageReturnLineFeedAfterProgress() {
        // The real tool ends a progress bar with `\r\n`, which Swift's
        // `split(separator: "\n")` treats as a single character and would
        // never split on: the section header stays glued to the progress bar.
        let output = "Loading package information...\n"
            + "[=========                              ] 25% Loading local repository...\r\n"
            + "Available Packages:\n"
            + "  system-images;android-35;google_apis;arm64-v8a | 9\n"

        XCTAssertEqual(
            SdkmanagerParsing.availableImages(fromListOutput: output).map(\.package),
            ["system-images;android-35;google_apis;arm64-v8a"]
        )
    }

    func testAvailableImagesHandlesCarriageReturnJoinedLines() {
        let output = "Loading...\r[==] 25% Fetch...\rAvailable Packages:\n"
            + "  system-images;android-36;google_atd;arm64-v8a | 1\n"

        XCTAssertEqual(
            SdkmanagerParsing.availableImages(fromListOutput: output).map(\.package),
            ["system-images;android-36;google_atd;arm64-v8a"]
        )
    }

    func testAvailableImagesSkipsRowsThatAreNotCompleteSystemImages() {
        let output = """
        Available Packages:
          Path | Version | Description
          ------- | ------- | -------
          system-images;android-35;google_apis | 1 | Missing ABI
          system-images;android-35;;arm64-v8a | 1 | Missing tag
          add-ons;addon-google_apis-google-15 | 3 | Google APIs
        """

        XCTAssertTrue(SdkmanagerParsing.availableImages(fromListOutput: output).isEmpty)
    }

    func testAvailableImagesStopsAtTheNextSection() {
        let output = """
        Available Packages:
          system-images;android-35;google_apis;arm64-v8a | 9
        Available Updates:
          system-images;android-36;google_apis;arm64-v8a | 10
        """

        XCTAssertEqual(
            SdkmanagerParsing.availableImages(fromListOutput: output).map(\.package),
            ["system-images;android-35;google_apis;arm64-v8a"]
        )
    }

    func testAvailableImagesOfEmptyOrGarbageOutput() {
        XCTAssertTrue(SdkmanagerParsing.availableImages(fromListOutput: "").isEmpty)
        XCTAssertTrue(
            SdkmanagerParsing.availableImages(fromListOutput: "Loading...\n\n").isEmpty
        )
        XCTAssertTrue(
            SdkmanagerParsing.availableImages(fromListOutput: "Available Packages:\n").isEmpty
        )
    }

    /// Real `sdkmanager --list` stdout of cmdline-tools 23.0.0 (the Android CLI
    /// shim, macOS arm64 VM, 2026-10-02): no table, `/` package paths.
    func testAvailableImagesParsesCmdlineTools23Listing() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/cmdline-tools-23/sdkmanager-list.stdout")
        let output = try String(contentsOf: url, encoding: .utf8)
        let images = SdkmanagerParsing.availableImages(fromListOutput: output)

        XCTAssertEqual(images.count, 329)
        XCTAssertTrue(images.allSatisfy { $0.package.hasPrefix("system-images;") && !$0.package.contains("/") })
        XCTAssertEqual(images.first?.package, "system-images;android-10;default;armeabi-v7a")
        XCTAssertEqual(images.first?.api, "android-10")
        XCTAssertEqual(images.first?.abi, "armeabi-v7a")
        XCTAssertTrue(images.contains { $0.abi == "arm64-v8a" && $0.tag == "android-tv" && $0.api == "android-34" })
    }

    func testSlashFormAndUnknownPackageDetection() {
        XCTAssertEqual(
            SdkmanagerClient.slashForm(of: "system-images;android-36;google_apis;arm64-v8a"),
            "system-images/android-36/google_apis/arm64-v8a"
        )
        XCTAssertTrue(SdkmanagerClient.isUnknownPackage("Warning: Unable to find package x"))
        XCTAssertFalse(SdkmanagerClient.isUnknownPackage("License not accepted"))
    }

    // MARK: - progress

    func testProgressParsesPercentageForms() {
        XCTAssertEqual(
            SdkmanagerParsing.progress(
                from: "[=========                              ] 25% Fetch remote repository..."
            ),
            0.25
        )
        XCTAssertEqual(SdkmanagerParsing.progress(from: "[====>   ] 45% Downloading…"), 0.45)
        XCTAssertEqual(SdkmanagerParsing.progress(from: "45%"), 0.45)
        XCTAssertEqual(SdkmanagerParsing.progress(from: "0%"), 0.0)
        XCTAssertEqual(SdkmanagerParsing.progress(from: "100%"), 1.0)
    }

    func testProgressHandlesCarriageReturnJoinedLines() {
        XCTAssertEqual(
            SdkmanagerParsing.progress(from: "[==  ] 25% Loading\r[=== ] 50% Fetching"),
            0.5
        )
        XCTAssertEqual(SdkmanagerParsing.progress(from: "45%\r"), 0.45)
        XCTAssertEqual(SdkmanagerParsing.progress(from: "\r100% Computing updates..."), 1.0)
    }

    func testProgressRejectsNonProgressLines() {
        XCTAssertNil(SdkmanagerParsing.progress(from: "Installed packages:"))
        XCTAssertNil(SdkmanagerParsing.progress(from: "Accept? (y/N): "))
        XCTAssertNil(SdkmanagerParsing.progress(from: "[====] 250%"))
        XCTAssertNil(
            SdkmanagerParsing.progress(from: "system-images;android-35;google_apis;arm64-v8a")
        )
        XCTAssertNil(SdkmanagerParsing.progress(from: ""))
    }

    // MARK: - licensePromptLines

    /// The real install-time license prompt (cmdline-tools 22.0): progress
    /// lines, the `License <id>:` header, an excerpt of the agreement, and the
    /// prompt merged into the rejection line that follows it on the same
    /// physical line (sdkmanager writes the prompt without a newline).
    private let installLicenseOutput = """
    [==                                     ] 7% Fetch remote repository...
    [===                                    ] 10% Computing updates...
    License android-sdk-license:
    ---------------------------------------
    Terms and Conditions

    This is the Android Software Development Kit License Agreement

    1. Introduction

    1.1 The Android Software Development Kit (referred to in the License Agreement as the "SDK" and specifically including the Android system files, packaged APIs, and Google APIs add-ons) is licensed to you subject to the terms of the License Agreement. The License Agreement forms a legally binding contract between you and Google in relation to your use of the SDK.

    Accept? (y/N): Skipping following packages as the license is not accepted:
    Intel x86 Atom System Image
    The following packages can not be installed since their licenses or those of the packages they depend on were not accepted:
      system-images;android-10;default;x86
    [=======================================] 100% Computing updates...
    """

    func testLicensePromptLinesKeepsTheBlockAndStripsThePrompt() {
        XCTAssertEqual(SdkmanagerParsing.licensePromptLines(from: installLicenseOutput), [
            "License android-sdk-license:",
            "---------------------------------------",
            "Terms and Conditions",
            "This is the Android Software Development Kit License Agreement",
            "1. Introduction",
            "1.1 The Android Software Development Kit (referred to in the License Agreement as the \"SDK\" and specifically including the Android system files, packaged APIs, and Google APIs add-ons) is licensed to you subject to the terms of the License Agreement. The License Agreement forms a legally binding contract between you and Google in relation to your use of the SDK.",
            "Skipping following packages as the license is not accepted:",
            "Intel x86 Atom System Image",
            "The following packages can not be installed since their licenses or those of the packages they depend on were not accepted:",
            "system-images;android-10;default;x86",
        ])
    }

    func testLicensePromptLinesHandlesSeveralLicensesAndBothHeaderForms() {
        let output = """
        7 of 7 SDK package licenses not accepted.
        Review licenses that have not been accepted (y/N)? 
        1/7: License android-googletv-license:
        ---------------------------------------
        Terms and Conditions
        Accept? (y/N): 
        2/7: License android-sdk-license:
        ---------------------------------------
        3. Android SDK License
        Accept? (y/N): 
        """

        XCTAssertEqual(SdkmanagerParsing.licensePromptLines(from: output), [
            "1/7: License android-googletv-license:",
            "---------------------------------------",
            "Terms and Conditions",
            "2/7: License android-sdk-license:",
            "---------------------------------------",
            "3. Android SDK License",
        ])
    }

    func testLicensePromptLinesNormalizesCrProgressAndSkipsTheToolWarning() {
        let output = """
        WARNING: The SDK Manager CLI tool (sdkmanager) is deprecated. Use Android CLI instead.
        The 'android' binary can also be found in the cmdline-tools directory, and 'android sdk' is the replacement for 'sdkmanager'.
        To learn more about the Android CLI and how to use it, see the documentation (https://d.android.com/tools/agents/android-cli)

        Loading local repository...\r[==] 25% Fetch remote repository...\rLicense android-sdk-license:
        ---------------------------------------
        Accept? (y/N): 
        """

        XCTAssertEqual(SdkmanagerParsing.licensePromptLines(from: output), [
            "License android-sdk-license:",
            "---------------------------------------",
        ])
    }

    func testLicensePromptLinesKeepsAHeaderWithoutAgreementText() {
        let output = """
        3. Android SDK License
        Accept? (y/N): 
        """

        XCTAssertEqual(
            SdkmanagerParsing.licensePromptLines(from: output),
            ["3. Android SDK License"]
        )
    }

    func testLicensePromptLinesKeepsTheWarningBeforeTheBlock() {
        let output = """
        Warning: Package 'system-images;android-10;default;x86' requires the 'android-sdk-license' license, which has not been accepted.
        License android-sdk-license:
        ---------------------------------------
        Accept? (y/N): 
        """

        XCTAssertEqual(SdkmanagerParsing.licensePromptLines(from: output), [
            "Warning: Package 'system-images;android-10;default;x86' requires the 'android-sdk-license' license, which has not been accepted.",
            "License android-sdk-license:",
            "---------------------------------------",
        ])
    }

    func testLicensePromptLinesOfEmptyOrPromptOnlyOutput() {
        XCTAssertTrue(SdkmanagerParsing.licensePromptLines(from: "").isEmpty)
        XCTAssertTrue(SdkmanagerParsing.licensePromptLines(from: "Accept? (y/N): ").isEmpty)
        XCTAssertTrue(
            SdkmanagerParsing.licensePromptLines(
                from: "Review licenses that have not been accepted (y/N)? "
            ).isEmpty
        )
    }

    func testAvailableEmulatorVersionComesFromTheAvailableSectionOfARealListing() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/cmdline-tools-23/sdkmanager-list.stdout")
        let output = try String(contentsOf: url, encoding: .utf8)

        XCTAssertEqual(SdkmanagerParsing.availableVersion(of: "emulator", fromListOutput: output), "37.2.12")
        XCTAssertNil(SdkmanagerParsing.availableVersion(of: "no-such-package", fromListOutput: output))
    }

    func testAvailableVersionReadsTheTableOfOlderTools() {
        let output = """
        Installed packages:
          emulator | 36.6.11 | Android Emulator

        Available Packages:
          Path     | Version | Description
          emulator | 37.2.12 | Android Emulator
        """
        XCTAssertEqual(SdkmanagerParsing.availableVersion(of: "emulator", fromListOutput: output), "37.2.12")
    }
}
