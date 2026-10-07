import SwiftUI
import DeviceHubProKit

/// Device ▸ Apply Profile: the profiles, then Save Current Settings as
/// Profile… and Manage Profiles…. Acts on the multi-selection when there is
/// one, else on the device shown.
struct ApplyProfileMenu: View {
    let model: AppModel?
    let workspace: DeviceWorkspace?

    var body: some View {
        Menu("Apply Profile") {
            ForEach(model?.settingsProfiles.profiles ?? []) { profile in
                Button(profile.name) {
                    Task { await model?.applyProfile(profile, in: workspace) }
                }
                .disabled(model?.canApplyProfile(in: workspace) != true)
            }
            Divider()
            Button("Save Current Settings as Profile…") {
                workspace?.window.deviceExtrasSheet = .saveProfile
            }
            .disabled(model?.canSaveCurrentProfile(in: workspace) != true)
            Button("Manage Profiles…") {
                workspace?.window.deviceExtrasSheet = .manageProfiles
            }
        }
    }
}

/// Names the profile that saves what the device shown reads now.
struct SaveProfileSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(DeviceWorkspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    private var readings: ProfileReadings? { model.currentProfileReadings(in: workspace) }

    private var draft: SettingsProfile? {
        readings.map { SettingsProfile.capturing($0, named: name) }
    }

    var body: some View {
        DHSheet(
            title: "Save Current Settings as Profile",
            actions: [
                DHSheetAction(
                    title: "Save",
                    isEnabled: model.settingsProfiles.isNameAvailable(name) && draft != nil,
                    isDefault: true
                ) {
                    if model.saveCurrentSettingsAsProfile(named: name) != nil { dismiss() }
                },
            ]
        ) {
            DHSheetCard {
                DHSheetRow(title: "Name:") {
                    DHSheetTextField(placeholder: "Profile name", text: $name)
                        .accessibilityLabel("Profile name")
                }
                DHSheetRow(title: "Saves:") {
                    Text(ProfileText.summary(draft) ?? "Nothing was read from the device")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 280, alignment: .trailing)
                        .padding(.vertical, 6)
                }
            }
        }
        .onAppear {
            if name.isEmpty {
                var n = model.settingsProfiles.userProfiles.count + 1
                while !model.settingsProfiles.isNameAvailable("Profile \(n)") { n += 1 }
                name = "Profile \(n)"
            }
        }
    }
}

/// Lists the profiles with their fields: Apply, Rename, Duplicate, Delete
/// (a built-in only Duplicate and Apply).
struct ManageProfilesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(DeviceWorkspace.self) private var workspace
    @State private var renamingID: String?
    @State private var draftName = ""
    @State private var deleting: SettingsProfile?

    var body: some View {
        let store = model.settingsProfiles
        DHSheet(
            title: "Manage Profiles", width: 520, cancelTitle: "Done",
            // Esc while a name is being edited drops the edit only.
            onCancel: renamingID == nil ? nil : { renamingID = nil }
        ) {
            ScrollView {
                DHSheetCard {
                    ForEach(store.profiles) { profile in
                        row(profile, store: store)
                    }
                }
            }
            .frame(maxHeight: 380)
        }
        .confirmationDialog(
            "Delete “\(deleting?.name ?? "")”?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { profile in
            Button("Delete", role: .destructive) { store.delete(id: profile.id) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The profile is removed; devices keep the settings they have.")
        }
    }

    private func row(_ profile: SettingsProfile, store: SettingsProfileStore) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                if renamingID == profile.id {
                    TextField("Name", text: $draftName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { commitRename(profile, store: store) }
                        .accessibilityLabel("New profile name")
                } else {
                    Text(profile.name).fontWeight(.medium)
                }
                Text(ProfileText.summary(profile) ?? "Changes nothing")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if renamingID == profile.id {
                Button("Done") { commitRename(profile, store: store) }
                    .disabled(!store.isNameAvailable(draftName, excluding: profile.id))
            } else {
                Button("Apply") { Task { await model.applyProfile(profile, in: workspace) } }
                    .disabled(!model.canApplyProfile(in: workspace))
                Menu {
                    if !profile.isBuiltIn {
                        Button("Rename…") {
                            draftName = profile.name
                            renamingID = profile.id
                        }
                    }
                    Button("Duplicate") { store.duplicate(id: profile.id) }
                    if !profile.isBuiltIn {
                        Divider()
                        Button("Delete…", role: .destructive) { deleting = profile }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("More for \(profile.name)")
            }
        }
        .padding(.horizontal, DHSheetMetrics.rowInset)
        .padding(.vertical, 8)
    }

    private func commitRename(_ profile: SettingsProfile, store: SettingsProfileStore) {
        if store.rename(id: profile.id, to: draftName) { renamingID = nil }
    }
}

enum ProfileText {
    /// "Appearance Dark · Text Size 200 % · Reduce Motion On"; nil for none.
    static func summary(_ profile: SettingsProfile?) -> String? {
        guard let profile, !profile.isEmpty else { return nil }
        return profile.fields.map { "\($0.title): \($0.value)" }.joined(separator: " · ")
    }
}
