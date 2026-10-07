import SwiftUI

/// Keyboard activation for the app's custom controls (the stage pill, the
/// Controls switches and pop-ups, the sidebar and Apps lists, the sidebar
/// toggle): one action per press, like a system button or switch.
///
/// `onKeyPress` delivers key-down *and* key-repeat by default, so holding
/// Space or Return re-ran the action at the key-repeat rate: the record
/// button started and stopped recordings, a switch flipped back and forth
/// with an adb write per flip. The key-down acts; the repeats of a held key
/// are consumed without acting, as a system control does, rather than sent
/// on up the responder chain.
enum KeyActivation {
    /// The phases the handler receives: repeats too, so it can consume them.
    static let phases: KeyPress.Phases = [.down, .repeat]

    /// A press in `phase`: the key-down runs `action` and returns its
    /// result; a repeat is consumed.
    static func handle(_ phase: KeyPress.Phases, action: () -> KeyPress.Result) -> KeyPress.Result {
        guard phase == .down else { return .handled }
        return action()
    }
}

extension View {
    /// Runs `action` once per press of one of `keys` (see `KeyActivation`).
    /// `action` returns `.ignored` to let the press travel on.
    func onKeyActivation(
        _ keys: Set<KeyEquivalent>,
        action: @escaping () -> KeyPress.Result
    ) -> some View {
        onKeyPress(keys: keys, phases: KeyActivation.phases) { press in
            KeyActivation.handle(press.phase, action: action)
        }
    }
}
