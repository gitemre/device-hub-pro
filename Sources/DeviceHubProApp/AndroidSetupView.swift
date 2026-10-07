import SwiftUI
import DeviceHubProKit

/// The "Set up Android tools" card: the empty stage of a Mac with no Android
/// SDK, and the sheet every dead end ("Android tools not found") opens. It
/// only reads `AndroidSetupModel`; what happens after the tools exist (the
/// first emulator) goes through `onCreateEmulator`.
struct AndroidSetupView: View {
    let model: AndroidSetupModel
    /// Where the card is: the stage shows "Don't show again", the sheet a
    /// Close button.
    var placement: Placement = .stage
    var onCreateEmulator: () -> Void = {}
    var onClose: () -> Void = {}

    enum Placement { case stage, sheet }

    static let width: CGFloat = 400

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: headerSymbol)
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(headerTint)
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)
            Text(title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            content
        }
        .frame(width: Self.width)
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
        .accessibilityElement(children: .contain)
    }

    private var title: String {
        switch model.phase {
        case .idle: "Set up Android tools"
        case .needsJava: "Java is needed"
        case .installing: "Installing Android tools"
        case .awaitingLicense: "Android SDK license"
        case .finished: "Android tools are ready"
        case .failed: "Setup did not finish"
        }
    }

    private var headerSymbol: String {
        switch model.phase {
        case .finished: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .awaitingLicense: "doc.text"
        default: "smartphone"
        }
    }

    private var headerTint: Color {
        switch model.phase {
        case .finished: .green
        case .failed: .orange
        default: .accentColor
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle: idle
        case .needsJava: needsJava
        case .installing: installing
        case .awaitingLicense(let prompt): license(prompt)
        case .finished: finished
        case .failed(let message): failed(message)
        }
    }

    // MARK: - Idle

    private var idle: some View {
        VStack(spacing: 14) {
            Text(AndroidSetupModel.explanation)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(Self.sizeNote(installRoot: model.installRootDisplay))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 8) {
                Button {
                    model.startInstall()
                } label: {
                    Text("Install Android Tools\u{2026}").frame(maxWidth: .infinity)
                }
                .glassProminentButton()
                .controlSize(.large)
                Button {
                    model.chooseSDKFolder()
                } label: {
                    Text("Locate SDK\u{2026}").frame(maxWidth: .infinity)
                }
                .glassButton()
                .controlSize(.large)
            }
            if let notice = model.notice {
                Text(notice)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.locateError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            studioLink
            footerLinks
        }
    }

    @ViewBuilder
    private var studioLink: some View {
        if model.studioIsInstalled {
            Button("I use Android Studio \u{2014} open it to set up its SDK") { model.openAndroidStudio() }
                .buttonStyle(.link)
                .font(.callout)
        } else {
            Button("I use Android Studio\u{2026}") { model.openAndroidStudioPage() }
                .buttonStyle(.link)
                .font(.callout)
        }
    }

    @ViewBuilder
    private var footerLinks: some View {
        switch placement {
        case .stage:
            Button("Don\u{2019}t show again") { model.dismissCard() }
                .buttonStyle(.link)
                .font(.caption)
                .foregroundStyle(.secondary)
        case .sheet:
            Button("Close") { onClose() }
                .keyboardShortcut(.cancelAction)
                .glassButton()
        }
    }

    // MARK: - Java

    private var needsJava: some View {
        VStack(spacing: 14) {
            Text(Self.javaNote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                model.startInstall(allowJavaDownload: true)
            } label: {
                Text("Download Java and Continue").frame(maxWidth: .infinity)
            }
            .glassProminentButton()
            .controlSize(.large)
            Button {
                model.reset()
            } label: {
                Text("Cancel").frame(maxWidth: .infinity)
            }
            .glassButton()
            .controlSize(.large)
        }
    }

    // MARK: - Installing

    private static let listedSteps: [AndroidToolsInstallStep] = [
        .downloadingJava, .downloadingCommandLineTools, .installingPlatformTools, .installingEmulator,
    ]

    private var visibleSteps: [AndroidToolsInstallStep] {
        Self.listedSteps.filter { step in
            step != .downloadingJava
                || model.completedSteps.contains(step) || model.progress?.step == step
        }
    }

    private var installing: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(visibleSteps, id: \.self) { step in
                    stepRow(step)
                }
            }
            if let progress = model.progress {
                VStack(alignment: .leading, spacing: 4) {
                    if let fraction = progress.fraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                    Text(statusLine(progress))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            Button {
                model.cancel()
            } label: {
                Text("Cancel").frame(maxWidth: .infinity)
            }
            .glassButton()
            .controlSize(.large)
        }
    }

    private func statusLine(_ progress: AndroidToolsInstallProgress) -> String {
        progress.detail.isEmpty ? progress.step.title : "\(progress.step.title) \u{00B7} \(progress.detail)"
    }

    private func stepRow(_ step: AndroidToolsInstallStep) -> some View {
        let done = model.completedSteps.contains(step)
        let current = model.progress?.step == step
        return HStack(spacing: 8) {
            Group {
                if done {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else if current {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "circle").foregroundStyle(.tertiary)
                }
            }
            .frame(width: 18, height: 18)
            Text(Self.rowTitle(step))
                .foregroundStyle(done || current ? .primary : .secondary)
            Spacer()
        }
    }

    /// The size claim on the first screen: the tools now, an image later.
    static func sizeNote(installRoot: String) -> String {
        "Install downloads Google\u{2019}s official Android tools (about 600 MB, plus a system image of about 1.5 GB "
            + "when you create an emulator) into \(installRoot), the folder Android Studio uses, so Studio shares them. "
            + "It needs no administrator password."
    }

    static let javaNote = "The Android tools run on Java, and this Mac has none. Device Hub Pro can download a free Java runtime "
        + "(about 50 MB, from adoptium.net) into its own folder. It does not change your system."

    /// The Java runtime, when needed, is fetched before this question, so the
    /// promise is about the Android packages only.
    static let licenseNote = "Google\u{2019}s Android SDK terms apply to the Android packages about to be downloaded. "
        + "They are not downloaded unless you accept."

    static func rowTitle(_ step: AndroidToolsInstallStep) -> String {
        switch step {
        case .downloadingJava: "Java runtime"
        case .downloadingCommandLineTools: "Command-line tools"
        case .installingPlatformTools: "Platform tools"
        case .installingEmulator: "Android Emulator"
        default: step.title
        }
    }

    // MARK: - License

    private func license(_ prompt: SDKLicensePrompt) -> some View {
        VStack(spacing: 12) {
            Text(Self.licenseNote)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(prompt.text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: 220)
            .background(
                Color.primary.opacity(0.04),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            HStack(spacing: 8) {
                Button {
                    model.declineLicense()
                } label: {
                    Text("Decline").frame(maxWidth: .infinity)
                }
                .glassButton()
                .controlSize(.large)
                Button {
                    model.acceptLicense()
                } label: {
                    Text("Accept and Install").frame(maxWidth: .infinity)
                }
                .glassProminentButton()
                .controlSize(.large)
            }
        }
    }

    // MARK: - Finished and failed

    private var finished: some View {
        VStack(spacing: 14) {
            Text("The next step is an emulator to run apps on. Device Hub Pro can download an Android system image and create one for you.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                onCreateEmulator()
            } label: {
                Text("Create an Emulator\u{2026}").frame(maxWidth: .infinity)
            }
            .glassProminentButton()
            .controlSize(.large)
            Button {
                model.reset()
                onClose()
            } label: {
                Text("Done").frame(maxWidth: .infinity)
            }
            .glassButton()
            .controlSize(.large)
        }
    }

    private func failed(_ message: String) -> some View {
        VStack(spacing: 14) {
            PlainFailureView(
                failure: PlainFailure.make(message, fallback: "Android setup couldn\u{2019}t finish."),
                centered: true
            )
            Text("What was already downloaded is kept, so trying again continues from there.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                model.reset()
                model.startInstall()
            } label: {
                Text("Try Again").frame(maxWidth: .infinity)
            }
            .glassProminentButton()
            .controlSize(.large)
            Button {
                model.reset()
            } label: {
                Text("Back").frame(maxWidth: .infinity)
            }
            .glassButton()
            .controlSize(.large)
        }
    }
}

