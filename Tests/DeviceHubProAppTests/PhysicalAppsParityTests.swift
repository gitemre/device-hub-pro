import AppKit
import Foundation
import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// The Apps tab at Device Hub parity: the scope popup
/// (All Apps by default, User Apps), real icons (lazy, cached, at most two fetches at
/// a time, the glyph on failure), the row menu, and no Open URL bar.
///
/// `devicectl-info-apps-default-apps.json` and `devicectl-info-appIcon.json` are
/// the trimmed captures described in `ApplePhysicalAppsListingTests`.
@MainActor
final class PhysicalAppsScopeTests: XCTestCase {
    private static let udid = PhysicalFixtures.udid

    private struct Harness {
        let stub: StubTool
        let inventory: ApplePhysicalInventory
        let controller: PhysicalAppsController
        let status: StatusCenter
        let iconCache: URL
    }

    private func harness(enabled: Bool = true, extra: String = "") async throws -> Harness {
        let stub = try makePhysicalStub(extra: """
          \(extra)
          *"--include-default-apps"*)
            \(PhysicalFixtures.json("devicectl-info-apps-default-apps.json")) ;;
          *"device info apps"*)
            \(PhysicalFixtures.json("devicectl-info-apps-after-install.json")) ;;
        """)
        let inventory = try await makeListedPhysicalInventory(stub: stub, enabled: enabled)
        let status = StatusCenter()
        let cache = try makeTemporaryFolder("icons")
        let controller = PhysicalAppsController(
            inventory: inventory,
            status: status,
            picker: TestPicker(),
            temporaryDirectory: try makeTemporaryFolder("apps"),
            iconCacheDirectory: cache
        )
        return Harness(stub: stub, inventory: inventory, controller: controller, status: status, iconCache: cache)
    }

    // MARK: Scope

    func testTheScopePopupOffersAllAppsAndUserAppsAndDefaultsToAllApps() async throws {
        XCTAssertEqual(PhysicalAppScope.allCases.map(\.label), ["All Apps", "User Apps"])
        XCTAssertFalse(PhysicalAppScope.userApps.includesDefaultApps)
        XCTAssertTrue(PhysicalAppScope.allApps.includesDefaultApps)
        let h = try await harness()
        XCTAssertEqual(h.controller.scope, .allApps)
    }

