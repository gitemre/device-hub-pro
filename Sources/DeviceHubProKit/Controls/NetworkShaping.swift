import Foundation

// MARK: - Speed

/// The emulator's classic network speed profiles (external/qemu
/// `android/emu/cmdline/include/android/network/constants.h`,
/// `ANDROID_NETWORK_LIST_MODES`: SOURCE-DERIVED, emu-master-dev). The
/// header lists upload then download in kbit/s (it says kB/s, but the
/// emulator's own `network status` prints 14.4 as 14400 bit/s), taken from
/// Wikipedia's list of device bandwidths. The emulator console's `network
/// speed` stores these numbers and throttles nothing (measured on API 35,
/// emulator 36.6.11); Device Hub Pro applies them with `tc netem rate` inside the
/// guest (`NetworkShaper`).
public enum NetworkSpeed: String, CaseIterable, Identifiable, Sendable {
    case full
    case gsm
    case hscsd
    case gprs
    case umts
    case edge
    case hsdpa
    case lte
    case evdo

    public var id: String { rawValue }

    /// Upload (device to network) rate in kbit/s; nil = not limited.
    public var uploadKbit: Double? {
        switch self {
        case .full: return nil
        case .gsm: return 14.4
        case .hscsd: return 14.4
        case .gprs: return 28.8
        case .umts: return 384.0
        case .edge: return 473.6
        case .hsdpa: return 5760.0
        case .lte: return 58000.0
        case .evdo: return 75000.0
        }
    }

    /// Download (network to device) rate in kbit/s; nil = not limited.
    public var downloadKbit: Double? {
        switch self {
        case .full: return nil
        case .gsm: return 14.4
        case .hscsd: return 57.6
        case .gprs: return 57.6
        case .umts: return 384.0
        case .edge: return 473.6
        case .hsdpa: return 13980.0
        case .lte: return 173000.0
        case .evdo: return 280000.0
        }
    }

    public var uploadBitsPerSecond: Int? { uploadKbit.map { Int(($0 * 1000).rounded()) } }
    public var downloadBitsPerSecond: Int? { downloadKbit.map { Int(($0 * 1000).rounded()) } }

    public var name: String {
        switch self {
        case .full: return "Full"
        case .gsm: return "GSM"
        case .hscsd: return "HSCSD"
        case .gprs: return "GPRS"
        case .umts: return "UMTS"
        case .edge: return "EDGE"
        case .hsdpa: return "HSDPA"
        case .lte: return "LTE"
        case .evdo: return "EVDO"
        }
    }

    /// `GPRS · 57.6 kbit/s down, 28.8 up`.
    public var label: String {
        guard let down = downloadKbit, let up = uploadKbit else { return "Full" }
        if down == up { return "\(name) · \(Self.rate(down))" }
        return "\(name) · \(Self.rate(down)) down, \(Self.rate(up)) up"
    }

    static func rate(_ kbit: Double) -> String {
        func number(_ value: Double) -> String {
            value == value.rounded() ? String(Int(value)) : String(format: "%g", value)
        }
        return kbit >= 1000 ? "\(number(kbit / 1000)) Mbit/s" : "\(number(kbit)) kbit/s"
    }

    /// The profile whose rates equal these (within 1 %, tc prints rounded
    /// numbers); `.full` for no limits; nil for rates no profile has.
    public static func matching(download: Int?, upload: Int?) -> NetworkSpeed? {
        func close(_ a: Int?, _ b: Int?) -> Bool {
            switch (a, b) {
            case (nil, nil): return true
            case let (a?, b?): return abs(Double(a - b)) <= Double(b) * 0.01 + 1
            default: return false
            }
        }
        return allCases.first {
            close(download, $0.downloadBitsPerSecond) && close(upload, $0.uploadBitsPerSecond)
        }
    }
}

// MARK: - Profile

/// What the Speed and Connection latency rows ask the device for.
public struct ShapingProfile: Sendable, Equatable {
    public var speed: NetworkSpeed
    /// The added round-trip time, `min...max` ms (each direction carries
    /// half). `.off` adds none.
    public var latency: ConnectionLatency
    /// Random packet loss in percent (0 = none). No row sets it yet.
    public var lossPercent: Double

