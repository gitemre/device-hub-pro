import AppKit
import SwiftUI
import UniformTypeIdentifiers
import DeviceHubProKit

/// Makes a view a Send Files drop target: files and folders dragged from the
/// Finder (and, for an Apple device, links) are sent to `target`, and while the
/// drag is over the view an overlay says what will happen ("Add 3 photos to
/// Photos", "Copy 2 files to Downloads", "Install app").
///
/// The overlay's text is read from the drag's file URLs as soon as it enters;
/// when macOS does not hand them over before the drop, the overlay says "Drop
/// to send files" and the drop itself still does the right thing.
struct SendFilesDropModifier: ViewModifier {
    let controller: SendFilesController
    /// The device a drop is aimed at, read when the drop happens; nil refuses it.
    let target: @MainActor () -> SendFilesController.Target?
    let platform: DevicePlatform?
    /// A small cue for a sidebar row.
    var compact = false
    var confirmCertificates: @MainActor @Sendable ([URL]) -> Void = { _ in }

    @State private var isTargeted = false
    @State private var overlayText = "Drop to send files"
    @State private var generation = 0

    func body(content: Content) -> some View {
        content
            .onDrop(
                of: StageDropTypes.accepted(by: platform),
                delegate: Delegate(
                    controller: controller,
                    target: target,
                    confirmCertificates: confirmCertificates,
                    entered: { providers in
                        isTargeted = true
                        overlayText = "Drop to send files"
                        generation += 1
                        let mine = generation
                        guard let device = target() else { return }
                        Task { @MainActor in
                            let urls = await SimulatorAppsController.urls(from: providers)
                            guard mine == generation, isTargeted, !urls.isEmpty else { return }
                            overlayText = controller.overlayText(for: urls, target: device)
                        }
                    },
                    exited: {
                        generation += 1
                        isTargeted = false
                    }
                )
            )
            .overlay {
                if isTargeted {
                    SendFilesDropOverlay(text: overlayText, compact: compact)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.12), value: isTargeted)
    }

    @MainActor
    private struct Delegate: DropDelegate {
        let controller: SendFilesController
        let target: @MainActor () -> SendFilesController.Target?
        let confirmCertificates: @MainActor @Sendable ([URL]) -> Void
        let entered: @MainActor ([NSItemProvider]) -> Void
        let exited: @MainActor () -> Void

        func validateDrop(info: DropInfo) -> Bool {
            target() != nil
        }

        func dropEntered(info: DropInfo) {
            entered(info.itemProviders(for: [.fileURL, .url]))
        }

        func dropExited(info: DropInfo) {
            exited()
        }

        func dropUpdated(info: DropInfo) -> DropProposal? {
            DropProposal(operation: target() == nil ? .forbidden : .copy)
        }

        func performDrop(info: DropInfo) -> Bool {
            exited()
            guard let device = target() else { return false }
            let providers = info.itemProviders(for: [.fileURL, .url])
            guard !providers.isEmpty else { return false }
            let controller = controller
            let confirm = confirmCertificates
            Task { @MainActor in
                let urls = await SimulatorAppsController.urls(from: providers)
                await controller.send(urls, to: device, confirmCertificates: confirm)
            }
            return true
        }
    }
}

/// The drag-over cue: a tinted wash with an accent outline and the sentence
/// naming what the drop will do.
private struct SendFilesDropOverlay: View {
    let text: String
    var compact = false

    var body: some View {
        if compact {
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(text)
        } else {
            wide
        }
    }

    private var wide: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.accentColor.opacity(0.12))
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
            Text(text)
                .font(.system(size: 13, weight: .semibold))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(24)
        }
        .padding(6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

extension View {
    /// See `SendFilesDropModifier`.
    func sendFilesDrop(
        controller: SendFilesController,
        platform: DevicePlatform?,
        compact: Bool = false,
        confirmCertificates: @escaping @MainActor @Sendable ([URL]) -> Void = { _ in },
        target: @escaping @MainActor () -> SendFilesController.Target?
    ) -> some View {
        modifier(SendFilesDropModifier(
            controller: controller,
            target: target,
            platform: platform,
            compact: compact,
            confirmCertificates: confirmCertificates
        ))
    }
}
