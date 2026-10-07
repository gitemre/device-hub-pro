import SwiftUI

/// One page: a header, then the registry's sections with a row each. A row
/// that changes flashes and shows when it changed.
struct VerifierView: View {
    @ObservedObject var model: VerifierModel

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.accessibilityShowButtonShapes) private var buttonShapes

    private var snapshot: EnvironmentSnapshot {
        EnvironmentSnapshot(
            dark: colorScheme == .dark,
            textSizeIndex: DynamicTypeSize.allCases.firstIndex(of: dynamicTypeSize) ?? 3,
            increasedContrast: colorSchemeContrast == .increased,
            reduceMotion: reduceMotion,
            reduceTransparency: reduceTransparency,
            voiceOver: voiceOver,
            buttonShapes: buttonShapes
        )
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    header
                }
                ForEach(Registry.sections) { section in
                    Section(section.title) {
                        ForEach(section.rows) { row in
                            RowView(
                                row: row,
                                reading: model.readings[row.id],
                                changedAt: model.changedAt[row.id],
                                reduceMotion: reduceMotion,
                                action: model.actionAvailable(for: row.id) ? { model.runAction(for: row.id) } : nil
                            )
                        }
                    }
                }
            }
            .navigationTitle("Device Hub Pro Verifier")
        }
        .onChange(of: snapshot, initial: true) { _, snapshot in
            model.environmentChanged(snapshot)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.system)
                .font(.subheadline.weight(.semibold))
            Text("Reads and shows; never changes a setting. Every change is written to Documents/\(ReadingsDocument.fileName).")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let failure = model.writeFailure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Materials turn opaque by themselves under Reduce Transparency.
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct RowView: View {
    let row: VerifierRow
    let reading: Reading?
    let changedAt: Date?
    let reduceMotion: Bool
    let action: (() -> Void)?

    @State private var flashing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.title)
                    .font(.headline)
                Spacer()
                Text(row.observes.tag)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(row.observes == .note ? .orange : .secondary)
            }
            Text(reading?.value ?? "Reading…")
                .font(.body.monospacedDigit())
                .foregroundStyle(reading == nil ? .secondary : .primary)
                .textSelection(.enabled)
            if let changedAt {
                Text("Changed at \(Readings.clock(changedAt))")
                    .font(.caption)
                    .foregroundStyle(.tint)
            }
            Text(row.source)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(row.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let action, let label = row.action {
                Button(label, action: action)
                    .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 2)
        .listRowBackground(flashing ? Color.accentColor.opacity(0.18) : nil)
        .accessibilityElement(children: .combine)
        .onChange(of: changedAt) { _, _ in
            flash()
        }
    }

    private func flash() {
        flashing = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            if reduceMotion {
                flashing = false
            } else {
                withAnimation(.easeOut(duration: 0.4)) { flashing = false }
            }
        }
    }
}
