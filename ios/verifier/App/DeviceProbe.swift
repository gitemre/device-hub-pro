import SwiftUI
import UIKit

/// A view behind the verifier's list that reads what only a view in the
/// hierarchy can: the hinge (a UIHingeInteraction on it), the size of its
/// window scene with the interface orientation, and the keys that
/// reach the app (it is the first responder; the verifier has no text field).
struct DeviceProbe: UIViewRepresentable {
    let model: VerifierModel

    func makeUIView(context: Context) -> ProbeView {
        ProbeView(model: model)
    }

    func updateUIView(_ view: ProbeView, context: Context) {}
}

final class ProbeView: UIView {
    private weak var model: VerifierModel?

    init(model: VerifierModel) {
        self.model = model
        super.init(frame: .zero)
        observeHinge()
    }

    required init?(coder: NSCoder) { nil }

    override var canBecomeFirstResponder: Bool { true }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        becomeFirstResponder()
        reportScreen()
    }

    /// Folding moves the window to the other panel and turning relays it
    /// out: either way the probe, which fills the window, lays out again.
    override func layoutSubviews() {
        super.layoutSubviews()
        reportScreen()
    }

    /// The window scene's size in pixels, as the interface is turned. Not
    /// the scene's `screen`: on iPhone Duo (iOS 27.1) that answered 1125 × 2001
    /// for an app filling the 1398 × 2034 outer panel.
    private func reportScreen() {
        guard let scene = window?.windowScene else { return }
        let points = scene.effectiveGeometry.coordinateSpace.bounds.size
        let scale = traitCollection.displayScale
        model?.screenChanged(
            width: Int((points.width * scale).rounded()), height: Int((points.height * scale).rounded()),
            scale: scale,
            interfaceOrientation: scene.effectiveGeometry.interfaceOrientation.rawValue
        )
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            guard let key = press.key, !key.charactersIgnoringModifiers.isEmpty else { continue }
            let flags = key.modifierFlags
            let modifiers = [(UIKeyModifierFlags.control, "control"), (.alternate, "option"), (.shift, "shift"), (.command, "command")]
                .filter { flags.contains($0.0) }
                .map(\.1)
            model?.keyPressed(Self.name(of: key), modifiers: modifiers)
        }
        super.pressesBegan(presses, with: event)
    }

    /// A key's name: its character, or the name of a key that types none.
    private static func name(of key: UIKey) -> String {
        switch key.keyCode {
        case .keyboardReturnOrEnter: return "return"
        case .keyboardTab: return "tab"
        case .keyboardSpacebar: return "space"
        case .keyboardEscape: return "escape"
        case .keyboardDeleteOrBackspace: return "delete"
        case .keyboardUpArrow: return "up"
        case .keyboardDownArrow: return "down"
        case .keyboardLeftArrow: return "left"
        case .keyboardRightArrow: return "right"
        default: return key.charactersIgnoringModifiers
        }
    }

    private func observeHinge() {
        // UIHingeInteraction is in the iOS 27.1 SDK (UIKit 9127.0.85); a
        // build with an earlier SDK says the row cannot be read.
        #if canImport(UIKit, _version: 9127.0.85)
        if #available(iOS 27.1, *) {
            addInteraction(UIHingeInteraction { [weak self] _, update in
                guard let hinge = update.hinge else {
                    self?.model?.hingeChanged(status: nil, degrees: nil)
                    return
                }
                self?.model?.hingeChanged(status: Self.name(of: hinge.status), degrees: Double(hinge.angle) * 180 / .pi)
            })
        } else {
            // No foldable runs an earlier iOS.
            model?.hingeChanged(status: nil, degrees: nil)
        }
        #else
        model?.hingeUnreadable()
        #endif
    }

    #if canImport(UIKit, _version: 9127.0.85)
    @available(iOS 27.1, *)
    private static func name(of status: UIHinge.Status) -> String {
        switch status {
        case .closed: return "closed"
        case .partiallyOpen: return "partiallyOpen"
        case .fullyOpen: return "fullyOpen"
        case .unknown: return "unknown"
        @unknown default: return "unknown"
        }
    }
    #endif
}
