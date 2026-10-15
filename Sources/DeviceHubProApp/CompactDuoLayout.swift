import AppKit
import DeviceHubProKit

/// How the compact window is sized round a foldable simulator (iPhone Duo)
/// in its front-on 3D model: as Xcode 27.1's Device Hub sizes it, one frame
/// (`ParityMetrics.compactFoldableWindowSize`, 696 × 784 pt) that stays the
/// same as the device folds, unfolds or is turned, the model in it fitted as
/// the main stage fits it (`MirrorStageContent.frontModel`) with room round
/// it. The window of any other device keeps Device Hub's 258 × 587 pt
/// (`CompactMirrorWindow.frameSize`).
///
/// The model is not lifted by `ParityMetrics.foldModelLift` here: that
/// offset was measured against the main window's fit area, and the compact
/// stage is not centred in its window the same way (it reaches up under the
/// toolbar band and keeps a pill band below), with nothing measured to say
/// Device Hub lifts it.
enum CompactDuoLayout {
    /// The frame the compact window of a foldable opens at, within `limit`
    /// (the screen's visible frame) when given.
    static func windowSize(limit: CGSize? = nil) -> CGSize {
        var size = ParityMetrics.compactFoldableWindowSize
        if let limit {
            size.width = min(size.width, max(limit.width, CompactMirrorWindow.minimumSize.width))
            size.height = min(size.height, max(limit.height, CompactMirrorWindow.minimumSize.height))
        }
        return size
    }
}

extension DeviceWorkspace {
    /// The counter-clockwise quarter turns the foldable's model is held at
    /// from its resting pose (the simulator turned to landscape, say).
    var foldModelRoll: Int {
        ((simulatorCanvas.devicePose.targetTurns - simulatorFold.restingTurns) % 4 + 4) % 4
    }
}

/// Sizes the compact window: a foldable shown in its 3D model gets
/// `CompactDuoLayout`'s frame, any other device Device Hub's. It remembers
/// the one size the user drags a foldable's window to, and keeps it as the
/// device folds and turns: the window is not fought, and it does not change
/// size with the device.
@MainActor
final class CompactWindowSizer {
    /// Whether the window has the foldable's size now (false: Device Hub's).
    private var isFoldable = false
    /// The size the user dragged a foldable's window to, kept for as long as
    /// the window lives (not per posture or per turn).
    private var userSize: CGSize?
    private weak var observed: NSWindow?
    private var observer: NSObjectProtocol?

    /// The frame size the window is to have: for a foldable, the user's, else
    /// the default within `screen`; Device Hub's for any other device.
    func size(foldable: Bool, on screen: NSScreen?) -> CGSize {
        guard foldable else { return CompactMirrorWindow.frameSize }
        return userSize ?? CompactDuoLayout.windowSize(limit: screen?.visibleFrame.size)
    }

    /// Notes the kind of a window that was just placed at `size(foldable:on:)`.
    func noteInitial(foldable: Bool, window: NSWindow) {
        isFoldable = foldable
        watch(window)
    }

    /// Gives `window` the size for `foldable`, keeping its top edge and the
    /// middle of its width (the device stays where the eye is), within the
    /// screen. Device Hub's size comes back when the device shows no
    /// foldable model any more. Does nothing while the kind stays the same:
    /// the window never changes size as the device folds.
    func fit(_ window: NSWindow, foldable: Bool) {
        watch(window)
        guard foldable != isFoldable else { return }
        let size = size(foldable: foldable, on: window.screen)
        var frame = window.frame
        if abs(frame.width - size.width) > 0.5 || abs(frame.height - size.height) > 0.5 {
            frame = NSRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height, width: size.width, height: size.height)
            if let screen = window.screen { frame = window.constrainFrameRect(frame, to: screen) }
            window.setFrame(frame, display: true, animate: false)
        }
        isFoldable = foldable
    }

    /// Whether `fit` has anything to do for a window of this kind.
    func needsFit(foldable: Bool) -> Bool { foldable != isFoldable }

    /// A size the user dragged a foldable's window to is the size it keeps.
    private func watch(_ window: NSWindow) {
        guard observed !== window else { return }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observed = window
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main
        ) { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                guard let self, let window, self.isFoldable else { return }
                self.userSize = window.frame.size
            }
        }
    }
}