    /// The default listing is the home screen's apps (Device Hub lists
    /// nearly all of the phone's apps): exactly `--include-default-apps`, the
    /// system apps with the developer ones.
    func testTheDefaultListingAddsTheIncludeDefaultAppsFlagAndListsTheSystemApps() async throws {
        let h = try await harness()
        await h.controller.load(udid: Self.udid)
        let calls = h.stub.deviceCalls.filter { $0.contains("device info apps") }
        XCTAssertEqual(calls.count, 1)
        XCTAssertTrue(calls[0].hasSuffix("--include-default-apps"), calls[0])
        XCTAssertEqual(h.controller.apps.count, 6)
        XCTAssertEqual(h.controller.loadedScope, .allApps)
        // Sorted by name like Device Hub's list.
        let titles = h.controller.apps.map(\.title)
        XCTAssertEqual(titles, titles.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
        XCTAssertTrue(h.controller.apps.contains { $0.bundleIdentifier == "com.apple.calculator" })
    }

    /// "User Apps" is devicectl's plain listing, argv unchanged.
    func testUserAppsRunsThePlainListing() async throws {
        let h = try await harness()
        h.controller.scope = .userApps
        await h.controller.load(udid: Self.udid)
        let calls = h.stub.deviceCalls.filter { $0.contains("device info apps") }
        XCTAssertEqual(calls.count, 1)
        XCTAssertFalse(calls[0].contains("--include-default-apps"), calls[0])
        XCTAssertTrue(calls[0].contains("device info apps --device \(PhysicalFixtures.coreDeviceIdentifier)"), calls[0])
        XCTAssertEqual(h.controller.apps.count, 1)
        XCTAssertEqual(h.controller.loadedScope, .userApps)
    }

    /// Hidden, internal and App Clip entries are not on the home screen: the
    /// All Apps list leaves them out. SYNTHETIC: the capture holds none, so the
    /// flags are set on copies of its entries.
    func testAllAppsLeavesOutHiddenInternalAndAppClipEntries() async throws {
        var document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try PhysicalFixtures.data("devicectl-info-apps-default-apps.json")) as? [String: Any]
        )
        var result = try XCTUnwrap(document["result"] as? [String: Any])
        var apps = try XCTUnwrap(result["apps"] as? [[String: Any]])
        apps[0]["hidden"] = true
        apps[1]["internalApp"] = true
        apps[2]["appClip"] = true
        result["apps"] = apps
        document["result"] = result
        let file = try makeTemporaryFolder("apps-flags").appendingPathComponent("apps.json")
        try JSONSerialization.data(withJSONObject: document).write(to: file)
        let h = try await harness(extra: """
          *"--include-default-apps"*) \(PhysicalFixtures.json(from: file.path)) ;;
        """)
        await h.controller.load(udid: Self.udid)
        XCTAssertEqual(h.controller.apps.count, 4)
        let leftOut = Set(try (0..<3).map { try XCTUnwrap(apps[$0]["bundleIdentifier"] as? String) })
        XCTAssertTrue(Set(h.controller.apps.map(\.bundleIdentifier)).isDisjoint(with: leftOut))
    }

    /// Switching the scope lists the other one; the listing read before shows
    /// at once when the scope comes back, while the fresh read runs.
    func testSwitchingTheScopeReloadsTheOtherListingAndKeepsTheLastOneToShowAtOnce() async throws {
        let h = try await harness()
        await h.controller.load(udid: Self.udid)
        XCTAssertEqual(h.controller.apps.count, 6)
        h.controller.scope = .userApps
        await h.controller.load(udid: Self.udid)
        XCTAssertEqual(h.controller.apps.count, 1)
        // Back to All Apps: the cached 6 are there before the read finishes.
        h.controller.scope = .allApps
        let reload = Task { await h.controller.load(udid: Self.udid) }
        await Task.yield()
        XCTAssertEqual(h.controller.apps.count, 6)
        await reload.value
        XCTAssertEqual(h.controller.apps.count, 6)
    }

    func testTheListingMapsTheDefaultAppFlag() async throws {
        let h = try await harness()
        h.controller.scope = .allApps
        await h.controller.load(udid: Self.udid)
        func app(_ id: String) throws -> PhysicalApp { try XCTUnwrap(h.controller.apps.first { $0.bundleIdentifier == id }) }
        XCTAssertFalse(try app("com.devicehubpro.verifier").isDefaultApp)
        XCTAssertTrue(try app("com.apple.calculator").isDefaultApp)
        XCTAssertFalse(try app("com.example.app").isDefaultApp)
    }

    /// The home-screen list shows the apps a user sees: the system services
    /// the capture holds (no icon, not removable) and the UI-test runner are
    /// left out, the developer builds and the removable system apps stay.
    func testAllAppsLeavesOutSystemServicesAndTheTestRunner() async throws {
        let h = try await harness()
        await h.controller.load(udid: Self.udid)
        let ids = Set(h.controller.apps.map(\.bundleIdentifier))
        XCTAssertEqual(ids, [
            "com.devicehubpro.verifier", "com.devicehubpro.agent.host", "com.apple.AppStore",
            "com.apple.calculator", "com.apple.camera", "com.example.app",
        ])
    }

    func testOnlyPhoneAndSettingsSurviveAmongTheNonRemovableSystemApps() {
        func hidden(_ id: String, defaultApp: Bool = true, removable: Bool = false) -> Bool {
            PhysicalApp.isBackgroundSystemApp(bundleIdentifier: id, isDefaultApp: defaultApp, isRemovable: removable)
        }
        XCTAssertFalse(hidden("com.apple.mobilephone"))
        XCTAssertFalse(hidden("com.apple.Preferences"))
        XCTAssertTrue(hidden("com.apple.assistivetouchd"))
        XCTAssertTrue(hidden("com.apple.ActivityMessagesApp"))
        XCTAssertFalse(hidden("com.apple.calculator", removable: true))
        XCTAssertFalse(hidden("com.example.app", defaultApp: false, removable: true))
        XCTAssertTrue(PhysicalApp.isTestRunner(bundleIdentifier: "com.devicehubpro.agent.uitests.xctrunner"))
        XCTAssertFalse(PhysicalApp.isTestRunner(bundleIdentifier: "com.devicehubpro.agent.host"))
    }

    // MARK: Running

    /// The processes read (best effort) marks the apps that run: the
    /// executable sits directly in the bundle folder.
    func testTheListingMarksTheRunningApps() async throws {
        // The verifier's bundle folder as the apps capture reports it.
        let apps = try DevicectlJSON.decode(
            DevicectlAppList.self, from: try PhysicalFixtures.data("devicectl-info-apps-default-apps.json")
        ).value
        let verifierURL = try XCTUnwrap(apps.apps.first { $0.bundleIdentifier == "com.devicehubpro.verifier" }?.url)
        let bundle = verifierURL.hasSuffix("/") ? String(verifierURL.dropLast()) : verifierURL
        var document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try PhysicalFixtures.data("devicectl-info-processes.json")) as? [String: Any]
        )
        var result = try XCTUnwrap(document["result"] as? [String: Any])
        var processes = try XCTUnwrap(result["runningProcesses"] as? [[String: Any]])
        // SYNTHETIC: the capture holds no verifier process; the shape is the one
        // `PhysicalAppsControllerTests` proves for a running app and its extension.
        processes.append(["executable": "\(bundle)/DeviceHubProVerifier", "processIdentifier": 4951])
        result["runningProcesses"] = processes
        document["result"] = result
        let file = try makeTemporaryFolder("procs").appendingPathComponent("processes.json")
        try JSONSerialization.data(withJSONObject: document).write(to: file)

        let h = try await harness(extra: """
          *"device info processes"*) \(PhysicalFixtures.json(from: file.path)) ;;
        """)
        h.controller.scope = .allApps
        await h.controller.load(udid: Self.udid)
        // App Store and Camera really ran when the processes capture was taken
        // (their executables sit in the bundle folders the apps capture names);
        // the verifier is the synthetic one added above.
        XCTAssertEqual(
            h.controller.runningBundleIdentifiers,
            ["com.devicehubpro.verifier", "com.apple.AppStore", "com.apple.camera"]
        )
    }

    /// A failed processes read leaves nothing marked, and the list still shows.
    func testAFailedProcessesReadStillListsTheApps() async throws {
        let h = try await harness()
        await h.controller.load(udid: Self.udid)
        XCTAssertEqual(h.controller.apps.count, 6)
        XCTAssertEqual(h.controller.runningBundleIdentifiers, [])
        XCTAssertNil(h.controller.loadProblem)
    }

    // MARK: Open URL

    /// The Open URL bar is gone from the tab; the action stays for the menus.
    func testOpenURLStaysAnAPIForTheMenus() async throws {
        let h = try await harness(extra: """
          *"process openURL"*) \(PhysicalFixtures.json("devicectl-process-openURL.json")) ;;
        """)
        // Without the window's physical selection there is nothing to open on.
        let refused = await h.controller.openURL("https://example.com")
        XCTAssertFalse(refused)
        XCTAssertTrue(h.stub.deviceCalls.isEmpty)

        h.controller.selectedUDID = { Self.udid }
        let opened = await h.controller.openURL("https://example.com")
        XCTAssertTrue(opened)
        let call = try XCTUnwrap(h.stub.deviceCalls.first { $0.contains("process openURL") })
        XCTAssertTrue(call.contains("https://example.com"), call)
    }

    func testTheAppsTabHasNoOpenURLField() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(
            contentsOf: root.appendingPathComponent("Sources/DeviceHubProApp/Apple/PhysicalAppsInspectorView.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(view.contains("Open URL:"))
        XCTAssertFalse(view.contains("openURLRow"))
        XCTAssertFalse(view.contains("openURLDraft"))
        XCTAssertTrue(view.contains("PhysicalAppScope.allCases"), "the scope popup is there")
    }

    // MARK: Icons through the controller

    /// The controller fetches an icon through `device info appIcon` with the
    /// fixed shape, the PNG lands in the cache and the JSON answer is read.
    func testTheControllerFetchesAnIconWithTheFixedArgv() async throws {
        let png = try makePNG()
        let pngFile = try makeTemporaryFolder("png").appendingPathComponent("icon.png")
        try png.write(to: pngFile)
        let arm = """
          *"device info appIcon"*)
            PREV=""; for ARG in "$@"; do
              if [ "$PREV" = "--json-output" ]; then cp \(SimulatorFixtures.quoted(PhysicalFixtures.url("devicectl-info-appIcon.json").path)) "$ARG"; fi
              if [ "$PREV" = "--destination" ]; then cp \(SimulatorFixtures.quoted(pngFile.path)) "$ARG"; fi
              PREV="$ARG"
            done ;;
        """
        let h = try await harness(extra: arm)
        h.controller.scope = .allApps
        await h.controller.load(udid: Self.udid)
        let calculator = try XCTUnwrap(h.controller.apps.first { $0.bundleIdentifier == "com.apple.calculator" })

        h.controller.icons.request(calculator, udid: Self.udid)
        await expectEventually { h.controller.icons.image(for: calculator, udid: Self.udid) != nil }

        let call = try XCTUnwrap(h.stub.deviceCalls.first { $0.contains("device info appIcon") })
        XCTAssertTrue(call.hasPrefix("device info appIcon --device \(PhysicalFixtures.coreDeviceIdentifier) --json-output "), call)
        XCTAssertTrue(call.contains("--app-bundle-id com.apple.calculator --width 64 --height 64 --destination "), call)
        // A second request costs no device call: it is in memory.
        h.controller.icons.request(calculator, udid: Self.udid)
        XCTAssertEqual(h.stub.deviceCalls.filter { $0.contains("device info appIcon") }.count, 1)
        // And on disk, named by bundle id and version, in a folder that is not the UDID.
        let key = PhysicalAppIconStore.key(for: calculator, udid: Self.udid)
        let file = h.controller.icons.file(for: key)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(file.lastPathComponent, "com.apple.calculator-12.0.png")
        XCTAssertFalse(file.path.contains(Self.udid))
        XCTAssertTrue(file.path.hasPrefix(h.iconCache.path))
    }

    /// A device that cannot be asked yields no icon and no device call.
    func testADeviceThatIsNotEnabledGetsNoIconCalls() async throws {
        let h = try await harness(enabled: false)
        let app = PhysicalApp(DevicectlInstalledApp.testValue(bundleIdentifier: "com.apple.calculator", version: "12.0"))
        h.controller.icons.request(app, udid: Self.udid)
        await expectEventually { h.controller.icons.hasFailed(app, udid: Self.udid) }
        XCTAssertNil(h.controller.icons.image(for: app, udid: Self.udid))
        XCTAssertTrue(h.stub.deviceCalls.isEmpty, "nothing reached the device")
    }
}

