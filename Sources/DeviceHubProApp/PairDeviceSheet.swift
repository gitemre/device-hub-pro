import SwiftUI
import DeviceHubProKit

/// Wireless ADB pairing (spec §11.3). The phone's "Pair device with pairing
/// code" dialog provides an IP:port plus a 6-digit code; after `adb pair`
/// succeeds the device is connected on the Wireless debugging screen's
/// IP address & Port — a random port on Android 11+, never the pairing port
/// (and not the legacy 5555). The connect port is optional: left empty, the
/// phone's mDNS announcement supplies it.
///
/// A pair that succeeded while the connect did not spends the code, so the
/// sheet then switches to connecting ("Connect" re-runs only `adb connect`)
/// instead of asking for a new pair. Errors stay inline here rather than in
/// the window's alert.
struct PairDeviceSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// Set when the Pair Nearby Device sheet shows this form inside itself:
    /// a Back button then returns to its QR code.
    var onBack: (() -> Void)?

    @State private var pairingAddress = ""
    @State private var pairingCode = ""
    @State private var connectPort = ""
    @State private var errorMessage: String?
    /// The paired phone's host once a pair succeeded without connecting;
    /// the primary action then connects instead of pairing again.
    @State private var pairedHost: String?
    /// What to do after a pair that did not connect (not an error).
    @State private var pairedNotice: String?
    @State private var pairingTask: Task<Void, Never>?
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case address
        case code
        case connectPort
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                LabeledContent("Pairing Address:") {
                    TextField("192.168.1.42:37000", text: $pairingAddress)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .frame(maxWidth: ParityMetrics.pairingFormMaxFieldWidth)
                        .focused($focusedField, equals: .address)
                        .onSubmit(submit)
                }

                LabeledContent("Pairing Code:") {
                    TextField("123456", text: $pairingCode)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .frame(maxWidth: ParityMetrics.pairingFormMaxFieldWidth)
                        .focused($focusedField, equals: .code)
                        .onSubmit(submit)
                }

                LabeledContent("Connect Port:") {
                    TextField("Automatic", text: $connectPort)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .frame(maxWidth: ParityMetrics.pairingFormMaxFieldWidth)
                        .focused($focusedField, equals: .connectPort)
                        .onSubmit(submit)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            // The running attempt pairs what was entered: an edit now would
            // leave Connect mode while the attempt's result re-entered it
            // for the old host, and Connect then targeted an unpaired one.
            .disabled(model.pairing.isPairingDevice)
            // Another address or code is another pairing: back to Pair.
            .onChange(of: pairingAddress) { leaveConnectMode() }
            .onChange(of: pairingCode) { leaveConnectMode() }

            Text("On the phone, open Developer options ▸ Wireless debugging. \"Pair device with pairing code\" shows the pairing address and code. Leave Connect Port empty to find the phone automatically, or enter the port shown under IP address & Port on the Wireless debugging screen — it differs from the pairing port.")
                .font(.system(size: ParityMetrics.pairingHintFontSize))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, ParityMetrics.pairingStatusHorizontalInset)
                .padding(.bottom, ParityMetrics.pairingStatusBottomSpacing)

            LocalNetworkDeniedHint()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, ParityMetrics.pairingStatusHorizontalInset)
                .padding(.bottom, ParityMetrics.pairingStatusBottomSpacing)

            if let pairedNotice {
                Label(pairedNotice, systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, ParityMetrics.pairingStatusHorizontalInset)
                    .padding(.bottom, ParityMetrics.pairingStatusBottomSpacing)
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, ParityMetrics.pairingStatusHorizontalInset)
                    .padding(.bottom, ParityMetrics.pairingStatusBottomSpacing)
            }

            if model.pairing.isPairingDevice {
                HStack(spacing: ParityMetrics.pairingStatusSpacing) {
                    ProgressView()
                        .controlSize(.small)
                    Text(pairedHost == nil ? "Pairing…" : "Connecting…")
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, ParityMetrics.pairingStatusBottomSpacing)
            }

            HStack {
                if let onBack {
                    Button("Back") { cancelPairing(); onBack() }
                }
                Spacer()
                // Cancel stays enabled while pairing: an unreachable host is
                // bounded by the adb timeout, and this dismisses immediately.
                Button("Cancel") { cancel() }
                    .keyboardShortcut(.cancelAction)
                Button(pairedHost == nil ? "Pair" : "Connect") { submit() }
                    .glassProminentButton()
                    .disabled(model.pairing.isPairingDevice)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, ParityMetrics.pairingStatusHorizontalInset)
            .padding(.bottom, ParityMetrics.pairingButtonsBottomSpacing)
        }
        .frame(width: ParityMetrics.pairingSheetWidth)
        .task {
            focusedField = .address
        }
        .onDisappear {
            // Any dismissal (Cancel, Escape, a window close) abandons the
            // attempt: the adb process is terminated and the model's
            // generation check ignores a late result.
            cancelPairing()
        }
    }

    private func submit() {
        guard !model.pairing.isPairingDevice else { return }
        errorMessage = nil
        let alreadyPaired = pairedHost != nil
        let address = pairingAddress
        let code = pairingCode
        let port = connectPort
        // The fields are disabled while the attempt runs, which drops focus.
        let focus = focusedField
        pairingTask = Task {
            let result = await model.pairing.pairWirelessDevice(
                address: address,
                code: code,
                connectPort: port,
                alreadyPaired: alreadyPaired
            )
            guard !Task.isCancelled else { return }
            switch result {
            case .connected:
                dismiss()
            case .cancelled:
                break
            case .failed(let message):
                errorMessage = message
                focusedField = focus
            case .paired(let host, let message):
                // Connect mode is for the pairing the fields still show.
                guard pairingAddress == address, pairingCode == code else { return }
                pairedHost = host
                pairedNotice = message
                focusedField = .connectPort
            }
        }
    }

    private func leaveConnectMode() {
        pairedHost = nil
        pairedNotice = nil
    }

    private func cancel() {
        cancelPairing()
        dismiss()
    }

    private func cancelPairing() {
        pairingTask?.cancel()
        pairingTask = nil
        model.pairing.cancelPairing()
    }
}
