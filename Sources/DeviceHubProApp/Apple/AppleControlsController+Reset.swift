import Foundation
import DeviceHubProKit

extension AppleControlsController {
    /// What Reset to Defaults would change on the attached simulator
    /// (`appleResetSteps`).
    func resetSteps(osVersion: String?) -> [AppleResetStep] {
        appleResetSteps(
            route: route,
            state: state,
            colorFilterSupported: appleColorFilterSupported(osVersion: osVersion),
            statusBarActive: statusBarActive,
            location: location
        )
    }

    /// Puts the settings the Settings panel changes back to their defaults:
    /// appearance Light, text size Large, the accessibility switches and the
    /// colour filter off, Liquid Glass Clear (iOS 26) or 50 % (iOS 27), the status bar override
    /// off and no simulated location. One change at a time, each shown by its
    /// row; a change that fails says why in the status line and the rest go on.
    func resetToDefaults(osVersion: String?) async {
        let steps = resetSteps(osVersion: osVersion)
        for step in steps {
            switch step {
            case .appearance: await setAppearance(dark: false)
            case .textSize: await setTextSize(.large)
            case .largerAccessibilitySizes: await setLargerAccessibilitySizes(false)
            case .reduceMotion: await setReduceMotion(false)
            case .increaseContrast: await setIncreaseContrast(false)
            case .showBorders: await setShowBorders(false)
            case .reduceTransparency: await setReduceTransparency(false)
            case .voiceOver: await setVoiceOver(false)
            case .colorFilter: await setColorFilter(nil)
            case .liquidGlass: await setLookAndFeel(.clear)
            case .liquidGlassOpacity: await setLiquidGlassOpacity(appleLiquidGlassDefaultOpacity)
            case .statusBar: await setStatusBarActive(false)
            case .location: await setLocation(nil)
            }
        }
    }
}