// MARK: - The icon store

/// The icon store on its own: lazy, cached per device + bundle id + version
/// on disk, at most two fetches at a time, the generic glyph on failure.
@MainActor
final class PhysicalAppIconStoreTests: XCTestCase {
    private static let udid = PhysicalFixtures.udid

    /// What the fake device did.
    @MainActor
    private final class Device {
        var fetched: [String] = []
        var current = 0
        var maxSeen = 0
        var gate: OpenAppsGate?
        var failFor: Set<String> = []
        var writeGarbageFor: Set<String> = []
        let png: Data

        init(png: Data) { self.png = png }

        func fetch(_ udid: String, _ bundleID: String, _ size: Int, _ destination: URL) async throws {
            fetched.append("\(udid)/\(bundleID)/\(size)")
            current += 1
            maxSeen = max(maxSeen, current)
            defer { current -= 1 }
            if let gate { await gate.wait() }
            if failFor.contains(bundleID) { throw PhysicalPreviewError(message: "no icon") }
            try (writeGarbageFor.contains(bundleID) ? Data("not a png".utf8) : png).write(to: destination)
        }
    }

    private func makeStore(
        cache: URL? = nil,
        concurrency: Int = 2,
        device: Device
    ) throws -> PhysicalAppIconStore {
        let directory = try cache ?? makeTemporaryFolder("icon-store")
        return PhysicalAppIconStore(cacheDirectory: directory, maxConcurrent: concurrency) { udid, bundle, size, destination in
            try await device.fetch(udid, bundle, size, destination)
        }
    }

