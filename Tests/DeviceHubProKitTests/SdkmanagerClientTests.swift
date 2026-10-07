import XCTest
@testable import DeviceHubProKit

final class SdkmanagerClientTests: XCTestCase {
    // MARK: - Tests

    func testListAvailableImagesRunsListAndParsesTheListing() async throws {
        let toolbox = try FakeToolbox.make()
        let client = toolbox.client()

        let images = try await client.listAvailableImages()

        XCTAssertEqual(images.map(\.package), [
            "system-images;android-35;google_apis;arm64-v8a",
            "system-images;android-36;google_atd;arm64-v8a",
        ])
        XCTAssertEqual(toolbox.recordedArgs(), ["--list"])
    }

    func testListAvailableAlsoReportsTheEmulatorPackageVersion() async throws {
        let toolbox = try FakeToolbox.make()

        let listing = try await toolbox.client().listAvailable()

        XCTAssertEqual(listing.emulatorVersion, "37.2.12")
        XCTAssertEqual(listing.images.count, 2)
        XCTAssertEqual(toolbox.recordedArgs(), ["--list"])
    }

    func testInstallingTheEmulatorPackageRunsSdkmanagerWithEmulator() async throws {
        let toolbox = try FakeToolbox.make()

        try await toolbox.client().install(
            package: "emulator",
            onProgress: { _ in },
            onLicense: { _ in true }
        )

        XCTAssertEqual(toolbox.recordedArgs(), ["emulator"])
    }

