import Foundation
import Synchronization

/// The seam between a physical view session and Control: the
/// session forwards the stage's touches, keys and Apple-chrome buttons here,
/// and they reach the phone only while a `PhysicalControlInputRouter` is set.
/// With none (Control off, the default) every input is dropped: the view is
/// view only.
public final class PhysicalInputRoute: Sendable {
    private let router = Mutex<PhysicalControlInputRouter?>(nil)

    public init() {}

    /// Sets (or clears) the router; a router that is replaced or cleared is
    /// stopped, so the text and the gesture it held are dropped.
    public func set(_ newRouter: PhysicalControlInputRouter?) {
        let old = router.withLock { current -> PhysicalControlInputRouter? in
            let old = current
            current = newRouter
            return old
        }
        if old !== newRouter { old?.stop() }
    }

    /// Whether Control receives input now.
    public var isActive: Bool { router.withLock { $0 != nil } }

    private let chrome = Mutex<PhysicalChromeButtons?>(nil)

    /// Sets (or clears) the Apple chrome's buttons while Control is off; one that is
    /// replaced or cleared is stopped (it releases what it holds).
    public func setChromeButtons(_ buttons: PhysicalChromeButtons?) {
        let old = chrome.withLock { current -> PhysicalChromeButtons? in
            let old = current
            current = buttons
            return old
        }
        if old !== buttons { old?.stop() }
    }

    /// Whether the chrome's buttons reach the phone: through Control, or on their own.
    public var acceptsButtons: Bool { isActive || chrome.withLock { $0 != nil } }

    func receive(contacts: [TouchCommand]) {
        router.withLock { $0 }?.receive(contacts: contacts)
    }

    func receive(_ command: KeyboardCommand) {
        router.withLock { $0 }?.receive(command)
    }

    /// Whether the stage should send physical keys (fast input is carrying input).
    var acceptsPhysicalKeys: Bool { router.withLock { $0 }?.isFastActive ?? false }

    func receive(physical event: PhysicalKeyEvent) {
        router.withLock { $0 }?.receive(physical: event)
    }

    func receive(button: SimulatorHardwareButton, isDown: Bool) {
        // Control's fast input first; else the buttons' own fast session; else Control's runner.
        let active = router.withLock { $0 }
        if let active, active.isFastActive {
            active.receive(button: button, isDown: isDown)
        } else if let own = chrome.withLock({ $0 }) {
            own.receive(button: button, isDown: isDown)
        } else {
            active?.receive(button: button, isDown: isDown)
        }
    }
}
