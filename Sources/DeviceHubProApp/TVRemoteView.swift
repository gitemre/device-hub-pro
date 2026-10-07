import DeviceHubProKit
import SwiftUI

/// The remote under a TV on the stage: a D-pad ring with Select, Back, Home,
/// Play/Pause and Menu. A TV is driven by these keys, not by touch, so the
/// stage offers them as buttons (`DeviceWorkspace.pressRemote`) next to the
/// Mac keys that do the same (arrows, Return, Escape: `RemoteKey(macKeyCode:)`).
///
/// One glass surface carries every control, never a glass per button
/// (`Glass.swift`, `toolbarControlSurface`'s warning).
struct TVRemoteView: View {
    let press: (RemoteKey) -> Void
    /// The buttons the device takes (an Apple TV has no Home, Play/Pause or
    /// Menu here, `RemoteKey.appleTVKeys`); every button by default.
    var keys: Set<RemoteKey> = Set(RemoteKey.allCases)

    /// The space the stage keeps for the remote under the device.
    static let reservedHeight: CGFloat = 124

    private static let ringDiameter: CGFloat = 92
    private static let buttonDiameter: CGFloat = 32

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 30, style: .continuous)
        HStack(spacing: 18) {
            VStack(spacing: 8) {
                if keys.contains(.back) { round(.back, glyph: "arrow.uturn.backward") }
                if keys.contains(.home) { round(.home, glyph: "house") }
            }
            dpad
            if keys.contains(.playPause) || keys.contains(.menu) {
                VStack(spacing: 8) {
                    if keys.contains(.playPause) { round(.playPause, glyph: "playpause.fill") }
                    if keys.contains(.menu) { round(.menu, glyph: "line.3.horizontal") }
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 10)
        .background(ParityMetrics.pillLift, in: shape)
        .liquidGlass(interactive: false, tint: ParityMetrics.pillTint, in: shape)
        .glassHairline(in: shape)
        .dhGlassRim(in: shape)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("TV remote")
    }

    private var dpad: some View {
        let reach = (Self.ringDiameter - Self.buttonDiameter) / 2 - 2
        return ZStack {
            Circle().fill(.primary.opacity(0.07))
            arrow(.up, glyph: "chevron.up").offset(y: -reach)
            arrow(.down, glyph: "chevron.down").offset(y: reach)
            arrow(.left, glyph: "chevron.left").offset(x: -reach)
            arrow(.right, glyph: "chevron.right").offset(x: reach)
            Button { press(.select) } label: {
                Text("OK").font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(RemoteButtonStyle(diameter: 34, fill: .primary.opacity(0.10)))
            .accessibilityLabel(RemoteKey.select.title)
            .help("Select (Return)")
        }
        .frame(width: Self.ringDiameter, height: Self.ringDiameter)
    }

    private func arrow(_ key: RemoteKey, glyph: String) -> some View {
        Button { press(key) } label: {
            Image(systemName: glyph).font(.system(size: 11, weight: .bold))
        }
        .buttonStyle(RemoteButtonStyle(diameter: 26, fill: .clear))
        .accessibilityLabel(key.title)
        .help("\(key.title) (arrow key)")
    }

    private func round(_ key: RemoteKey, glyph: String) -> some View {
        Button { press(key) } label: {
            Image(systemName: glyph).font(.system(size: 13, weight: .medium))
        }
        .buttonStyle(RemoteButtonStyle(diameter: Self.buttonDiameter, fill: .primary.opacity(0.08)))
        .accessibilityLabel(key.title)
        .help(key == .back ? "Back (Escape)" : key.title)
    }
}

/// A round remote button: a faint fill that darkens while pressed.
private struct RemoteButtonStyle: ButtonStyle {
    let diameter: CGFloat
    let fill: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(fill))
            .overlay(Circle().fill(.primary.opacity(configuration.isPressed ? 0.16 : 0)))
            .contentShape(Circle())
    }
}

/// Where the stage puts the remote: right under the device, as the
/// navigation bar sits under an Android handheld, and never lower than the
/// pill's band (a device that fills the stage leaves it there).
enum TVRemotePlacement {
    /// The stage's padding round the fitted device (`MirrorContainer`).
    static let stagePadding: CGFloat = 10
    static let gap: CGFloat = 8
    /// The remote's laid-out height, ring plus padding.
    static let height: CGFloat = 112

    /// The remote's top edge in the stage's coordinates.
    /// - Parameters:
    ///   - stageHeight: the stage's full height, the remote's band included.
    ///   - pillBand: the band at the bottom the pill floats in.
    ///   - deviceHeight: the device's height at rest.
    static func top(stageHeight: CGFloat, pillBand: CGFloat, deviceHeight: CGFloat) -> CGFloat {
        let lowest = stageHeight - pillBand - 8 - height
        // The device is centred in what the stage keeps for it.
        let area = stageHeight - TVRemoteView.reservedHeight - 2 * stagePadding - pillBand
        let centre = stagePadding + area / 2
        let wanted = centre + deviceHeight / 2 + gap
        return min(max(wanted, 0), max(lowest, 0))
    }
}

/// The stage's single hook for the remote: leaves room under a TV and draws
/// the remote there, right under the device. Any other device is untouched.
struct StageRemoteHook: ViewModifier {
    @Environment(DeviceWorkspace.self) private var workspace

    func body(content: Content) -> some View {
        if let family = workspace.remoteFamily {
            content
                .padding(.bottom, TVRemoteView.reservedHeight)
                .overlay(alignment: .topLeading) {
                    GeometryReader { proxy in
                        TVRemoteView(
                            press: { workspace.pressRemote($0) },
                            keys: family == .appleTV ? Set(RemoteKey.appleTVKeys) : Set(RemoteKey.allCases)
                        )
                        .frame(maxWidth: .infinity)
                        .offset(y: TVRemotePlacement.top(
                            stageHeight: proxy.size.height,
                            pillBand: ParityMetrics.mainStagePillBand,
                            deviceHeight: workspace.window.deviceExtent.height
                        ))
                    }
                }
        } else {
            content
        }
    }
}