    private func app(_ id: String, version: String? = "1.0") -> PhysicalApp {
        PhysicalApp(DevicectlInstalledApp.testValue(bundleIdentifier: id, version: version))
    }

    func testNothingIsFetchedUntilARowAsks() throws {
        let device = Device(png: try makePNG())
        let store = try makeStore(device: device)
        XCTAssertNil(store.image(for: app("com.a.one"), udid: Self.udid))
        XCTAssertEqual(store.fetchCount, 0)
        XCTAssertEqual(device.fetched, [])
    }

    func testARequestFetchesOnceAndDrawsTheImage() async throws {
        let device = Device(png: try makePNG())
        let store = try makeStore(device: device)
        let one = app("com.a.one")
        store.request(one, udid: Self.udid)
        store.request(one, udid: Self.udid)
        await expectEventually { store.image(for: one, udid: Self.udid) != nil }
        XCTAssertEqual(device.fetched, ["\(Self.udid)/com.a.one/64"], "asked twice, fetched once, at 64 px")
        store.request(one, udid: Self.udid)
        XCTAssertEqual(device.fetched.count, 1)
    }

    /// A cached PNG is read from disk at once, without a device call, also by
    /// a new store on the same folder (the next launch).
    func testTheDiskCacheSurvivesAndCostsNoFetch() async throws {
        let cache = try makeTemporaryFolder("icon-cache")
        let first = Device(png: try makePNG())
        let store = try makeStore(cache: cache, device: first)
        let one = app("com.a.one", version: "2.5")
        store.request(one, udid: Self.udid)
        await expectEventually { store.image(for: one, udid: Self.udid) != nil }
        XCTAssertEqual(first.fetched.count, 1)

        let second = Device(png: try makePNG())
        let reopened = try makeStore(cache: cache, device: second)
        reopened.request(one, udid: Self.udid)
        XCTAssertNotNil(reopened.image(for: one, udid: Self.udid), "read synchronously from disk")
        XCTAssertEqual(second.fetched, [])
        XCTAssertEqual(reopened.fetchCount, 0)
    }

