import SwiftUI
import Observation
import DeviceHubProKit

/// Device ▸ Port Forwarding…: the `adb forward` and `adb reverse` rules of the
/// selected Android device, with Add and Remove. Every call names the
/// device's serial; nothing polls (Refresh reads again).
@MainActor
@Observable
final class PortForwardingModel {
    private let adb: AdbClient?
    let serial: String?

    private(set) var rules: [PortForwardRule] = []
    private(set) var isBusy = false
    private(set) var message: String?

    var direction: PortForwardRule.Direction = .forward
    var listen = "tcp:"
    var target = "tcp:"

    init(adb: AdbClient?, serial: String?) {
        self.adb = adb
        self.serial = serial
    }

    var validation: String? {
        PortForwarding.validate(direction: direction, listen: listen, target: target)
    }

    var listenLabel: String { direction == .forward ? "Mac listens on:" : "Device listens on:" }
    var targetLabel: String { direction == .forward ? "Device target:" : "Mac target:" }

    func refresh() async {
        guard let adb, let serial else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            rules = try await adb.allPortForwardRules(serial: serial)
            message = nil
        } catch {
            if !error.isCancellation { message = String(describing: error) }
        }
    }

    func add() async {
        guard let adb, let serial, validation == nil else { return }
        isBusy = true
        do {
            try await adb.addPortForward(
                serial: serial,
                rule: PortForwardRule(
                    direction: direction,
                    listen: PortForwarding.normalized(listen),
                    target: PortForwarding.normalized(target)
                )
            )
            message = nil
        } catch {
            message = String(describing: error)
        }
        isBusy = false
        await refresh()
    }

    func remove(_ rule: PortForwardRule) async {
        guard let adb, let serial else { return }
        isBusy = true
        do {
            try await adb.removePortForward(serial: serial, rule: rule)
            message = nil
        } catch {
            message = String(describing: error)
        }
        isBusy = false
        await refresh()
    }
}

struct PortForwardingSheet: View {
    @Environment(DeviceWorkspace.self) private var workspace

    var body: some View {
        PortForwardingContent(model: PortForwardingModel(
            adb: workspace.services.adbClient,
            serial: workspace.context.serial
        ))
    }
}

private struct PortForwardingContent: View {
    @State var model: PortForwardingModel

    var body: some View {
        @Bindable var model = model
        // Rules apply as they are added: closing takes nothing back, so the
        // button says Done, not Cancel.
        DHSheet(title: "Port Forwarding", width: 520, cancelTitle: "Done", footerNote: model.message) {
            DHSheetCard {
                if model.rules.isEmpty {
                    Text("No forwarding rules on this device.")
                        .foregroundStyle(.secondary)
                        .padding(DHSheetMetrics.rowInset)
                } else {
                    ForEach(model.rules) { rule in
                        HStack(spacing: 8) {
                            Text(rule.direction == .forward ? "Forward" : "Reverse")
                                .foregroundStyle(.secondary)
                                .frame(width: 60, alignment: .leading)
                            Text("\(rule.listen)  →  \(rule.target)")
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                            Spacer()
                            Button("Remove") { Task { await model.remove(rule) } }
                                .disabled(model.isBusy)
                        }
                        .padding(.horizontal, DHSheetMetrics.rowInset)
                        .frame(minHeight: DHSheetMetrics.rowHeight)
                    }
                }
            }
            DHSheetCard {
                DHSheetRow(title: "Direction:") {
                    Picker("Direction", selection: $model.direction) {
                        Text("Forward (Mac → device)").tag(PortForwardRule.Direction.forward)
                        Text("Reverse (device → Mac)").tag(PortForwardRule.Direction.reverse)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                DHSheetRow(title: model.listenLabel) {
                    DHSheetTextField(placeholder: "tcp:8080", text: $model.listen, width: 220)
                }
                DHSheetRow(title: model.targetLabel) {
                    DHSheetTextField(placeholder: "tcp:8080", text: $model.target, width: 220)
                }
            }
            HStack {
                if let problem = model.validation, model.listen != "tcp:" || model.target != "tcp:" {
                    Text(problem).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh") { Task { await model.refresh() } }
                    .disabled(model.isBusy)
                Button("Add Rule") { Task { await model.add() } }
                    .disabled(model.validation != nil || model.isBusy)
            }
        }
        .task { await model.refresh() }
    }
}
