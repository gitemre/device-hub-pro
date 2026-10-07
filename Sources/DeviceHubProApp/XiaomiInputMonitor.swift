import Foundation
import Observation
import SwiftUI
import DeviceHubProKit

/// Whether a Xiaomi phone's mirror is showing but its input is refused
/// (MIUI / HyperOS "USB debugging (Security settings)" off, see
/// ``XiaomiInputBlock``), for the stage's banner.
///
/// Input is blocked when the phone's properties say so (read once when a
/// scrcpy session begins) or the scrcpy server's console reported the
/// refusal. While blocked, a click re-reads the property, at most once per
/// ``recheckInterval``, and so does the banner's Check Again; the banner
/// clears the moment the property reads `1`. Clicks are never withheld: they
/// keep reaching the session, so they work as soon as the setting changes.
@MainActor
@Observable
final class XiaomiInputMonitor {
    /// The least time between two re-reads triggered by clicks.
    static let recheckInterval: TimeInterval = 3

    private(set) var isBlocked = false

    /// Reads ``XiaomiInputBlock/probeScript``'s output for a serial; nil when
    /// the read failed (the state then stays as it was).
    @ObservationIgnored var readProbe: @MainActor (_ serial: String) async -> String? = { _ in nil }
    /// Forgets the server console's remembered refusal, so a new one is
    /// told apart from it.
    @ObservationIgnored var clearServerSignal: @MainActor () -> Void = {}
    @ObservationIgnored var now: @MainActor () -> Date = { Date() }

    @ObservationIgnored private var serial: String?
    @ObservationIgnored private var lastCheck: Date?
    @ObservationIgnored private var isChecking = false
    @ObservationIgnored private var generation: UInt64 = 0

    /// A scrcpy session for `serial` began: reads the phone's properties.
    func begin(serial: String) {
        reset()
        self.serial = serial
        Task { await check() }
    }

    /// The server console reported (or not) the refusal of injected input.
    func observe(injectionDenied: Bool) {
        guard injectionDenied, serial != nil, !isBlocked else { return }
        isBlocked = true
    }

    /// A touch went down. While blocked, re-reads the property unless that
    /// was done less than ``recheckInterval`` ago.
    func noteClick() {
        guard isBlocked, !isChecking else { return }
        if let lastCheck, now().timeIntervalSince(lastCheck) < Self.recheckInterval { return }
        Task { await check() }
    }

    /// The banner's Check Again: always re-reads.
    func checkAgain() {
        guard serial != nil, !isChecking else { return }
        Task { await check() }
    }

    /// The session ended.
    func reset() {
        generation &+= 1
        serial = nil
        lastCheck = nil
        isChecking = false
        isBlocked = false
    }

    /// Reads the properties and applies the answer. Internal so tests can
    /// await it.
    func check() async {
        guard let serial, !isChecking else { return }
        isChecking = true
        lastCheck = now()
        let started = generation
        let output = await readProbe(serial)
        guard started == generation else { return }
        isChecking = false
        guard let output, let blocked = XiaomiInputBlock.isBlocked(probeOutput: output) else { return }
        if blocked {
            isBlocked = true
        } else {
            isBlocked = false
            clearServerSignal()
        }
    }
}

/// The stage line while input is blocked, in the style of the physical
/// iPhone's status line.
struct XiaomiInputBlockedBanner: View {
    let monitor: XiaomiInputMonitor

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(XiaomiInputBlock.bannerText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .lineLimit(3)
            Button("Check Again") { monitor.checkAgain() }
                .buttonStyle(.link)
                .font(.system(size: 11))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(maxWidth: 460)
        .liquidGlass()
        .glassHairline(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Phone input blocked")
    }
}
