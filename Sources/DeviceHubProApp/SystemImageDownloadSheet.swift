import SwiftUI
import DeviceHubProKit

/// The "Download More System Images…" sheet of the create-AVD sheet: the
/// images this Mac can run and the chosen device profile accepts, grouped by
/// Android release (newest stable first, previews last, the recommended image
/// on top, extension builds like `android-33-ext4` folded under their
/// release), one row per variant
/// with a Download button, live progress with cancel, or an installed mark
/// and its size. Downloads go through the shared `SDKComponentModel` (one at
/// a time, app-wide, with the license gate); `onInstalled` hears each image
/// that finished so the OS Version popup can select it.
struct SystemImageDownloadSheet: View {
    @Environment(\.dismiss) private var dismiss
    let sdk: SDKComponentModel
    let category: SkinCatalogEntry.Category
    let hostAbi: String
    let onInstalled: (SystemImage) -> Void

    @State private var expanded: Set<String> = []
    @State private var didOpenFirst = false
    /// Releases whose extension builds are shown.
    @State private var extensionsShown: Set<String> = []

    static let width: CGFloat = 470
    static let listHeight: CGFloat = 340

    /// The images the sheet offers: compatible with the profile and the host.
    static func offered(_ images: [SystemImage], category: SkinCatalogEntry.Category, hostAbi: String) -> [SystemImage] {
        SystemImageCatalog.compatible(images.filter { $0.abi == hostAbi }, with: category)
    }

    private var groups: [SystemImageGroup] {
        SystemImageCatalog.groups(Self.offered(sdk.availableImages, category: category, hostAbi: hostAbi))
    }

    private var recommended: SystemImage? {
        SystemImageCatalog.recommended(Self.offered(sdk.availableImages, category: category, hostAbi: hostAbi))
    }