    /// The key is device + bundle id + version: a new version, another device
    /// and another app are each their own file.
    func testTheCacheIsKeyedByDeviceBundleAndVersion() async throws {
        let cache = try makeTemporaryFolder("icon-keys")
        let device = Device(png: try makePNG())
        let store = try makeStore(cache: cache, device: device)
        let v1 = app("com.a.one", version: "1.0")
        let v2 = app("com.a.one", version: "2.0")
        store.request(v1, udid: Self.udid)
        store.request(v2, udid: Self.udid)
        store.request(v1, udid: "00000000-0000000000000001")
        await expectEventually { device.fetched.count == 3 && store.runningCount == 0 }
        XCTAssertEqual(device.fetched.count, 3)

        let files = [
            store.file(for: PhysicalAppIconStore.key(for: v1, udid: Self.udid)),
            store.file(for: PhysicalAppIconStore.key(for: v2, udid: Self.udid)),
            store.file(for: PhysicalAppIconStore.key(for: v1, udid: "00000000-0000000000000001")),
        ]
        XCTAssertEqual(Set(files.map(\.path)).count, 3)
        for file in files { XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), file.path) }
        // Two devices, two folders; neither is named by the UDID.
        XCTAssertNotEqual(files[0].deletingLastPathComponent(), files[2].deletingLastPathComponent())
        XCTAssertFalse(files.contains { $0.path.contains(Self.udid) })
        // A version with odd characters is a safe file name.
        let odd = app("com.a.two", version: "1.0/beta 2")
        XCTAssertEqual(
            store.file(for: PhysicalAppIconStore.key(for: odd, udid: Self.udid)).lastPathComponent,
            "com.a.two-1.0_beta_2.png"
        )
        // A version-less app has a name of its own.
        let bare = app("com.a.three", version: nil)
        XCTAssertEqual(store.file(for: PhysicalAppIconStore.key(for: bare, udid: Self.udid)).lastPathComponent, "com.a.three.png")
    }

    /// Bounded: with six rows asking, never more than two fetches run at once, and
    /// all six load once the device answers.
    func testAtMostTwoFetchesRunAtOnce() async throws {
        let device = Device(png: try makePNG())
        let gate = OpenAppsGate()
        device.gate = gate
        let store = try makeStore(concurrency: 2, device: device)
        let apps = (1...6).map { app("com.a.app\($0)") }
        for app in apps { store.request(app, udid: Self.udid) }

        await expectEventually { device.current == 2 }
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(device.current, 2, "two run, four wait")
        XCTAssertEqual(store.runningCount, 2)
        XCTAssertEqual(device.fetched.count, 2)

        await gate.open()
        await expectEventually { apps.allSatisfy { store.image(for: $0, udid: Self.udid) != nil } }
        XCTAssertEqual(device.fetched.count, 6)
        XCTAssertLessThanOrEqual(device.maxSeen, 2)
        XCTAssertEqual(store.runningCount, 0)
    }

    func testTheBoundFollowsTheConfiguredConcurrency() async throws {
        let device = Device(png: try makePNG())
        device.gate = OpenAppsGate()
        let store = try makeStore(concurrency: 1, device: device)
        for id in 1...3 { store.request(app("com.a.app\(id)"), udid: Self.udid) }
        await expectEventually { device.current == 1 }
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(device.maxSeen, 1)
        XCTAssertEqual(PhysicalAppIconStore.defaultMaxConcurrent, 2, "the default is two")
        await device.gate?.open()
        await expectEventually { store.fetchCount == 3 && store.runningCount == 0 }
    }

    /// A row that scrolls away before its turn drops its request; a running fetch
    /// finishes and is cached.
    func testARowThatScrollsAwayDropsItsPendingFetch() async throws {
        let device = Device(png: try makePNG())
        let gate = OpenAppsGate()
        device.gate = gate
        let store = try makeStore(concurrency: 1, device: device)
        let a = app("com.a.first"), b = app("com.a.second"), c = app("com.a.third")
        store.request(a, udid: Self.udid)
        store.request(b, udid: Self.udid)
        store.request(c, udid: Self.udid)
        await expectEventually { device.current == 1 }
        store.cancel(c, udid: Self.udid)
        store.cancel(a, udid: Self.udid) // running: not stopped
        await gate.open()
        await expectEventually { store.runningCount == 0 && store.fetchCount == 2 }
        XCTAssertEqual(device.fetched, ["\(Self.udid)/com.a.first/64", "\(Self.udid)/com.a.second/64"])
        XCTAssertNotNil(store.image(for: a, udid: Self.udid))
        XCTAssertNil(store.image(for: c, udid: Self.udid))
    }

    /// A failure keeps the generic glyph, is not asked again and leaves nothing
    /// in the cache.
    func testAFailedFetchFallsBackToTheGlyphAndIsNotRetried() async throws {
        let cache = try makeTemporaryFolder("icon-fail")
        let device = Device(png: try makePNG())
        device.failFor = ["com.a.bad"]
        let store = try makeStore(cache: cache, device: device)
        let bad = app("com.a.bad"), good = app("com.a.good")
        store.request(bad, udid: Self.udid)
        store.request(good, udid: Self.udid)
        await expectEventually { store.hasFailed(bad, udid: Self.udid) && store.image(for: good, udid: Self.udid) != nil }
        XCTAssertNil(store.image(for: bad, udid: Self.udid))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: store.file(for: PhysicalAppIconStore.key(for: bad, udid: Self.udid)).path
        ))
        // The staged file did not stay.
        let folder = store.folder(for: PhysicalAppIconStore.key(for: bad, udid: Self.udid))
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.filter { $0.hasPrefix(".fetch-") } ?? []
        XCTAssertEqual(leftovers, [])

        store.request(bad, udid: Self.udid)
        XCTAssertEqual(device.fetched.filter { $0.contains("com.a.bad") }.count, 1, "not asked again")
        // A forgotten failure may be asked again (a refresh).
        store.forgetFailures()
        store.request(bad, udid: Self.udid)
        await expectEventually { device.fetched.filter { $0.contains("com.a.bad") }.count == 2 }
    }

    /// A file that is no image is a failure, never cached.
    func testAFileThatIsNoImageIsAFailure() async throws {
        let device = Device(png: try makePNG())
        device.writeGarbageFor = ["com.a.garbage"]
        let store = try makeStore(device: device)
        let garbage = app("com.a.garbage")
        store.request(garbage, udid: Self.udid)
        await expectEventually { store.hasFailed(garbage, udid: Self.udid) }
        XCTAssertNil(store.image(for: garbage, udid: Self.udid))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: store.file(for: PhysicalAppIconStore.key(for: garbage, udid: Self.udid)).path
        ))
    }

    func testTheDefaultCacheIsUnderTheUsersCaches() {
        let path = PhysicalAppIconStore.defaultCacheDirectory().path
        XCTAssertTrue(path.hasSuffix("/Library/Caches/DeviceHubPro/icons"), path)
    }
}