/// The sheet form of the card: opened by the toolbar warning, the sidebar
/// row and the dead ends of New Emulator, Pair Nearby Device and the catalog.
struct AndroidSetupSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(DeviceWorkspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        AndroidSetupView(
            model: model.androidSetup,
            placement: .sheet,
            onCreateEmulator: {
                dismiss()
                Task { @MainActor in
                    // Let the sheet finish closing before the next one opens.
                    try? await Task.sleep(for: .milliseconds(350))
                    workspace.window.createFormFactor = .phone
                }
            },
            onClose: { dismiss() }
        )
        .padding(20)
        .interactiveDismissDisabled(model.androidSetup.isRunning)
    }
}

/// The empty stage of a Mac with no Android tools yet.
struct AndroidSetupStage: View {
    /// Whether the empty stage shows the card instead of "No Selection": the
    /// tools are missing and the card was not closed for good, or a setup run
    /// is on screen (running, failed, or finished and not yet dismissed).
    static func isShown(adbAvailable: Bool, dismissed: Bool, phase: AndroidSetupModel.Phase) -> Bool {
        if phase != .idle { return true }
        return !adbAvailable && !dismissed
    }

    @Environment(AppModel.self) private var model
    @Environment(DeviceWorkspace.self) private var workspace

    var body: some View {
        AndroidSetupView(
            model: model.androidSetup,
            placement: .stage,
            onCreateEmulator: { workspace.window.createFormFactor = .phone },
            onClose: {}
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
