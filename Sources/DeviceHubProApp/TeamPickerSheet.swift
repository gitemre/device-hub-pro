import SwiftUI
import DeviceHubProKit

/// Asked once, only when the iPhone input runner is needed and the keychain
/// holds several Apple Development teams: lists them by the certificate's
/// organization name (never the identifier) and remembers the choice.
struct TeamPickerSheet: View {
    let request: TeamPickerRequest
    @Environment(\.dismiss) private var dismiss
    @State private var selection: SigningTeam?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose a development team")
                .font(.headline)
            Text("More than one Apple Development team is signed in on this Mac. Choose the one to sign the iPhone input helper with. Device Hub Pro remembers the choice.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List(request.teams, id: \.self, selection: $selection) { team in
                Text(team.organization)
            }
            .frame(minHeight: 120)
            HStack {
                Spacer()
                Button("Cancel") { finish(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("Choose") { finish(selection) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == nil)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { selection = request.teams.first }
    }

    private func finish(_ team: SigningTeam?) {
        request.answer(team)
        dismiss()
    }
}