// MARK: - The row menu

final class PhysicalAppMenuTests: XCTestCase {
    private func app(_ id: String) throws -> PhysicalApp {
        let list = try DevicectlJSON.decode(
            DevicectlAppList.self, from: try PhysicalFixtures.data("devicectl-info-apps-default-apps.json")
        ).value
        return PhysicalApp(try XCTUnwrap(list.apps.first { $0.bundleIdentifier == id }, id))
    }

    /// A developer build (the verifier): container and Uninstall; Terminate
    /// only while it runs.
    func testADeveloperApp() throws {
        let verifier = try app("com.devicehubpro.verifier")
        let idle = PhysicalAppMenu.make(app: verifier, isRunning: false, isBusy: false)
        XCTAssertEqual(idle, PhysicalAppMenu(
            showsTerminate: false, showsCopyVersion: true,
            showsAppContainer: true,
            showsUninstall: true, uninstallEnabled: true
        ))
        XCTAssertTrue(PhysicalAppMenu.make(app: verifier, isRunning: true, isBusy: false).showsTerminate)
    }

    /// A system app that cannot be removed: only Launch and the copies.
    func testASystemAppThatCannotBeRemoved() throws {
        let menu = PhysicalAppMenu.make(app: try app("com.apple.BluetoothUIService"), isRunning: false, isBusy: false)
        XCTAssertFalse(menu.showsAppContainer)
        XCTAssertFalse(menu.showsUninstall)
        XCTAssertTrue(menu.showsCopyVersion)
    }

