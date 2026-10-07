import Foundation
import DeviceHubProKit

// What the Color Filter and Color inversion rows show, as pure functions of
// their readings so the wording is unit-tested without a device.

// MARK: - Color Filter

/// The Color Filter popup: the selection, or a non-selectable placeholder
/// while the device holds a state the five options do not name (the five
/// stay selectable, so the user can leave it from here: the Appearance
/// "Custom" rule).
struct ColorFilterPopupModel: Equatable {
    let selection: ColorFilterOption?
    let placeholder: String?
    /// Explains the placeholder; nil while an option is selected.
    let help: String?
}

func colorFilterPopupModel(for readings: ColorFilterReadings?) -> ColorFilterPopupModel {
    switch readings?.setting {
    case .filter(let option):
        return ColorFilterPopupModel(selection: option, placeholder: nil, help: nil)
    case .simulation(let option):
        // One word, like Appearance's "Custom": "Simulated Deuteranopia"
        // overflows the row at the inspector's default width. The status
        // sentence and the help name the simulation.
        return ColorFilterPopupModel(
            selection: nil,
            placeholder: "Simulated",
            help: "\(simulationSentence(option)) Choose a filter to change it; None turns it off."
        )
    case .unmapped(let mode):
        return ColorFilterPopupModel(
            selection: nil,
            placeholder: "Mode \(mode)",
            help: "The device's color correction mode is \(mode), which Android's Settings doesn't offer. Choose a filter to change it."
        )
    case nil:
        return ColorFilterPopupModel(selection: nil, placeholder: "Unknown", help: nil)
    }
}

/// The caption under Color Filter: what the filter is and where it shows, then
/// at most one sentence about the device's state; on Android 11 and older a
/// Grayscale selection first says where Settings keeps it. The state sentence
/// goes under the row whose setting it is about: here while a filter is set
/// (alone or with inversion), under Color inversion while only inversion is.
func colorFilterCaption(
    readings: ColorFilterReadings?,
    check: ColorTransformCheck?,
    isEmulator: Bool,
    apiLevel: Int?
) -> String {
    let base = isEmulator
        ? "Android's Color correction. The emulator draws it wrongly and screenshots leave it out: check the look on a phone."
        : "Android's Color correction. Only the phone's own screen is sure to show it: screenshots leave it out, and recordings and the mirror may too."
    var sentences = [base]
    switch readings?.setting {
    case .simulation(let option):
        return "\(base) \(simulationSentence(option))"
    case .unmapped(let mode):
        return "\(base) Mode \(mode) isn't one of Android's Settings options."
    case .filter(.grayscale):
        // Settings' Color correction lists Grayscale from Android 12
        // (accessibility_daltonizer_settings.xml, android-12.0.0_r34; not in
        // android-11.0.0_r48). Before, mode 0 is Developer options' entry.
        if let apiLevel, apiLevel < 31 {
            sentences.append("Before Android 12, Settings shows Grayscale as Developer options ▸ Simulate color space ▸ Monochromacy.")
        }
    default:
        break
    }
    if let subject = ColorTransformSubject(readings), subject != .inversion {
        if let status = colorTransformStatus(subject, check: check, apiLevel: apiLevel) {
            sentences.append(status)
        }
    }
    if case .applied(let level?) = check, abs(level - 0.7) > 0.05 {
        sentences.append("Intensity \(Int((level * 10).rounded())) of 10, set on the device.")
    }
    return sentences.joined(separator: " ")
}

/// What Developer options ▸ Simulate color space is doing.
private func simulationSentence(_ option: ColorFilterOption) -> String {
    "Developer options ▸ Simulate color space is simulating \(option.shortTitle)."
}

/// Which of the two settings ask for a color transform: the subject of the
/// state sentence. nil while neither does.
enum ColorTransformSubject: Equatable {
    case filter
    case inversion
    case filterAndInversion

    init?(_ readings: ColorFilterReadings?) {
        let filter = readings?.setting.map { $0 != .filter(.none) } ?? false
        let inversion = readings?.inversion == true
        switch (filter, inversion) {
        case (true, true): self = .filterAndInversion
        case (true, false): self = .filter
        case (false, true): self = .inversion
        case (false, false): return nil
        }
    }

    /// "the applied …"
    var noun: String {
        switch self {
        case .filter: return "filter"
        case .inversion: return "color inversion"
        case .filterAndInversion: return "filter and color inversion"
        }
    }

    /// "… can't be confirmed"
    var object: String {
        switch self {
        case .filter: return "the filter"
        case .inversion: return "color inversion"
        case .filterAndInversion: return "the filter and color inversion"
        }
    }
}

/// At most one sentence about what SurfaceFlinger shows for `subject`.
private func colorTransformStatus(_ subject: ColorTransformSubject, check: ColorTransformCheck?, apiLevel: Int?) -> String? {
    switch check {
    case .displayOff:
        return "The screen is off, so the applied \(subject.noun) can't be read."
    case .notApplied:
        return "SurfaceFlinger shows no color transform: this device may not draw \(subject.object)."
    case .combined:
        return "SurfaceFlinger also applies another color transform (Night Light, Extra dim, Bedtime mode or the display's color mode), so \(subject.object) can't be confirmed."
    case .unavailable:
        guard let apiLevel, apiLevel < 33 else { return nil }
        return "Android 12L and older don't report the applied \(subject.noun)."
    case .applied, nil:
        return nil
    }
}

/// The status line after a Color Filter write: a flash, or an error when
/// SurfaceFlinger shows nothing.
func colorFilterWriteMessage(option: ColorFilterOption, check: ColorTransformCheck) -> (flash: String?, error: String?) {
    let base = option == .none ? "Color filter turned off" : "Color filter set to \(option.title)"
    return colorTransformWriteMessage(base, check: check)
}

private func colorTransformWriteMessage(_ base: String, check: ColorTransformCheck) -> (flash: String?, error: String?) {
    switch check {
    case .applied, .unavailable, .displayOff:
        return (flash: base, error: nil)
    case .combined:
        return (flash: "\(base); another color transform is on too", error: nil)
    case .notApplied:
        return (flash: nil, error: "\(base), but SurfaceFlinger shows no color transform")
    }
}