    public init(speed: NetworkSpeed = .full, latency: ConnectionLatency = .off, lossPercent: Double = 0) {
        self.speed = speed
        self.latency = latency
        self.lossPercent = lossPercent
    }

    public static let neutral = ShapingProfile()

    public var isNeutral: Bool {
        speed == .full && !latency.isActive && lossPercent <= 0
    }

    public enum Direction: Sendable {
        /// Device to network (the guest's route interface).
        case upload
        /// Network to device (mirrored to `ifb0`).
        case download
    }

    /// The arguments after `netem` for one direction; nil when that
    /// direction needs no qdisc.
    ///
    /// The delay is half the round trip, with the jitter around it
    /// (netem's default distribution is uniform, so a 35-200 ms round trip
    /// is `58750us` with `41250us` of jitter per direction). The queue
    /// limit must hold what is in flight: the delay line counts against
    /// it, and at a high rate the default 1000 packets drop traffic.
    public func netemArguments(_ direction: Direction) -> [String]? {
        let bits = direction == .upload ? speed.uploadBitsPerSecond : speed.downloadBitsPerSecond
        let delayed = latency.isActive
        guard bits != nil || delayed || lossPercent > 0 else { return nil }

        var tail: [String] = []
        var maxDelayMs = 0.0
        if delayed {
            let delay = (latency.minimumMs + latency.maximumMs) * 250
            let jitter = (latency.maximumMs - latency.minimumMs) * 250
            maxDelayMs = Double(latency.maximumMs) / 2
            tail += ["delay", "\(delay)us"]
            if jitter > 0 { tail.append("\(jitter)us") }
        }
        if lossPercent > 0 {
            tail += ["loss", String(format: "%g%%", (lossPercent * 100).rounded() / 100)]
        }
        if let bits { tail += ["rate", "\(bits)bit"] }

        let limit: Int
        if let bits {
            let bytesPerSecond = Double(bits) / 8
            let packets = Int((bytesPerSecond * (maxDelayMs / 1000 + 1.0) / 1500).rounded(.up))
            limit = min(20_000, max(5, packets))
        } else {
            limit = 10_000
        }
        return ["netem", "limit", "\(limit)"] + tail
    }
}

// MARK: - Reading

/// One `netem` root qdisc of `tc qdisc show`.
public struct NetemQdisc: Sendable, Equatable {
    public let device: String
    public let delayMs: Double
    public let jitterMs: Double
    public let lossPercent: Double
    public let rateBitsPerSecond: Int?

    public init(device: String, delayMs: Double = 0, jitterMs: Double = 0, lossPercent: Double = 0, rateBitsPerSecond: Int? = nil) {
        self.device = device
        self.delayMs = delayMs
        self.jitterMs = jitterMs
        self.lossPercent = lossPercent
        self.rateBitsPerSecond = rateBitsPerSecond
    }

    /// `qdisc netem 8005: dev wlan0 root refcnt 2 limit 108 delay 58.7ms  41.2ms rate 1Mbit`
    /// (also `loss 2.5%`, `rate 14400bit`, `delay 150.0ms`). Other qdiscs and
    /// netem on a class (not `root`) answer nil.
    static func parse(line: String) -> NetemQdisc? {
        let words = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count > 4, words[0] == "qdisc", words[1] == "netem",
              let dev = words.firstIndex(of: "dev"), dev + 1 < words.count,
              words.contains("root")
        else { return nil }
        var delay = 0.0
        var jitter = 0.0
        var loss = 0.0
        var rate: Int?
        var index = words.firstIndex(of: "root")! + 1
        while index < words.count {
            switch words[index] {
            case "delay":
                if index + 1 < words.count, let value = milliseconds(words[index + 1]) {
                    delay = value
                    index += 1
                    if index + 1 < words.count, let second = milliseconds(words[index + 1]) {
                        jitter = second
                        index += 1
                    }
                }
            case "loss":
                if index + 1 < words.count {
                    loss = Double(words[index + 1].trimmingCharacters(in: CharacterSet(charactersIn: "%"))) ?? 0
                    index += 1
                }
            case "rate":
                if index + 1 < words.count {
                    rate = bitsPerSecond(words[index + 1])
                    index += 1
                }
            default: break
            }
            index += 1
        }
        return NetemQdisc(device: words[dev + 1], delayMs: delay, jitterMs: jitter, lossPercent: loss, rateBitsPerSecond: rate)
    }

