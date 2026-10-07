import SwiftUI
import DeviceHubProKit

/// Device Hub's "Pair Nearby Device" sheet (one
/// sheet for iPhones and Android phones). A rounded card: a blue antenna
/// glyph, the bold "Waiting to pair.", a row of square platform tiles (the
/// selected one has a blue border), the instructions of the selected
/// platform, a wide Cancel and a small footer. Device Hub's tiles are iPhone
/// and iPad, Apple TV and Vision Pro; ours are iPhone and Android Phone
/// (phones only for now).
///
/// - iPhone: the phones CoreDevice lists as unpaired over the network
///   (`ApplePhysicalInventory.pairCandidates`) and `devicectl manage pair`.
///   Needs "Show physical Apple devices"; the sheet offers to turn it on.
/// - Android Phone: a QR code in Android Studio's format; the phone scans it
///   from Developer options ▸ Wireless debugging ▸ Pair device with QR code
///   and adb pairs and connects (`WirelessPairingController.pairWithQR`). The
///   existing pairing-code form stays one link away.
struct PairNearbySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(DeviceWorkspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss

    enum Platform: String, CaseIterable, Identifiable {
        case iPhone = "iPhone"
        case android = "Android Phone"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .iPhone: "iphone"
            case .android: "smartphone"
            }
        }
    }

    @State private var platform: Platform = .iPhone
    @State private var showsCodeForm = false

    // iPhone
    @State private var pairingUDID: String?
    @State private var iphoneError: String?
    @State private var showsNoCandidateHint = false

    // Android QR
    @State private var credentials = WirelessPairing.makeQRCredentials()
    @State private var qrState: QRState = .waiting

    enum QRState: Equatable {
        case waiting
        case expired
        case failed(String)
        case paired(String)
    }

    var body: some View {
        if showsCodeForm {
            PairDeviceSheet(onBack: {
                showsCodeForm = false
                qrState = .waiting
            })
        } else {
            card
        }
    }

    private var card: some View {
        VStack(spacing: PairNearbyMetrics.sectionSpacing) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: PairNearbyMetrics.glyphSize, weight: .regular))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text("Waiting to pair.")
                .font(.title2.bold())

            HStack(spacing: PairNearbyMetrics.tileSpacing) {
                ForEach(Platform.allCases) { candidate in
                    PairNearbyTile(
                        title: candidate.rawValue,
                        symbol: candidate.symbol,
                        isSelected: platform == candidate
                    ) { platform = candidate }
                }
            }

            Group {
                switch platform {
                case .iPhone: iPhoneContent
                case .android: androidContent
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                dismiss()
            } label: {
                Text("Cancel").frame(maxWidth: .infinity)
            }
            .glassButton()
            .controlSize(.large)
            .keyboardShortcut(.cancelAction)

            footer
        }
        .padding(PairNearbyMetrics.cardInset)
        .frame(width: PairNearbyMetrics.sheetWidth)
        .task(id: qrTaskID) { await runQRAttempt() }
        .onDisappear { model.pairing.cancelPairing() }
    }

    // MARK: - iPhone

    @ViewBuilder
    private var iPhoneContent: some View {
        let inventory = model.physicalInventory
        if let guidance = model.simulators.tooling.guidance, model.simulators.tooling.isProbed {
            // devicectl lives inside Xcode: without a usable one no iPhone
            // can be listed or paired. Android Phone stays one tile away.
            XcodeHintView(guidance: guidance, checkAgain: { Task { await model.checkXcodeAgain() } })
        } else if !inventory.isShowing {
            VStack(alignment: .leading, spacing: 10) {
                Text("Showing physical Apple devices is off, so Device Hub Pro is not looking for iPhones. Turn it on to find an iPhone that is waiting to pair.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Show Physical Apple Devices") { inventory.setShowing(true) }
                    .glassProminentButton()
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                PairNearbyBullet {
                    Text("On the device you\u{2019}d like to pair, go to Settings > Privacy & Security > Developer Mode.")
                }
                PairNearbyBullet {
                    (Text("Make sure Developer Mode ")
                        + Text("is turned on.").foregroundStyle(Color.accentColor))
                }
                candidateList(inventory)
                if let iphoneError {
                    Text(iphoneError)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private func candidateList(_ inventory: ApplePhysicalInventory) -> some View {
        let candidates = inventory.pairCandidates
        let paired = inventory.pairedPhones
        VStack(alignment: .leading, spacing: 10) {
            if candidates.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(inventory.hasListed
                            ? "Looking for iPhones waiting to pair\u{2026}"
                            : "Checking the network\u{2026}")
                            .foregroundStyle(.secondary)
                    }
                    if showsNoCandidateHint {
                        Text(PairNearbyHint.text)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 2)
            } else {
                deviceRows(candidates) { entry in
                    if pairingUDID == entry.udid {
                        ProgressView().controlSize(.small)
                        Text("Accept on the iPhone\u{2026}")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Pair") { pair(entry) }
                            .glassProminentButton()
                            .disabled(pairingUDID != nil)
                    }
                }
            }
            if !paired.isEmpty {
                Text("Already Paired")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                deviceRows(paired) { _ in
                    Text("Paired")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .opacity(0.6)
                .allowsHitTesting(false)
            }
        }
        .task(id: candidates.isEmpty) {
            showsNoCandidateHint = false
            guard candidates.isEmpty else { return }
            if await PairNearbyHint.waitForHint() { showsNoCandidateHint = true }
        }
    }

    private func deviceRows<Trailing: View>(
        _ entries: [ApplePhysicalEntry],
        @ViewBuilder trailing: @escaping (ApplePhysicalEntry) -> Trailing
    ) -> some View {
        VStack(spacing: 0) {
            ForEach(entries) { entry in
                HStack(spacing: 10) {
                    Image(systemName: entry.symbolName)
                        .frame(width: 22)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.name)
                        Text([entry.modelName, entry.osLabel].compactMap { $0 }.joined(separator: " \u{00B7} "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    trailing(entry)
                }
                .padding(.horizontal, 10)
                .frame(minHeight: DHSheetMetrics.rowHeight)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: DHSheetMetrics.cardRadius, style: .continuous)
                .fill(Color(nsColor: .quaternarySystemFill))
        )
    }

    private func pair(_ entry: ApplePhysicalEntry) {
        guard pairingUDID == nil else { return }
        iphoneError = nil
        pairingUDID = entry.udid
        let name = entry.name
        Task {
            do {
                try await model.physicalInventory.pairNearby(udid: entry.udid)
                model.status.flash("Paired \(name)")
                dismiss()
            } catch {
                pairingUDID = nil
                iphoneError = "Could not pair \(name): \(ApplePhysicalController.describe(error))"
            }
        }
    }

    // MARK: - Android Phone

    /// The QR attempt runs while the Android tile shows the code; another
    /// code, another tile or the code form cancels it.
    private var qrTaskID: String {
        platform == .android && !showsCodeForm && model.adbIsAvailable ? credentials.serviceName : "idle"
    }

    @ViewBuilder
    private var androidContent: some View {
        if !model.adbIsAvailable {
            // Without the Android tools nothing can pair: say so, and lead to
            // the setup instead of a QR code that can never work.
            VStack(alignment: .leading, spacing: 10) {
                Text("Pairing an Android phone needs Google\u{2019}s Android tools, which are not set up on this Mac yet.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Set Up Android Tools\u{2026}") {
                    dismiss()
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(350))
                        workspace.window.isAndroidSetupPresented = true
                    }
                }
                .glassProminentButton()
            }
        } else {
            androidPairingContent
        }
    }

    @ViewBuilder
    private var androidPairingContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            PairNearbyBullet {
                Text("On the phone, open Settings > Developer options > Wireless debugging.")
            }
            PairNearbyBullet {
                Text("Tap Pair device with QR code, then scan this code.")
            }
            HStack {
                Spacer()
                if let image = QRCodeImage.nsImage(for: credentials.payload, points: PairNearbyMetrics.qrSize) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: PairNearbyMetrics.qrSize, height: PairNearbyMetrics.qrSize)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .accessibilityLabel("Pairing QR code")
                }
                Spacer()
            }
            LocalNetworkDeniedHint()
            qrStatus
            HStack {
                Button("Pair with a code instead\u{2026}") { showsCodeForm = true }
                    .buttonStyle(.link)
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var qrStatus: some View {
        switch qrState {
        case .waiting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(model.pairing.isWaitingForQR ? "Waiting for the phone to scan\u{2026}" : "Starting\u{2026}")
                    .foregroundStyle(.secondary)
            }
        case .expired:
            qrMessage("The code was not scanned in time.", isError: false)
        case .failed(let message):
            qrMessage(message, isError: true)
        case .paired(let message):
            qrMessage(message, isError: false)
        }
    }

    private func qrMessage(_ text: String, isError: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text)
                .font(.callout)
                .foregroundStyle(isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Button("New Code") { newCode() }
                .glassButton()
        }
    }

    private func newCode() {
        credentials = WirelessPairing.makeQRCredentials()
        qrState = .waiting
    }

    private func runQRAttempt() async {
        guard platform == .android, !showsCodeForm, model.adbIsAvailable else { return }
        // Wireless pairing is the first thing that needs the local network:
        // the Bonjour browse and adb's own mDNS start here, not at launch.
        model.wantLocalNetwork()
        await model.waitForLocalNetwork()
        guard !Task.isCancelled else { return }
        let mine = credentials
        let result = await model.pairing.pairWithQR(mine)
        guard !Task.isCancelled, credentials == mine else { return }
        switch result {
        case .cancelled:
            break
        case .notScanned:
            qrState = .expired
        case .attempt(.connected):
            dismiss()
        case .attempt(.cancelled):
            break
        case .attempt(.failed(let message)):
            qrState = .failed(message)
        case .attempt(.paired(_, let message)):
            qrState = .paired(message)
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        switch platform {
        case .iPhone:
            Text("For devices running iOS 26 or watchOS 26 (or earlier), see [WWDC 2022: Get to know Developer Mode](https://developer.apple.com/videos/play/wwdc2022/110344/).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        case .android:
            Text("Wireless debugging needs Android 11 or later, with the phone and this Mac on the same Wi-Fi network.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The sheet's measurements, from Device Hub's Pair Nearby Device sheet.
enum PairNearbyMetrics {
    static let sheetWidth: CGFloat = 460
    static let cardInset: CGFloat = 24
    static let sectionSpacing: CGFloat = 16
    static let glyphSize: CGFloat = 38
    static let tileSize: CGFloat = 104
    static let tileSpacing: CGFloat = 12
    static let tileRadius: CGFloat = 18
    static let tileGlyphSize: CGFloat = 40
    static let qrSize: CGFloat = 176
}

/// One large square platform tile: a glyph over its name, a blue border
/// when selected.
private struct PairNearbyTile: View {
    let title: String
    let symbol: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: PairNearbyMetrics.tileGlyphSize, weight: .light))
                Text(title)
                    .font(.callout)
            }
            .frame(width: PairNearbyMetrics.tileSize, height: PairNearbyMetrics.tileSize)
            .background(
                RoundedRectangle(cornerRadius: PairNearbyMetrics.tileRadius, style: .continuous)
                    .fill(Color(nsColor: .quaternarySystemFill))
            )
            .overlay(
                RoundedRectangle(cornerRadius: PairNearbyMetrics.tileRadius, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 3)
            )
            .contentShape(RoundedRectangle(cornerRadius: PairNearbyMetrics.tileRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A bulleted instruction line.
private struct PairNearbyBullet<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\u{2022}").foregroundStyle(.secondary)
            content()
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The hint the iPhone tab shows once it has looked for a while without
/// finding an unpaired iPhone (an endless spinner reads as a hang
/// when the phone is already paired).
enum PairNearbyHint {
    static let delay: Duration = .seconds(4)
    static let text = "Paired iPhones appear in the sidebar. To pair a new iPhone, turn on Developer Mode and connect it with a cable or join the same Wi-Fi."

    /// Waits `delay` through `sleep` (injectable); true when the wait ran to
    /// its end, false when the task was cancelled first (a candidate
    /// appeared, the sheet closed).
    static func waitForHint(
        sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async -> Bool {
        do {
            try await sleep(delay)
            return !Task.isCancelled
        } catch {
            return false
        }
    }
}