    var body: some View {
        VStack(spacing: 0) {
            content
                .padding(DHSheetMetrics.cardInset)
            Divider()
            footer
        }
        .frame(width: Self.width)
        .onAppear { openFirstGroup() }
        .onChange(of: sdk.availableImages) { openFirstGroup() }
        .sheet(item: Binding(get: { sdk.licensePrompt }, set: { _ in })) { prompt in
            SDKLicenseSheet(
                prompt: prompt,
                onAccept: { sdk.acceptLicense() },
                onDecline: { sdk.declineLicense() }
            )
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Download System Images")
                .font(.headline)
            switch sdk.availableState {
            case .idle, .loading:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Loading available system images\u{2026}")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 80)
            case .unavailable(let message):
                Text(message)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
            case .loaded:
                if groups.isEmpty {
                    Text("No system images are offered for this device profile on this Mac.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 80)
                } else {
                    list
                }
            }
        }
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 0) {
                if let recommended {
                    recommendedView(recommended)
                    Divider().padding(.horizontal, DHSheetMetrics.rowInset)
                }
                ForEach(groups) { group in
                    groupView(group)
                    if group.id != groups.last?.id {
                        Divider().padding(.horizontal, DHSheetMetrics.rowInset)
                    }
                }
            }
        }
        .frame(height: Self.listHeight)
        .background(
            RoundedRectangle(cornerRadius: DHSheetMetrics.cardRadius, style: .continuous)
                .fill(Color(nsColor: .quaternarySystemFill))
        )
    }

    private func groupView(_ group: SystemImageGroup) -> some View {
        let isOpen = expanded.contains(group.id)
        let installed = group.images.filter { sdk.isInstalled($0.package) }.count
        return VStack(spacing: 0) {
            Button {
                if isOpen { expanded.remove(group.id) } else { expanded.insert(group.id) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .frame(width: 12)
                    Text(group.title)
                    Spacer(minLength: 8)
                    if installed > 0 {
                        Text("\(installed) installed")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, DHSheetMetrics.rowInset)
                .frame(height: DHSheetMetrics.rowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(group.title)
            .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
            if isOpen {
                let base = group.baseImages
                let extensions = group.extensionImages
                // Extension builds are the same release with a newer
                // extension level: folded away unless they are all there is
                // or one of them is installed.
                let showsExtensions = extensionsShown.contains(group.id) || base.isEmpty
                    || extensions.contains { sdk.isInstalled($0.package) }
                ForEach(base) { image in
                    row(image, in: group)
                }
                if !extensions.isEmpty {
                    if !base.isEmpty, !extensions.contains(where: { sdk.isInstalled($0.package) }) {
                        Button {
                            if extensionsShown.contains(group.id) {
                                extensionsShown.remove(group.id)
                            } else {
                                extensionsShown.insert(group.id)
                            }
                        } label: {
                            Text(showsExtensions
                                ? "Hide extension builds"
                                : "Show \(extensions.count) extension build\(extensions.count == 1 ? "" : "s")")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(.leading, DHSheetMetrics.rowInset + 20)
                                .frame(maxWidth: .infinity, minHeight: DHSheetMetrics.rowHeight, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if showsExtensions {
                        ForEach(extensions) { image in
                            row(image, in: group)
                        }
                    }
                }
            }
        }
    }

    /// The image to download when the user has no preference: the newest
    /// stable release's Play Store (or the form factor's own) image.
    private func recommendedView(_ image: SystemImage) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Recommended")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(image.versionTitle) \u{00B7} \(image.variantTitle)")
                Text(image.architectureTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            trailing(for: image)
        }
        .padding(.horizontal, DHSheetMetrics.rowInset)
        .padding(.vertical, 6)
        .frame(minHeight: DHSheetMetrics.rowHeight)
    }

    private func row(_ image: SystemImage, in group: SystemImageGroup) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(group.variantTitle(for: image))
                Text(image.architectureTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            trailing(for: image)
        }
        .padding(.leading, DHSheetMetrics.rowInset + 20)
        .padding(.trailing, DHSheetMetrics.rowInset)
        .frame(minHeight: DHSheetMetrics.rowHeight)
    }

    @ViewBuilder
    private func trailing(for image: SystemImage) -> some View {
        if sdk.isInstalled(image.package) {
            HStack(spacing: 6) {
                Text(sdk.installedSizeText(package: image.package))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Installed")
            }
        } else {
            switch sdk.downloadState(package: image.package) {
            case .downloading(let progress):
                HStack(spacing: 8) {
                    if let progress {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .frame(width: 80)
                        Text("\(Int((progress * 100).rounded()))%")
                            .font(.callout)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Button("Cancel") { sdk.cancelDownload() }
                        .controlSize(.small)
                }
                .accessibilityLabel("Downloading \(image.versionTitle) \(image.variantTitle)")
            case .failed(let message):
                HStack(spacing: 8) {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .frame(maxWidth: 170, alignment: .trailing)
                    Button("Retry") { start(image) }
                        .controlSize(.small)
                        .disabled(!sdk.canStartDownload)
                }
            case .idle:
                Button("Download") { start(image) }
                    .controlSize(.small)
                    .disabled(!sdk.canStartDownload)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if sdk.isDownloading {
                Text("Downloading\u{2026}")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") { dismiss() }
                .glassProminentButton()
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, DHSheetMetrics.footerSide)
        .padding(.top, DHSheetMetrics.footerTop)
        .padding(.bottom, DHSheetMetrics.footerBottom)
    }

    private func openFirstGroup() {
        guard !didOpenFirst, let first = groups.first else { return }
        didOpenFirst = true
        // The release of the recommended image, else the newest.
        let release = recommended.flatMap { image in groups.first { $0.images.contains(image) } } ?? first
        expanded.insert(release.id)
    }

    private func start(_ image: SystemImage) {
        Task {
            if await sdk.startDownload(package: image.package) == .installed {
                onInstalled(image)
            }
        }
    }
}
