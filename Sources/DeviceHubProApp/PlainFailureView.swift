import SwiftUI
import DeviceHubProKit

/// A failure as one plain sentence, with the tool's own output behind a
/// "Show Details" disclosure (collapsed). The sentence and the raw text come
/// from `PlainFailure.make`.
struct PlainFailureView: View {
    let failure: PlainFailure
    var summaryColor: Color = .secondary
    var centered = false
    var font: Font = .callout
    @State private var showsDetails = false

    var body: some View {
        VStack(alignment: centered ? .center : .leading, spacing: 6) {
            Text(failure.summary)
                .font(font)
                .foregroundStyle(summaryColor)
                .multilineTextAlignment(centered ? .center : .leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
            if let details = failure.details, !details.isEmpty {
                DisclosureGroup("Show Details", isExpanded: $showsDetails) {
                    ScrollView {
                        Text(details)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                    }
                    .frame(maxHeight: 110)
                    .background(
                        Color.primary.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                }
                .font(.caption)
            }
        }
    }
}
