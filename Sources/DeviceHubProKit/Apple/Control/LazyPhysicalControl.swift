import CoreGraphics
import Foundation

/// The control the input router holds while fast input is on: the XCTest runner
/// (`PhysicalControlSession`) is not started with Control, only when an action
/// that needs it reaches this proxy (Siri, typing or a touch fast input
/// cannot take, a fallback after a fast input failure). `resolve` starts the
/// runner if it is not running and returns it; it throws when it cannot.
/// Its lifecycle (`start`, `stop`, `terminateNow`) belongs to whoever owns the
/// real session, so here those do nothing.
public final class LazyPhysicalControl: PhysicalControlling {
    private let resolve: @Sendable () async throws -> any PhysicalControlling

    public init(resolve: @escaping @Sendable () async throws -> any PhysicalControlling) {
        self.resolve = resolve
    }

    public func start() async throws {}
    public func stop() async {}
    public func terminateNow() {}

    public func snapshot() async -> PhysicalControlSnapshot { PhysicalControlSnapshot(state: .ready) }
    public func portraitSize() async -> CGSize? { try? await resolve().portraitSize() }

    public func tap(_ point: CGPoint) async throws { try await resolve().tap(point) }
    public func swipe(from: CGPoint, to: CGPoint, duration: TimeInterval) async throws {
        try await resolve().swipe(from: from, to: to, duration: duration)
    }
    public func type(_ text: String, bundleID: String) async throws { try await resolve().type(text, bundleID: bundleID) }
    public func press(_ button: PhysicalControlButton) async throws { try await resolve().press(button) }
    public func setOrientation(_ orientation: PhysicalControlOrientation) async throws -> PhysicalControlOrientation {
        try await resolve().setOrientation(orientation)
    }
    public func orientation() async throws -> PhysicalControlOrientation { try await resolve().orientation() }
    public func activateSiri(text: String?) async throws { try await resolve().activateSiri(text: text) }
    public func showAppSwitcher() async throws { try await resolve().showAppSwitcher() }
    public func foreground(ids: [String]) async throws -> [String] { try await resolve().foreground(ids: ids) }
    public func foregroundApp() async throws -> String? { try await resolve().foregroundApp() }
}