    /// `58.7ms`, `150us`, `1.5s` → milliseconds.
    static func milliseconds(_ text: String) -> Double? {
        let units: [(String, Double)] = [("ms", 1), ("us", 0.001), ("s", 1000)]
        for (suffix, factor) in units where text.hasSuffix(suffix) {
            return Double(text.dropLast(suffix.count)).map { $0 * factor }
        }
        return nil
    }

    /// `14400bit`, `1Mbit`, `173Mbit`, `57.6Kbit` → bits per second.
    static func bitsPerSecond(_ text: String) -> Int? {
        let lower = text.lowercased()
        let units: [(String, Double)] = [("gbit", 1e9), ("mbit", 1e6), ("kbit", 1e3), ("bit", 1)]
        for (suffix, factor) in units where lower.hasSuffix(suffix) {
            return Double(lower.dropLast(suffix.count)).map { Int(($0 * factor).rounded()) }
        }
        return nil
    }
}

/// What the device says about its shaping: the build (`ro.debuggable`),
/// whether adbd is root, the interface the default route leaves by, and the
/// netem qdiscs now in place.
public struct ShapingReading: Sendable, Equatable {
    /// `ro.debuggable`: whether `adb root` can work (userdebug and eng
    /// builds; Play Store images are `user` builds). nil when unreadable.
    public var debuggable: Bool?
    public var isRoot: Bool
    /// The interface of `ip route get 1.1.1.1`; nil without a route.
    public var routeInterface: String?
    public var netem: [NetemQdisc]

    public init(debuggable: Bool? = nil, isRoot: Bool = false, routeInterface: String? = nil, netem: [NetemQdisc] = []) {
        self.debuggable = debuggable
        self.isRoot = isRoot
        self.routeInterface = routeInterface
        self.netem = netem
    }

    /// The device that carries the upload shaping.
    public var shapedInterface: String? {
        netem.first { $0.device != NetworkShaper.ifbDevice }?.device
    }

    private var upload: NetemQdisc? { netem.first { $0.device != NetworkShaper.ifbDevice } }
    private var download: NetemQdisc? { netem.first { $0.device == NetworkShaper.ifbDevice } }

    public var isShaping: Bool { !netem.isEmpty }

    /// The speed in place; `.full` without limits, nil for rates no
    /// profile has.
    public var speed: NetworkSpeed? {
        NetworkSpeed.matching(download: download?.rateBitsPerSecond, upload: upload?.rateBitsPerSecond)
    }

    /// The round-trip latency in place (both directions' delay added; tc
    /// prints tenths of a millisecond, so the ends are rounded).
    public var latency: ConnectionLatency {
        let delay = (upload?.delayMs ?? 0) + (download?.delayMs ?? 0)
        let jitter = (upload?.jitterMs ?? 0) + (download?.jitterMs ?? 0)
        guard delay > 0 else { return .off }
        return ConnectionLatency(
            minimumMs: Int((delay - jitter).rounded()),
            maximumMs: Int((delay + jitter).rounded())
        )
    }

    public var lossPercent: Double { max(upload?.lossPercent ?? 0, download?.lossPercent ?? 0) }

    /// Whether upload and download shaping both sit where the traffic goes
    /// now: the netem is on the route's interface, with its mirror on
    /// `ifb0`. False after the data path moved to another interface.
    public func isPlaced(for profile: ShapingProfile) -> Bool {
        guard let routeInterface else { return false }
        let wantsUpload = profile.netemArguments(.upload) != nil
        let wantsDownload = profile.netemArguments(.download) != nil
        if wantsUpload, upload?.device != routeInterface { return false }
        if !wantsUpload, upload != nil { return false }
        if wantsDownload, download == nil { return false }
        if !wantsDownload, download != nil { return false }
        return true
    }

