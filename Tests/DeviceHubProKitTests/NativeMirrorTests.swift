import CoreImage
import CoreVideo
import Foundation
import XCTest
import DeviceHubProNativeMirror
@testable import DeviceHubProKit

/// The native live view's pure parts: the endpoint
/// resolver, the frame cropper, the session on fakes, and the source guard.
/// Nothing here reaches a device or a private framework.
final class NativeMirrorTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    // MARK: Endpoint resolver

    /// The scrubbed `device info details` capture of the test iPhone
    /// (`Fixtures/ios27-device/`): the identifier and the tunnel address are
    /// same-length placeholders (`fd00:0000:0000::0` for the phone's end), so the
    /// host end below is a placeholder in the same /64, not a capture.
    private func details() throws -> DevicectlDeviceDetails {
        let url = Self.root.appendingPathComponent("Tests/DeviceHubProKitTests/Fixtures/ios27-device/devicectl-info-details.json")
        return try DevicectlJSON.decode(DevicectlDeviceDetails.self, from: Data(contentsOf: url)).value
    }

    private let interfaces: [NativeMirrorEndpoint.HostAddress] = [
        .init(interface: "lo0", address: "::1"),
        .init(interface: "en0", address: "fd00:0000:0000::2"),          // same prefix, not a tunnel
        .init(interface: "utun2", address: "fd11:0000:0000::2"),          // another phone's tunnel
        .init(interface: "utun3", address: "fd00:0000:0000::0"),          // the phone's own address
        .init(interface: "utun4", address: "fd00:0000:0000:0000::2"),     // the host end
    ]

    func testTheResolverFindsTheHostEndInThePhonesSubnet() throws {
        let endpoint = try NativeMirrorEndpoint.resolve(details: details(), interfaces: interfaces)
        XCTAssertEqual(endpoint.interface, "utun4")
        XCTAssertEqual(endpoint.hostAddress, "fd00:0000:0000:0000::2")
        XCTAssertEqual(endpoint.deviceAddress, "fd00:0000:0000::0")
        XCTAssertEqual(endpoint.productType, "iPhone13,2")
        XCTAssertEqual(endpoint.coreDeviceIdentifier, "00000000-0000-4000-8000-000000000001")
    }

    func testTheResolverRefusesWhatItCannotTie() throws {
        let id = "00000000-0000-4000-8000-000000000001"
        XCTAssertThrowsError(try NativeMirrorEndpoint.resolve(coreDeviceIdentifier: id, tunnelAddress: "fd00::1", productType: nil, interfaces: [
            .init(interface: "utun2", address: "fd11::2"),
        ])) { XCTAssertEqual($0 as? NativeMirrorEndpoint.ResolveError, .noHostInterface) }
        XCTAssertThrowsError(try NativeMirrorEndpoint.resolve(coreDeviceIdentifier: id, tunnelAddress: nil, productType: nil, interfaces: interfaces)) {
            XCTAssertEqual($0 as? NativeMirrorEndpoint.ResolveError, .noTunnelAddress)
        }
        XCTAssertThrowsError(try NativeMirrorEndpoint.resolve(coreDeviceIdentifier: id, tunnelAddress: "not an address", productType: nil, interfaces: interfaces))
        XCTAssertThrowsError(try NativeMirrorEndpoint.resolve(coreDeviceIdentifier: "nope", tunnelAddress: "fd00::1", productType: nil, interfaces: interfaces)) {
            XCTAssertEqual($0 as? NativeMirrorEndpoint.ResolveError, .notAnIdentifier)
        }
    }

    func testTheKillSwitchIsAnyNonEmptyValue() {
        XCTAssertFalse(NativeMirrorEndpoint.isDisabled(environment: [:]))
        XCTAssertFalse(NativeMirrorEndpoint.isDisabled(environment: ["DHP_DISABLE_NATIVE_MIRROR": ""]))
        XCTAssertTrue(NativeMirrorEndpoint.isDisabled(environment: ["DHP_DISABLE_NATIVE_MIRROR": "1"]))
    }

    func testTheHostAddressesComeFromTheInterfaces() {
        // Whatever this Mac has: the call works and only reports IPv6 entries.
        for entry in NativeMirrorEndpoint.currentHostAddresses() {
            XCTAssertFalse(entry.interface.isEmpty)
            XCTAssertTrue(entry.address.contains(":"))
        }
    }

    // MARK: Cropper

    private func makeBuffer(width: Int, height: Int, format: OSType = kCVPixelFormatType_32BGRA) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]]
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height, format, attributes as CFDictionary, &buffer), kCVReturnSuccess)
        return try XCTUnwrap(buffer)
    }

    func testTheCropperCutsThePaddingOff() throws {
        let frame = try makeBuffer(width: 1184, height: 2576)
        let cropper = NativeMirrorFrameCropper()
        let out = try XCTUnwrap(cropper.crop(frame, to: CGRect(x: 0, y: 0, width: 1170, height: 2532)))
        XCTAssertEqual(CVPixelBufferGetWidth(out), 1170)
        XCTAssertEqual(CVPixelBufferGetHeight(out), 2532)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(out), kCVPixelFormatType_32BGRA)
        XCTAssertNotNil(CVPixelBufferGetIOSurface(out))
        // A whole-frame BGRA rect passes through; a rect outside the frame is refused.
        XCTAssertTrue(try XCTUnwrap(cropper.crop(frame, to: CGRect(x: 0, y: 0, width: 1184, height: 2576))) === frame)
        XCTAssertNil(cropper.crop(frame, to: CGRect(x: 2000, y: 0, width: 10, height: 10)))
    }

    // MARK: Session on fakes

    private actor Steps {
        var events: [String] = []
        func add(_ event: String) { events.append(event) }
    }

    private final class FakeLease: FastInputLease, @unchecked Sendable {
        let lock = NSLock()
        private var _starts = 0, _stops = 0
        var starts: Int { lock.withLock { _starts } }
        var stops: Int { lock.withLock { _stops } }
        func start() async throws { lock.withLock { _starts += 1 } }
        func stop() async { lock.withLock { _stops += 1 } }
        func terminateNow() {}
    }

    private final class FakeStream: NativeMirroring, @unchecked Sendable {
        let onFrame: @Sendable (CVPixelBuffer, CGRect) -> Void
        let onError: @Sendable (NativeMirrorError) -> Void
        let startFailure: NativeMirrorError?
        let lock = NSLock()
        private var _stopped = 0
        var stopped: Int { lock.withLock { _stopped } }
        init(onFrame: @escaping @Sendable (CVPixelBuffer, CGRect) -> Void, onError: @escaping @Sendable (NativeMirrorError) -> Void, startFailure: NativeMirrorError?) {
            self.onFrame = onFrame; self.onError = onError; self.startFailure = startFailure
        }
        func start() async throws { if let startFailure { throw startFailure } }
        func stop() { lock.withLock { _stopped += 1 } }
    }

    private final class Streams: @unchecked Sendable {
        let lock = NSLock()
        private var made: [FakeStream] = []
        var failures: [NativeMirrorError?]
        init(failures: [NativeMirrorError?] = []) { self.failures = failures }
        var all: [FakeStream] { lock.withLock { made } }
        var factory: NativeMirrorStreamFactory {
            { [self] _, onFrame, onError in
                lock.withLock {
                    let failure = failures.isEmpty ? nil : failures.removeFirst()
                    let stream = FakeStream(onFrame: onFrame, onError: onError, startFailure: failure)
                    made.append(stream)
                    return stream
                }
            }
        }
    }

    private func endpoint() -> NativeMirrorEndpoint {
        NativeMirrorEndpoint(coreDeviceIdentifier: "00000000-0000-4000-8000-000000000001", interface: "utun4",
                             hostAddress: "fd00::2", deviceAddress: "fd00::1", productType: "iPhone13,2")
    }

    private func session(lease: FakeLease, streams: Streams, endpoint: @escaping @Sendable () async throws -> NativeMirrorEndpoint) -> PhysicalNativeMirrorSession {
        PhysicalNativeMirrorSession(
            hardwareUDID: "00000000-0000000000000000", endpointProvider: endpoint, lease: lease,
            makeStream: streams.factory, sleep: { _ in }
        )
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }

    func testFramesAreCroppedAndPublishedLatestOnly() async throws {
        let lease = FakeLease(), streams = Streams()
        let ep = endpoint()
        let session = session(lease: lease, streams: streams) { ep }
        XCTAssertEqual(session.transport, .physicalNativeMirror)
        XCTAssertEqual(session.viewKind, .nativeLive)
        session.start()
        try await waitUntil { streams.all.count == 1 && session.isRunning }
        let frame = try makeBuffer(width: 1184, height: 2576)
        streams.all[0].onFrame(frame, CGRect(x: 0, y: 0, width: 1170, height: 2532))
        let current = try XCTUnwrap(session.frames.current)
        XCTAssertEqual(current.width, 1170)
        XCTAssertEqual(current.height, 2532)
        // Turned phone: a landscape frame with its own rect replaces the store's size.
        streams.all[0].onFrame(try makeBuffer(width: 2576, height: 1184), CGRect(x: 0, y: 0, width: 2532, height: 1170))
        XCTAssertEqual(session.frames.currentSize?.width, 2532)
        XCTAssertEqual(lease.starts, 1)
        session.stop()
        XCTAssertFalse(session.isRunning)
        try await waitUntil { lease.stops >= 1 && streams.all[0].stopped >= 1 }
    }

    func testAStreamErrorEndsTheSessionWithItsMessage() async throws {
        let lease = FakeLease(), streams = Streams()
        let ep = endpoint()
        let session = session(lease: lease, streams: streams) { ep }
        session.start()
        try await waitUntil { streams.all.count == 1 && session.isRunning }
        streams.all[0].onError(NativeMirrorError(code: 7000, message: "no video frames for 12 seconds"))
        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(session.lastError, "no video frames for 12 seconds")
        try await waitUntil { lease.stops >= 1 }
    }

    func testAStartFailureLandsInLastErrorAndReleasesTheLease() async throws {
        let lease = FakeLease()
        let streams = Streams(failures: [NativeMirrorError(code: 1000, message: "CoreDevice is not installed")])
        let ep = endpoint()
        let session = session(lease: lease, streams: streams) { ep }
        session.start()
        try await waitUntil { !session.isRunning }
        XCTAssertEqual(session.lastError, "CoreDevice is not installed")
        try await waitUntil { lease.stops >= 1 }
    }

    func testAnUpTunnelIsAwaitedNotGivenUpOn() async throws {
        let lease = FakeLease()
        let down = NativeMirrorError(code: NativeMirrorError.tunnelDownCode, message: "tunnel down")
        let streams = Streams(failures: [down, down, nil])
        let ep = endpoint()
        let session = session(lease: lease, streams: streams) { ep }
        session.start()
        try await waitUntil { streams.all.count == 3 }
        XCTAssertTrue(session.isRunning)
        XCTAssertNil(session.lastError)
        XCTAssertEqual(streams.all[0].stopped, 1, "a failed attempt's stream is released")
        session.stop()
    }

    func testTheEndpointNotBeingThereYetIsRetriedThenReported() async throws {
        let lease = FakeLease(), streams = Streams()
        let session = session(lease: lease, streams: streams) { throw NativeMirrorEndpoint.ResolveError.noHostInterface }
        session.start()
        try await waitUntil { !session.isRunning }
        XCTAssertEqual(session.lastError, NativeMirrorEndpoint.ResolveError.noHostInterface.description)
        XCTAssertTrue(streams.all.isEmpty)
    }

    func testTheKillSwitchRefusesTheLiveFactory() {
        XCTAssertThrowsError(try PhysicalNativeMirrorSession.live(
            hardwareUDID: "x", environment: ["DHP_DISABLE_NATIVE_MIRROR": "1"],
            prepare: { throw NativeMirrorEndpoint.ResolveError.disabled }
        ))
    }

    // MARK: Source guards

    /// The stream's service and class words live only in the vendored target
    /// (and in this guard); the target links nothing private.
    func testTheStreamWordsLiveOnlyInTheNativeMirrorTarget() throws {
        let words = ["startmediastream", "mediastreamstart", "avcmediastreamnegotiator", "vcimagequeue"]
        let allowedPrefix = "Sources/DeviceHubProNativeMirror/"
        var found = Set<String>()
        var offenders: [String] = []
        for folder in ["Sources", "Tests", "Scripts", "ios", "android"] {
            let base = Self.root.appendingPathComponent(folder, isDirectory: true)
            guard let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { continue }
            for case let url as URL in enumerator {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true, (values.fileSize ?? 0) < 1_000_000,
                      let text = (try? Data(contentsOf: url)).flatMap({ String(data: $0, encoding: .utf8) })?.lowercased()
                else { continue }
                let path = String(url.path.dropFirst(Self.root.path.count + 1))
                guard words.contains(where: text.contains) else { continue }
                if path.hasPrefix(allowedPrefix) { found.insert(path) }
                else if path != "Tests/DeviceHubProKitTests/NativeMirrorTests.swift", !path.contains("/Fixtures/") { offenders.append(path) }
            }
        }
        XCTAssertEqual(offenders, [])
        XCTAssertFalse(found.isEmpty, "the scan sees the vendored target")
        let manifest = try String(contentsOf: Self.root.appendingPathComponent("Package.swift"), encoding: .utf8)
        XCTAssertFalse(manifest.contains("AVConference"), "nothing private is linked")
    }

    func testTheNativeMirrorSourcesResolveEverythingAtRunTime() throws {
        let source = try String(
            contentsOf: Self.root.appendingPathComponent("Sources/DeviceHubProNativeMirror/AQNativeMirrorSession.m"), encoding: .utf8
        )
        XCTAssertTrue(source.contains("dlopen(") && source.contains("dlsym(") && source.contains("NSClassFromString"))
        // What was stripped from upstream's mirror stays out.
        for word in ["universalhid", "hid_report", "digitizer", "sqlite", "NSWindow"] {
            XCTAssertFalse(source.lowercased().contains(word.lowercased()), word)
        }
        let provenance = try String(contentsOf: Self.root.appendingPathComponent("fastinput/PROVENANCE.md"), encoding: .utf8)
        XCTAssertTrue(provenance.contains("mirror.m") && provenance.contains("f2e85a6d60c45f18e6f9f2a306f709ffb9710392"))
    }

    /// The Camera switch stays in the capture provider alone, and the native
    /// session never touches AVFoundation or CoreMediaIO.
    func testTheNativeSessionTouchesNoCaptureFramework() throws {
        for name in ["PhysicalNativeMirrorSession.swift", "NativeMirrorEndpoint.swift", "NativeMirrorFrameCropper.swift"] {
            let text = try String(contentsOf: Self.root.appendingPathComponent("Sources/DeviceHubProKit/Apple/Live/\(name)"), encoding: .utf8)
            XCTAssertFalse(text.contains("AVFoundation") || text.contains("CoreMediaIO") || text.contains("AVCapture"), name)
        }
    }

    // MARK: Diagnostic tuning (DHP_NATIVE_MIRROR_TUNING)

    func testTuningParsesTypedValuesAndSkipsMalformedEntries() {
        let entries = AQNativeMirrorParseTuning(" config.jitterBufferMode=3 ; options.flag=true;receiver.rate=0.5;;noequals;.k=1;t.=2;options.name=abc; stream.off=No ")
        XCTAssertEqual(entries.count, 5)
        XCTAssertEqual(entries[0]["target"] as? String, "config")
        XCTAssertEqual(entries[0]["key"] as? String, "jitterBufferMode")
        XCTAssertEqual(entries[0]["value"] as? Int, 3)
        XCTAssertEqual(entries[1]["value"] as? Bool, true)
        XCTAssertEqual(entries[2]["value"] as? Double, 0.5)
        XCTAssertEqual(entries[3]["value"] as? String, "abc")
        XCTAssertEqual(entries[4]["value"] as? Bool, false)
        XCTAssertTrue(AQNativeMirrorParseTuning(nil).isEmpty)
        XCTAssertTrue(AQNativeMirrorParseTuning("").isEmpty)
    }

    func testTuningAppliesOnlyToItsTargetAndNeverThrowsOnUnknownKeys() {
        let entries = AQNativeMirrorParseTuning("options.a=1;options.b=x;config.c=2;config.nonsense=1")
        let options = NSMutableDictionary()
        let applied = AQNativeMirrorApplyTuning(entries, "options", options)
        XCTAssertEqual(applied, IndexSet([0, 1]))
        XCTAssertEqual(options["a"] as? Int, 1)
        XCTAssertEqual(options["b"] as? String, "x")
        XCTAssertNil(options["c"])
        // A plain object without the setters takes nothing and raises nothing.
        XCTAssertTrue(AQNativeMirrorApplyTuning(entries, "config", NSObject()).isEmpty)
        XCTAssertTrue(AQNativeMirrorApplyTuning(entries, "receiver", nil).isEmpty)
    }
}