    /// A removable system app (Calculator): Uninstall, no App Container.
    func testARemovableSystemApp() throws {
        let menu = PhysicalAppMenu.make(app: try app("com.apple.calculator"), isRunning: false, isBusy: false)
        XCTAssertFalse(menu.showsAppContainer)
        XCTAssertTrue(menu.showsUninstall)
    }

    /// A third-party app from the store: no App Container (its container is not
    /// readable, so the item is not listed) and Uninstall.
    func testAThirdPartyApp() throws {
        let menu = PhysicalAppMenu.make(app: try app("com.example.app"), isRunning: false, isBusy: false)
        XCTAssertFalse(menu.showsAppContainer)
        XCTAssertTrue(menu.showsUninstall)
    }

    func testCopyVersionIsNotListedWithoutAVersionAndUninstallWaitsForTheDevice() throws {
        let noVersion = try app("com.apple.ShortcutsActions")
        XCTAssertNil(noVersion.displayVersion)
        XCTAssertFalse(PhysicalAppMenu.make(app: noVersion, isRunning: false, isBusy: false).showsCopyVersion)
        let busy = PhysicalAppMenu.make(app: try app("com.devicehubpro.verifier"), isRunning: false, isBusy: true)
        XCTAssertFalse(busy.uninstallEnabled)
    }

    /// Device Hub's wording, in the view: "Copy Bundle ID", "Copy Version",
    /// "App Container" and "Uninstall".
    func testTheMenuUsesDeviceHubsWording() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(
            contentsOf: root.appendingPathComponent("Sources/DeviceHubProApp/Apple/PhysicalAppsInspectorView.swift"),
            encoding: .utf8
        )
        for title in ["Launch", "Copy Bundle ID", "Copy Version", "App Container", "Uninstall", "Terminate", "Show Container Files…"] {
            XCTAssertTrue(view.contains("\"\(title)\""), title)
        }
        XCTAssertFalse(view.contains("Copy Bundle Identifier"))
    }
}

// MARK: - Helpers

extension DevicectlInstalledApp {
    /// An `apps[]` entry decoded from JSON, for the tests that need an app the
    /// captures do not have (only the two keys the icon store reads).
    static func testValue(bundleIdentifier: String, version: String?) -> DevicectlInstalledApp {
        var object: [String: Any] = ["bundleIdentifier": bundleIdentifier]
        if let version { object["version"] = version }
        // Force: the object is built here from valid keys.
        return try! JSONDecoder().decode(DevicectlInstalledApp.self, from: JSONSerialization.data(withJSONObject: object))
    }
}

/// A real PNG (a small solid square), the way `devicectl` writes an icon.
func makePNG() throws -> Data {
    let size = NSSize(width: 8, height: 8)
    let image = NSImage(size: size)
    image.lockFocus()
    NSColor.systemBlue.setFill()
    NSRect(origin: .zero, size: size).fill()
    image.unlockFocus()
    let tiff = try XCTUnwrap(image.tiffRepresentation)
    let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
    return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
}

actor OpenAppsGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}