    /// Whether the device shows `profile`: placed on the route's interface,
    /// with its speed and latency (tc prints rounded numbers, so the
    /// latency ends may differ by 1 ms).
    public func matches(_ profile: ShapingProfile) -> Bool {
        guard isPlaced(for: profile), speed == profile.speed else { return false }
        if profile.latency.isActive {
            return abs(latency.minimumMs - profile.latency.minimumMs) <= 1
                && abs(latency.maximumMs - profile.latency.maximumMs) <= 1
        }
        return !latency.isActive && lossPercent == profile.lossPercent
    }

    public static func parse(_ output: String) -> ShapingReading {
        let sections = ConditionsText.sections(
            from: output,
            markers: ProbeSection.allCases.map { ($0, $0.marker) }
        )
        var reading = ShapingReading()
        reading.debuggable = sections[.debuggable].flatMap { $0 == "1" ? true : ($0 == "0" ? false : nil) }
        reading.isRoot = sections[.uid] == "0"
        if let route = sections[.route] {
            let words = route.split(whereSeparator: \.isWhitespace).map(String.init)
            if let dev = words.firstIndex(of: "dev"), dev + 1 < words.count {
                reading.routeInterface = words[dev + 1]
            }
        }
        reading.netem = (sections[.qdisc] ?? "")
            .components(separatedBy: .newlines)
            .compactMap(NetemQdisc.parse(line:))
        return reading
    }

    enum ProbeSection: String, CaseIterable {
        case debuggable
        case uid
        case route
        case qdisc

        var marker: String { "@@devicehubpro:shape:\(rawValue)" }
    }

    /// The probe, one shell line (the markers start with `@@devicehubpro:shape:`
    /// so a stub adb can tell it from the other probes). `tc qdisc show`
    /// and `ip route get` need no root.
    public static var probeScript: String {
        [
            "echo \(ProbeSection.debuggable.marker)", "getprop ro.debuggable",
            "echo \(ProbeSection.uid.marker)", "id -u",
            "echo \(ProbeSection.route.marker)", "ip route get 1.1.1.1 2>&1",
            "echo \(ProbeSection.qdisc.marker)", "tc qdisc show 2>&1",
            "true",
        ].joined(separator: "; ")
    }
}

// MARK: - Errors

public enum ShapingError: Error, Equatable, CustomStringConvertible {
    /// `adb root` refused (a user build).
    case notRootable(String)
    /// adbd did not come back as root within the wait.
    case rootNotReached
    /// No default route: nothing to shape (airplane mode, no network).
    case noRoute
    /// A tc or ip command failed.
    case commandFailed(String)

    public var description: String {
        switch self {
        case .notRootable(let detail): return "adb root was refused: \(detail)"
        case .rootNotReached: return "The device's adb did not come back as root."
        case .noRoute: return "The device has no network route to shape."
        case .commandFailed(let detail): return "tc failed: \(detail)"
        }
    }
}

public enum RootOutcome: Sendable, Equatable {
    /// adbd was root already: Device Hub Pro must not unroot it.
    case alreadyRoot
    /// Device Hub Pro restarted adbd as root: it unroots when conditions reset.
    case restartedAsRoot
}

// MARK: - Shaper

/// Speed and latency shaping inside the guest with `tc netem`, in both
/// directions: the route interface's egress qdisc shapes uploads, and an
/// ingress filter mirrors the interface's traffic to `ifb0`, whose qdisc
/// shapes downloads. It needs root (`adb root` on userdebug and eng
/// images; a Play Store image refuses it, and the rows are then hidden).
/// The emulator console's `network delay` / `network speed` do not do this:
/// speed throttles nothing and delay holds only new connection setups.
///
/// The type holds no state: callers remember whether Device Hub Pro rooted the
/// device (`RootOutcome`) and what they asked for.
public struct NetworkShaper: Sendable {
    public static let ifbDevice = "ifb0"
    /// The ingress filter's priority: Device Hub Pro deletes only its own, never
    /// the system's filters on the interface's clsact.
    public static let filterPriority = 49000

