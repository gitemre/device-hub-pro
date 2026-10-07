import AppKit
import SwiftUI

/// Device Hub's stage banner: a 50 pt glass card floating just above the
/// pill (its bottom 7 pt over the pill's top), a leading picture, a 13 pt
/// semibold title over an 11 pt secondary line, and a trailing round control.
/// Measured on DH 27.0 for "Screenshot Saved / Open in Finder" (285 x 50 pt,
/// a 26 pt thumbnail 12 pt from the edge, a 17 pt grey disc with a chevron
/// 12 pt from the other) and "Zoom Controls / Hold ⌥⌘ and drag to move
/// around." (270 x 50, a 21 pt blue move glyph, a 17 pt grey disc with an ×).
struct StageBanner<Leading: View>: View {
    let title: String
    let subtitle: String
    /// Sized to at least this wide (the screenshot banner's 285 pt); nil
    /// fits the text.
    var minWidth: CGFloat?
    /// The trailing disc's symbol and what it does.
    let trailingSymbol: String
    let trailingLabel: String
    /// The whole card acts (the screenshot banner opens Finder); nil makes
    /// only the trailing disc a control.
    var cardAction: (() -> Void)?
    let trailingAction: () -> Void
    @ViewBuilder let leading: () -> Leading

    var body: some View {
        HStack(spacing: ParityMetrics.stageBannerSpacing) {
            leading()
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            Button(action: trailingAction) {
                Image(systemName: trailingSymbol)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: ParityMetrics.stageBannerDisc, height: ParityMetrics.stageBannerDisc)
                    .background(Circle().fill(Color.primary.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(trailingLabel)
        }
        .padding(.horizontal, ParityMetrics.stageBannerPadding)
        .frame(minWidth: minWidth, minHeight: ParityMetrics.stageBannerHeight, maxHeight: ParityMetrics.stageBannerHeight)
        .fixedSize(horizontal: true, vertical: false)
        // Device Hub's card is real glass: over the zoomed picture it is
        // tinted by it (measured on DH 27.0), over the white stage it reads
        // white (#fefefd).
        .liquidGlass(in: RoundedRectangle(cornerRadius: ParityMetrics.stageBannerCorner, style: .continuous))
        .glassHairline(in: RoundedRectangle(cornerRadius: ParityMetrics.stageBannerCorner, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: ParityMetrics.stageBannerCorner, style: .continuous))
        .onTapGesture { cardAction?() }
        .accessibilityElement(children: .contain)
    }
}

/// "Screenshot Saved / Open in Finder" over the pill (`CaptureController.savedScreenshot`).
struct ScreenshotSavedBanner: View {
    let shot: SavedScreenshot
    let open: () -> Void
    let dismiss: () -> Void

    var body: some View {
        StageBanner(
            title: shot.title,
            subtitle: shot.subtitle,
            minWidth: ParityMetrics.screenshotBannerWidth,
            trailingSymbol: "chevron.right",
            trailingLabel: "Open in Finder",
            cardAction: open,
            trailingAction: open
        ) {
            Group {
                if let thumbnail = shot.thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color.secondary.opacity(0.2)
                }
            }
            .frame(width: ParityMetrics.stageBannerThumbnail, height: ParityMetrics.stageBannerThumbnail)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            // Drag the thumbnail out as the saved file itself (into Finder,
            // Mail, a chat ...).
            .onDrag { shot.dragProvider() ?? NSItemProvider() }
            .accessibilityHidden(true)
        }
    }
}

/// "Zoom Controls / Hold ⌥⌘ and drag to move around." while the stage is
/// zoomed past its size (`WindowState.showsZoomHint(dismissed:)`).
struct ZoomHintBanner: View {
    let dismiss: () -> Void

    var body: some View {
        StageBanner(
            title: "Zoom Controls",
            subtitle: "Hold ⌥⌘ and drag to move around.",
            trailingSymbol: "xmark",
            trailingLabel: "Dismiss",
            cardAction: nil,
            trailingAction: dismiss
        ) {
            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color.blue)
                .frame(width: ParityMetrics.stageBannerThumbnail)
                .accessibilityHidden(true)
        }
    }
}

/// The banners over the stage's pill: the screenshot's, else the zoom hint.
/// Sized to the banner and laid over the stage with `.overlay(alignment: .bottom)`,
/// so nothing else of the stage stops taking clicks.
struct StageBannerHost: View {
    @Environment(AppModel.self) private var model
    @Environment(DeviceWorkspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            if let shot = workspace.capture.savedScreenshot {
                ScreenshotSavedBanner(
                    shot: shot,
                    open: { workspace.capture.revealSavedScreenshot() },
                    dismiss: { workspace.capture.dismissBanner() }
                )
                .id(shot.id)
                .transition(transition)
            } else if showsZoomHint {
                ZoomHintBanner { model.preferences.setZoomHintDismissed(true) }
                    .transition(transition)
            }
        }
        .animation(reduceMotion ? nil : MotionMetrics.banner, value: workspace.capture.savedScreenshot)
        .animation(reduceMotion ? nil : MotionMetrics.banner, value: showsZoomHint)
        .padding(.bottom, ParityMetrics.stageBannerBottomInset)
    }

    private var showsZoomHint: Bool {
        workspace.window.showsZoomHint(dismissed: model.preferences.zoomHintDismissed)
    }

    private var transition: AnyTransition {
        reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity)
    }
}