    func testListAvailableImagesSurfacesANonZeroExit() async throws {
        let toolbox = try FakeToolbox.make(listExit: 3)
        let client = toolbox.client()

        do {
            _ = try await client.listAvailableImages()
            XCTFail("expected commandFailed")
        } catch let error as SdkmanagerError {
            guard case .commandFailed(let message) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("fatal: repository unavailable"), message)
            XCTAssertTrue(message.contains("3"), message)
        }
    }

    func testTheToolRunsWithAJavaHomeResolvedFromTheInjectedRuntime() async throws {
        let toolbox = try FakeToolbox.make()
        let client = toolbox.client()

        _ = try await client.listAvailableImages()

        // The injected fake runtime lives in a `<home>/bin/java` layout.
        XCTAssertEqual(toolbox.recordedInfo(), ["JAVA_HOME=\(toolbox.javaHome.path)"])
    }

    func testAnExistingJavaHomeIsUsedWithoutProbingTheInjectedRuntime() async throws {
        let toolbox = try FakeToolbox.make()

        let resolved = await AvdmanagerLocator.javaHomeEnvironment(
            environment: ["JAVA_HOME": "/custom/jdk"],
            preferred: toolbox.java
        )

        // `[:]` means "inherit the environment unchanged": the existing
        // JAVA_HOME wins without probing the injected runtime.
        XCTAssertEqual(resolved, [:])
    }

    func testInstallStreamsProgressAndAnswersTheLicensePrompt() async throws {
        let toolbox = try FakeToolbox.make()
        let client = toolbox.client()
        let progress = ProgressRecorder()
        let licenses = LicenseRecorder(answer: true)

        try await client.install(
            package: "system-images;android-35;google_apis;arm64-v8a",
            onProgress: { progress.append($0) },
            onLicense: { licenses.record($0) }
        )

        XCTAssertEqual(progress.recorded, [nil, 0.25, 0.5, 1.0])
        XCTAssertEqual(toolbox.recordedArgs(), ["system-images;android-35;google_apis;arm64-v8a"])
        XCTAssertEqual(toolbox.recordedAnswers(), ["y"])
        let text = try XCTUnwrap(licenses.recorded.first)
        XCTAssertTrue(text.contains("License android-sdk-license:"), text)
        XCTAssertTrue(text.contains("Terms and Conditions"), text)
        XCTAssertFalse(text.contains("(y/N)"), text)
    }

    func testDecliningTheLicenseWritesNAndThrowsLicenseDeclined() async throws {
        let toolbox = try FakeToolbox.make()
        let client = toolbox.client()
        let licenses = LicenseRecorder(answer: false)

        do {
            try await client.install(
                package: "decline-me",
                onProgress: { _ in },
                onLicense: { licenses.record($0) }
            )
            XCTFail("expected licenseDeclined")
        } catch let error as SdkmanagerError {
            guard case .licenseDeclined(let package) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(package, "decline-me")
        }

        XCTAssertEqual(toolbox.recordedAnswers(), ["n"])
        XCTAssertEqual(licenses.recorded.count, 1)
    }

    func testInstallAnswersSeveralLicensePromptsIncludingTheReviewGate() async throws {
        let toolbox = try FakeToolbox.make()
        let client = toolbox.client()
        let licenses = LicenseRecorder(answer: true)

        try await client.install(
            package: "two-licenses",
            onProgress: { _ in },
            onLicense: { licenses.record($0) }
        )

        // The newline-terminated review gate plus the two prompts written
        // without a line terminator (the real tool's per-license form).
        XCTAssertEqual(toolbox.recordedAnswers(), ["y", "y", "y"])
        XCTAssertEqual(licenses.recorded.count, 3)
        guard licenses.recorded.count == 3 else { return }
        XCTAssertTrue(licenses.recorded[1].contains("android-googletv-license"), licenses.recorded[1])
        XCTAssertTrue(licenses.recorded[2].contains("android-sdk-license"), licenses.recorded[2])
    }

    func testANonZeroExitWithoutALicensePromptThrowsCommandFailed() async throws {
        let toolbox = try FakeToolbox.make()
        let client = toolbox.client()

        do {
            try await client.install(
                package: "fail-me",
                onProgress: { _ in },
                onLicense: { _ in true }
            )
            XCTFail("expected commandFailed")
        } catch let error as SdkmanagerError {
            guard case .commandFailed(let message) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("boom: cannot install"), message)
            XCTAssertTrue(message.contains("fail-me"), message)
        }
    }

    func testCancellingInstallThrowsCancelledAndStopsTheTool() async throws {
        let toolbox = try FakeToolbox.make()
        let client = toolbox.client()
        let install = Task {
            try await client.install(
                package: "hang-me",
                onProgress: { _ in },
                onLicense: { _ in true }
            )
        }

        try await waitForFile(toolbox.startedFile, timeout: .seconds(10))
        client.cancel()

        do {
            try await withTimeout(.seconds(15)) { try await install.value }
            XCTFail("expected the install to be cancelled")
        } catch is TimedOut {
            XCTFail("the install did not stop after cancel()")
        } catch let error as SdkmanagerError {
            guard case .cancelled = error else {
                return XCTFail("unexpected error: \(error)")
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - Uninstall

    func testUninstallRunsSdkmanagerAndRemovesThePackage() async throws {
        let toolbox = try FakeToolbox.make()
        let package = "system-images;android-35;google_apis;arm64-v8a"
        let directory = try toolbox.installPackage(package)

        try await toolbox.client().uninstall(package: package, sdkRoot: toolbox.sdkRoot)

        XCTAssertEqual(toolbox.recordedArgs(), ["--uninstall", package])
        XCTAssertEqual(toolbox.recordedInfo(), ["JAVA_HOME=\(toolbox.javaHome.path)"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertFalse(SdkPackageStorage.isInstalled(package: package, sdkRoot: toolbox.sdkRoot))
    }

    /// sdkmanager exits 0 when it cannot find the package; that must not be
    /// reported as a successful removal.
    func testUninstallOfAPackageSdkmanagerCannotFindThrows() async throws {
        let toolbox = try FakeToolbox.make()

        do {
            try await toolbox.client().uninstall(package: "system-images;android-99;missing;arm64-v8a")
            XCTFail("expected commandFailed")
        } catch let error as SdkmanagerError {
            guard case .commandFailed(let message) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("did not find"), message)
        }
    }

    func testUninstallThatLeavesThePackageInstalledThrows() async throws {
        let toolbox = try FakeToolbox.make()
        let package = "system-images;android-35;keep;arm64-v8a"
        try toolbox.installPackage(package)

        do {
            try await toolbox.client().uninstall(package: package, sdkRoot: toolbox.sdkRoot)
            XCTFail("expected commandFailed")
        } catch let error as SdkmanagerError {
            guard case .commandFailed(let message) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("still installed"), message)
        }
    }

    func testUninstallSurfacesANonZeroExit() async throws {
        let toolbox = try FakeToolbox.make()

        do {
            try await toolbox.client().uninstall(package: "platforms;android-fail")
            XCTFail("expected commandFailed")
        } catch let error as SdkmanagerError {
            guard case .commandFailed(let message) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("boom: cannot uninstall"), message)
            XCTAssertTrue(message.contains("exit code 3"), message)
            XCTAssertFalse(message.contains("%"), "progress redraws must not reach the message: \(message)")
        }
    }

    /// A value the tool would read as an option (`--licenses` would start
    /// the license flow) never reaches it.
    func testUninstallRejectsAnythingButAPackagePath() async throws {
        let toolbox = try FakeToolbox.make()

        for package in ["--licenses", "", "system-images;;x", "a b", "platforms;../../etc"] {
            do {
                try await toolbox.client().uninstall(package: package)
                XCTFail("expected \(package) to be rejected")
            } catch let error as SdkmanagerError {
                guard case .commandFailed = error else {
                    return XCTFail("unexpected error: \(error)")
                }
            }
        }
        XCTAssertEqual(toolbox.recordedArgs(), [])
    }

    func testLocateFindsSdkmanagerUnderAConfiguredSdkRoot() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("cmdline-tools/latest/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let tool = bin.appendingPathComponent("sdkmanager")
        try "#!/bin/sh\nexit 0\n".write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: tool.path
        )

        let client = SdkmanagerClient.locate(environment: [
            "ANDROID_HOME": root.path,
            "PATH": "/usr/bin:/bin",
        ])

        XCTAssertEqual(client?.sdkmanagerURL.path, tool.path)
    }

    /// Opt-in real check: `DHP_REAL_SDKMANAGER=1 swift test --filter
    /// SdkmanagerClientTests/testRealSdkmanagerListingParsesWhenEnabled`
    /// runs `--list` against the installed tool (no downloads).
    func testRealSdkmanagerListingParsesWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["DHP_REAL_SDKMANAGER"] == "1" else {
            throw XCTSkip("set DHP_REAL_SDKMANAGER=1 to run the real sdkmanager check")
        }
        guard let client = SdkmanagerClient.locate() else {
            throw XCTSkip("no sdkmanager installed")
        }

        let images = try await client.listAvailableImages()

        XCTAssertFalse(images.isEmpty)
        for image in images {
            XCTAssertTrue(image.package.hasPrefix("system-images;"), image.package)
            XCTAssertFalse(image.abi.isEmpty, image.package)
        }
    }

    // MARK: - Fake tool

    /// A temporary directory holding an executable fake `sdkmanager` and a
    /// fake `java` that always succeeds, plus the files the fake records.
    private struct FakeToolbox {
        let root: URL
        let sdkmanager: URL
        let java: URL

        var javaHome: URL { java.deletingLastPathComponent().deletingLastPathComponent() }
        var argsFile: URL { root.appendingPathComponent("args.txt") }
        var infoFile: URL { root.appendingPathComponent("info.txt") }
        var answerFile: URL { root.appendingPathComponent("answer.txt") }
        var startedFile: URL { root.appendingPathComponent("started.txt") }
        /// The SDK the fake's `--uninstall` removes packages from.
        var sdkRoot: URL { root.appendingPathComponent("sdk", isDirectory: true) }

        func client(environment: [String: String] = ["PATH": "/usr/bin:/bin"]) -> SdkmanagerClient {
            SdkmanagerClient(sdkmanagerURL: sdkmanager, javaURL: java, environment: environment)
        }

        /// Lays out an installed package (manifest plus an image file).
        @discardableResult
        func installPackage(_ package: String) throws -> URL {
            let directory = try XCTUnwrap(SdkPackageStorage.directory(forPackage: package, sdkRoot: sdkRoot))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("<package/>".utf8).write(to: directory.appendingPathComponent("package.xml"))
            try Data(repeating: 7, count: 4096).write(to: directory.appendingPathComponent("system.img"))
            return directory
        }

        func recordedArgs() -> [String] {
            lines(of: argsFile)
        }

        func recordedInfo() -> [String] {
            lines(of: infoFile)
        }

        func recordedAnswers() -> [String] {
            lines(of: answerFile)
        }

        private func lines(of url: URL) -> [String] {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").map(String.init)
        }

        static func make(listExit: Int = 0) throws -> FakeToolbox {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "SdkmanagerClientTests-\(UUID().uuidString)",
                    isDirectory: true
                )
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

            let java = root.appendingPathComponent("jdk/bin/java", isDirectory: false)
            try FileManager.default.createDirectory(
                at: java.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try writeScript(at: java, content: "#!/bin/sh\necho 'openjdk version \"21\"' >&2\n")

            let sdkmanager = root.appendingPathComponent("fake-sdkmanager")
            try writeScript(at: sdkmanager, content: script(root: root, listExit: listExit))

            return FakeToolbox(root: root, sdkmanager: sdkmanager, java: java)
        }

        private static func writeScript(at url: URL, content: String) throws {
            try content.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: url.path
            )
        }

        /// `--list` prints a listing fixture and exits with `listExit`.
        ///
        /// An install prints `\r`-joined progress, then the license text with
        /// a prompt written without a line terminator (exactly how the real
        /// tool writes `Accept? (y/N):`), records the answer stdin receives
        /// and exits 0 for `y` / 1 for `n`. The package argument selects the
        /// behavior; anything unrecognized is the accepting path.
        private static func script(root: URL, listExit: Int) -> String {
            #"""
            #!/bin/sh
            ROOT="\#(root.path)"
            printf '%s\n' "$@" >> "$ROOT/args.txt"
            printf 'JAVA_HOME=%s\n' "$JAVA_HOME" >> "$ROOT/info.txt"

            if [ "$1" = "--uninstall" ]; then
              printf '[====      ] 10%% Loading local repository...\r'
              case "$2" in
                *missing*)
                  printf 'Warning: Unable to find package %s\n' "$2"
                  exit 0
                  ;;
                *fail*)
                  printf 'boom: cannot uninstall\n' >&2
                  exit 3
                  ;;
                *keep*)
                  exit 0
                  ;;
              esac
              rm -rf "$ROOT/sdk/$(printf '%s' "$2" | tr ';' '/')"
              printf '[==========] 100%% Uninstalling...\n'
              exit 0
            fi

            if [ "$1" = "--list" ]; then
              if [ "\#(listExit)" -ne 0 ]; then
                printf 'fatal: repository unavailable\n' >&2
                exit \#(listExit)
              fi
              printf 'Loading package information...\n'
              printf '[=========                              ] 25%% Loading local repository...\r\n'
              printf 'Available Packages:\n'
              printf '  Path                                            | Version | Description\n'
              printf '  system-images;android-35;google_apis;arm64-v8a  | 9       | Google APIs ARM 64 v8a System Image\n'
              printf '  emulator                                        | 37.2.12 | Android Emulator\n'
              printf '  system-images;android-36;google_atd;arm64-v8a   | 1       | Google APIs ATD ARM 64 System Image\n'
              exit 0
            fi

            case "$1" in
              *decline*)
                printf 'License android-sdk-license:\n---------------------------------------\nTerms and Conditions\nAccept? (y/N): '
                read answer
                printf '%s' "$answer" > "$ROOT/answer.txt"
                printf 'Skipping following packages as the license is not accepted:\n'
                exit 1
                ;;
              *two-licenses*)
                printf '7 of 7 SDK package licenses not accepted.\n'
                printf 'Review licenses that have not been accepted (y/N)? \n'
                read review
                printf 'License android-googletv-license:\n---------------------------------------\nTerms and Conditions\nAccept? (y/N): '
                read first
                printf 'License android-sdk-license:\n---------------------------------------\nTerms and Conditions\nAccept? (y/N): '
                read second
                printf '%s\n%s\n%s\n' "$review" "$first" "$second" > "$ROOT/answer.txt"
                exit 0
                ;;
              *hang*)
                printf 'Fetching remote repository...\n'
                : > "$ROOT/started.txt"
                exec sleep 30
                ;;
              *fail*)
                printf 'boom: cannot install\n' >&2
                exit 4
                ;;
              *)
                printf '[==  ] 25%% Fetching remote repository...\r'
                printf '[====] 50%% Fetching remote repository...\r'
                printf 'License android-sdk-license:\n---------------------------------------\nTerms and Conditions\nAccept? (y/N): '
                read answer
                printf '%s' "$answer" > "$ROOT/answer.txt"
                printf 'Installing...\n'
                printf '[=======================================] 100%% Computing updates...\n'
                exit 0
                ;;
            esac
            """#
        }
    }

    // MARK: - Recorders

    private final class ProgressRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Double?] = []

        func append(_ value: Double?) {
            lock.lock()
            defer { lock.unlock() }
            values.append(value)
        }

        var recorded: [Double?] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    private final class LicenseRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private let answer: Bool
        private var texts: [String] = []

        init(answer: Bool) {
            self.answer = answer
        }

        func record(_ text: String) -> Bool {
            lock.lock()
            texts.append(text)
            lock.unlock()
            return answer
        }

        var recorded: [String] {
            lock.lock()
            defer { lock.unlock() }
            return texts
        }
    }

    // MARK: - Helpers

    private struct TimedOut: Error {}

    private func withTimeout<T: Sendable>(
        _ timeout: Duration,
        operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TimedOut()
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private func waitForFile(_ url: URL, timeout: Duration) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if FileManager.default.fileExists(atPath: url.path) {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw TimedOut()
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SdkmanagerClientTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