    private let adb: AdbClient
    private let sleep: @Sendable (Duration) async throws -> Void
    private let rootWait: Int

    /// - Parameter rootWait: how many half-second polls wait for adbd to
    ///   come back after `adb root` / `adb unroot`.
    public init(
        adb: AdbClient,
        rootWait: Int = 40,
        sleep: (@Sendable (Duration) async throws -> Void)? = nil
    ) {
        self.adb = adb
        self.rootWait = rootWait
        self.sleep = sleep ?? { try await Task.sleep(for: $0) }
    }

    /// Only emulators: a phone needs root for tc, which Device Hub Pro never asks.
    public static func isSupportedSerial(_ serial: String) -> Bool {
        serial.hasPrefix("emulator-")
    }

    public func read(serial: String) async throws -> ShapingReading {
        ShapingReading.parse(try await adb.shell(serial: serial, [ShapingReading.probeScript]))
    }

    // MARK: Root

    /// Makes adbd root. Runs `adb root` only when it is not root yet, then
    /// waits for the restarted adbd. Throws `.notRootable` when adb refuses.
    public func ensureRoot(
        serial: String,
        willRestart: (@Sendable () async -> Void)? = nil
    ) async throws -> RootOutcome {
        if try await isRoot(serial: serial) { return .alreadyRoot }
        let reverses = await reverseRules(serial: serial)
        do {
            try await adb.run(["-s", serial, "root"], timeout: .seconds(20))
        } catch {
            throw ShapingError.notRootable("\(error)")
        }
        await willRestart?()
        var reached = false
        var waitError: (any Error)?
        do { reached = try await waitForAdbd(serial: serial, root: true) } catch { waitError = error }
        await restoreReverseRules(reverses, serial: serial)
        if let waitError { throw waitError }
        guard reached else { throw ShapingError.rootNotReached }
        return .restartedAsRoot
    }

    /// `adb unroot`, waiting for adbd. Call it after `clear`: the tc rules
    /// outlive the restart.
    public func dropRoot(serial: String) async throws {
        guard try await isRoot(serial: serial) else { return }
        let reverses = await reverseRules(serial: serial)
        try await adb.run(["-s", serial, "unroot"], timeout: .seconds(20))
        var waitError: (any Error)?
        do { _ = try await waitForAdbd(serial: serial, root: false) } catch { waitError = error }
        await restoreReverseRules(reverses, serial: serial)
        if let waitError { throw waitError }
    }

    /// The `adb reverse` rules of `serial` as `(remote, local)` pairs, read
    /// before an adbd restart: the rules live in adbd and the restart drops
    /// them (a dev server's `adb reverse tcp:8081 tcp:8081` stops working).
    /// A line is `<serial> <remote> <local>`; an unreadable list is none.
    func reverseRules(serial: String) async -> [(remote: String, local: String)] {
        guard let output = try? await adb.run(["-s", serial, "reverse", "--list"], timeout: .seconds(10)) else {
            return []
        }
        return Self.parseReverseList(output)
    }

