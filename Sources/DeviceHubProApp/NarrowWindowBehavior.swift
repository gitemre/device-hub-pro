import AppKit
import SwiftUI

/// Narrow windows, like Device Hub's (measured on DH 27.0, 2026-09-29): the
/// window shrinks as far as its content allows (Device Hub's stops at
/// 876 × 268 pt with the inspector open; ours at 881 × 271), the inspector
/// stays, and the toolbar folds into the » chevron as the width goes: first
/// the compact button and "...", then the zoom group, then Resize; the
/// keyboard toggle and the inspector pill last.
///
/// The stage used to keep the window at 1033 pt while a device was
/// mirrored, and the inspector hid itself below 1080 pt; a stage that may
/// shrink (`ContentView`'s `minWidth: 1` detail frame) made both go away.
enum NarrowWindowBehavior {
    /// The narrowest window with the inspector open and a device mirrored
    /// (the stage adds nothing to the sidebar's 272 pt, the inspector's
    /// 260 pt and the toolbar's needs).
    static let minimumWindowWidth: CGFloat = 881
}