    static func parseReverseList(_ output: String) -> [(remote: String, local: String)] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 3, let remote = fields.dropLast().last, let local = fields.last,
                  remote.contains(":"), local.contains(":")
            else { return nil }
            return (remote, local)
        }
    }

    /// Adds back the rules the restart dropped; best effort, per rule.
    func restoreReverseRules(_ rules: [(remote: String, local: String)], serial: String) async {
        for rule in rules {
            _ = try? await adb.run(["-s", serial, "reverse", rule.remote, rule.local], timeout: .seconds(10))
        }
    }

    private func isRoot(serial: String) async throws -> Bool {
        try await adb.shell(serial: serial, ["id", "-u"]).trimmingCharacters(in: .whitespacesAndNewlines) == "0"
    }

    private func waitForAdbd(serial: String, root: Bool) async throws -> Bool {
        // The restart drops the transport for a moment; every error is the
        // restart until the wait runs out.
        _ = try? await adb.run(["-s", serial, "wait-for-device"], timeout: .seconds(20))
        for _ in 0..<rootWait {
            if let now = try? await isRoot(serial: serial), now == root { return true }
            try await sleep(.milliseconds(500))
        }
        return false
    }

    // MARK: Apply and clear

    /// Puts `profile` in place and returns what the device reports. adbd
    /// must be root. A neutral profile clears. Idempotent: it replaces the
    /// qdiscs and the filter, and removes shaping left on an interface the
    /// route no longer uses.
    @discardableResult
    public func apply(_ profile: ShapingProfile, serial: String) async throws -> ShapingReading {
        if profile.isNeutral {
            try await clear(serial: serial)
            return try await read(serial: serial)
        }
        let before = try await read(serial: serial)
        guard let route = before.routeInterface else { throw ShapingError.noRoute }

        // Shaping on an interface the route left.
        for stale in before.netem where stale.device != route && stale.device != Self.ifbDevice {
            try await tolerate(serial: serial, ["tc", "qdisc", "del", "dev", stale.device, "root"])
            try await tolerate(serial: serial, filterDelete(stale.device))
        }

        if let egress = profile.netemArguments(.upload) {
            try await tc(serial: serial, ["tc", "qdisc", "replace", "dev", route, "root"] + egress)
        } else {
            try await tolerate(serial: serial, ["tc", "qdisc", "del", "dev", route, "root"])
        }

        if let ingress = profile.netemArguments(.download) {
            try await tc(serial: serial, ["ip", "link", "set", Self.ifbDevice, "up"])
            try await tolerate(serial: serial, filterDelete(route))
            try await tc(serial: serial, [
                "tc", "filter", "add", "dev", route, "ingress", "protocol", "all",
                "pref", "\(Self.filterPriority)", "u32", "match", "u32", "0", "0",
                "action", "mirred", "egress", "redirect", "dev", Self.ifbDevice,
            ])
            try await tc(serial: serial, ["tc", "qdisc", "replace", "dev", Self.ifbDevice, "root"] + ingress)
        } else {
            try await removeIngress(serial: serial, route: route)
        }
        return try await read(serial: serial)
    }

    /// Removes every Device Hub Pro qdisc and filter. Idempotent, and a no-op
    /// when nothing is shaped. adbd must be root.
    public func clear(serial: String, reading known: ShapingReading? = nil) async throws {
        let before = if let known { known } else { try await read(serial: serial) }
        var interfaces = Set(before.netem.map(\.device).filter { $0 != Self.ifbDevice })
        if let route = before.routeInterface { interfaces.insert(route) }
        for device in interfaces.sorted() {
            if before.netem.contains(where: { $0.device == device }) {
                try await tolerate(serial: serial, ["tc", "qdisc", "del", "dev", device, "root"])
            }
            try await tolerate(serial: serial, filterDelete(device))
        }
        if before.netem.contains(where: { $0.device == Self.ifbDevice }) {
            try await tolerate(serial: serial, ["tc", "qdisc", "del", "dev", Self.ifbDevice, "root"])
        }
        try await tolerate(serial: serial, ["ip", "link", "set", Self.ifbDevice, "down"])
    }

    private func removeIngress(serial: String, route: String) async throws {
        try await tolerate(serial: serial, filterDelete(route))
        try await tolerate(serial: serial, ["tc", "qdisc", "del", "dev", Self.ifbDevice, "root"])
        try await tolerate(serial: serial, ["ip", "link", "set", Self.ifbDevice, "down"])
    }

    private func filterDelete(_ device: String) -> [String] {
        ["tc", "filter", "del", "dev", device, "ingress", "pref", "\(Self.filterPriority)"]
    }

    /// A command that must work.
    private func tc(serial: String, _ command: [String]) async throws {
        do {
            _ = try await adb.shell(serial: serial, command)
        } catch {
            throw ShapingError.commandFailed("\(command.joined(separator: " ")): \(error)")
        }
    }

    /// A command whose failure means "already gone".
    private func tolerate(serial: String, _ command: [String]) async throws {
        do {
            _ = try await adb.shell(serial: serial, command)
        } catch AdbError.commandFailed {
            // Nothing to delete or already down.
        }
    }
}
