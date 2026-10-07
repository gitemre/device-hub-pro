import SwiftUI
import DeviceHubProKit

/// Stopped-AVD detail: a large skin hero with a floor shadow, the device
/// name, and a single Start action. The card resolves live from the model so
/// the stage flips to the live view as soon as the device comes online.
struct AvdDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(DeviceWorkspace.self) private var workspace
    let avdName: String
    /// The AVD home the config is read from; nil for the model's
    /// (`ActiveDeviceContext.avdHome`, the emulator's own by default).
    var avdHome: URL?
    @State private var variantID = "default"

    private var card: AvdCard? {
        model.catalog.avdCards.first(where: { $0.name == avdName })
    }

    /// A stopped AVD without a skin: its vector body, planned like the live
    /// stage's (`DeviceCompositionPlanner.vector`) from its `config.ini`
    /// (`hw.lcd.width`/`height`, `hw.lcd.density`, the hinge count) and the
    /// displays it last reported. The screen is in the panel's natural
    /// orientation, so its cutout is upright. Square-cornered, without a
    /// hole, until the AVD has reported its shapes. Nil when the config
    /// declares no LCD size. Reads the file: call it off the main thread.
    nonisolated static func vectorPlan(avdName: String, avdHome: URL?, shapes: [DisplayShape]) -> DeviceComposition? {
        AvdScreenConfig.read(avdName: avdName, avdHome: avdHome)?.vectorPlan(shapes: shapes)
    }

    private var variant: SkinVariant? {
        card?.skin?.variants.first(where: { $0.id == variantID })
            ?? card?.skin?.preferredVariant
    }

    private var isOnline: Bool {
        guard let serial = card?.serial else { return false }
        return model.inventory.devices.first(where: { $0.serial == serial })?.isOnline ?? false
    }

    /// Another window or tab whose session shows this running emulator.
    private var otherOwner: DeviceWorkspace? {
        guard card?.isRunning == true, let serial = card?.serial,
              let owner = model.registry.owner(of: .android(serial)), owner !== workspace
        else { return nil }
        return owner
    }

    /// A running, online emulator that has no session here and no failure to
    /// report: it attaches by itself (`attachIfNeeded`), so the page shows a
    /// spinner rather than a Retry that has nothing to retry.
    private var isAwaitingAutoAttach: Bool {
        guard card?.isRunning == true, isOnline, otherOwner == nil, attachFailure == nil,
              let serial = card?.serial
        else { return false }
        return workspace.context.device != .android(serial)
    }

    /// A running, online emulator whose start or attach is still in flight.
    private var isAttachInFlight: Bool {
        guard card?.isRunning == true, isOnline else { return false }
        return model.avdIsBooting(avdName) || model.isBusy || isAwaitingAutoAttach
    }

    /// Attaches a running emulator that nothing shows yet, once per
    /// appearance of that state; a failure parks its reason (`attachFailure`)
    /// and the page offers Retry for it.
    private func attachIfNeeded() async {
        guard isAwaitingAutoAttach, !model.avdIsBooting(avdName), !model.isBusy,
              let serial = card?.serial,
              let device = model.inventory.devices.first(where: { $0.serial == serial })
        else { return }
        await workspace.mirror(device: device)
    }

    /// Why the last attach to this emulator failed, if it did.
    private var attachFailure: String? {
        guard let serial = card?.serial,
              let attach = workspace.mirror.mirrorAttach, attach.serial == serial
        else { return nil }
        return attach.failure
    }

    private var subtitle: String {
        var parts: [String] = []
        if let target = card?.osTitle {
            parts.append("\(target) Emulator")
        } else {
            parts.append("Emulator")
        }
        if isOnline {
            parts.append("Running")
        } else if card?.isRunning == true {
            parts.append("Booting")
        }
        // Stopped: no state word, like DH's "iOS 26.5 Simulator".
        return parts.joined(separator: " · ")
    }

    var body: some View {
        if let card {
            content(card: card)
        } else {
            Text("AVD not found")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func content(card: AvdCard) -> some View {
        StoppedStagePanel {
            AvdHero(avdName: avdName, variant: variant, hasSkin: card.skin != nil, avdHome: avdHome)
                .frame(height: SkinHero.height)

            if card.isFoldable {
                Picker("", selection: $variantID) {
                    Text("Open").tag("default")
                    Text("Cover").tag("closed")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Posture")
                .frame(width: 200)
            }

            VStack(spacing: 4) {
                Text(card.displayName)
                    .font(.system(size: ParityMetrics.stoppedNameFontSize, weight: ParityMetrics.stoppedNameFontWeight))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, ParityMetrics.stoppedHeroToNameGap)

            // A running, online emulator attaches by itself (the stage routes
            // it to the live view, which attaches on appearance), so this page
            // shows it only while an in-app start or attach is still in
            // flight (a spinner) or after one failed (its reason and Retry).
            if otherOwner != nil {
                Text("\(card.displayName) is open in another tab.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                    .padding(.top, 8)
                    .accessibilityIdentifier("avd-open-elsewhere")
            } else if let failure = attachFailure {
                Text(failure)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                    .padding(.top, 8)
            }

            HStack(spacing: 12) {
                if let owner = otherOwner {
                    Button("Show Tab") { model.registry.activate(owner.id) }
                        .stagePrimaryButton()
                } else if isAttachInFlight {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Attaching")
                } else {
                Button {
                    Task {
                        if card.isRunning, let serial = card.serial,
                           let device = model.inventory.devices.first(where: { $0.serial == serial })
                        {
                            await workspace.mirror(device: device)
                        } else {
                            await model.startAndMirror(avd: card.name, workspace: workspace)
                        }
                    }
                } label: {
                    StagePrimaryButtonLabel(card.isRunning && isOnline && attachFailure != nil ? "Retry" : "Start")
                }
                .stagePrimaryButton()
                .disabled(model.isBusy)
                }

                if card.serial != nil {
                    Button("Logs") {
                        Task {
                            await workspace.logcat.openLogcat(serial: card.serial ?? "")
                            workspace.window.selectInspectorTab(.diagnostics)
                        }
                    }
                    .glassButton()
                    .controlSize(.large)
                    .disabled(!isOnline || model.isBusy)
                }
            }
            .padding(.top, ParityMetrics.stoppedSubtitleToButtonGap)
        }
        .task(id: "\(card.serial ?? "")|\(isOnline)|\(card.isRunning)") { await attachIfNeeded() }
    }
}

/// An AVD's hero wherever the stage shows one (the stopped page, the booting
/// panel, and the live stage while no mirror runs): its skin's preview, or
/// for a skinless AVD its vector body, planned from its `config.ini` and the
/// displays it last reported (`AvdScreenConfig`).
///
/// The config is read off the main thread once per AVD and kept
/// (`SkinlessAvdScreens`), and the body is planned from it synchronously, so
/// a skinless AVD drawn again (a switch back to it, its booting panel after
/// its stopped page, its stage after Stop Mirror) shows its body on the
/// first frame. Until the first read answers the hero shows nothing: the
/// grey placeholder card is only for "nothing known", a config that
/// declares no screen. Each appearance reads the file again, so an edited
/// config shows without a relaunch.
struct AvdHero: View {
    @Environment(AppModel.self) private var model
    @Environment(DeviceWorkspace.self) private var workspace
    let avdName: String
    /// The skin variant drawn when the AVD has a skin.
    let variant: SkinVariant?
    /// The AVD has a skin; without one its vector body is drawn.
    let hasSkin: Bool
    /// The AVD home the config is read from; nil for the model's
    /// (`ActiveDeviceContext.avdHome`, the emulator's own by default).
    var avdHome: URL?

    /// What the hero draws.
    enum Content: Equatable {
        /// The skin's preview (`SkinHero` draws its placeholder card while
        /// it renders, and for a skin without variants).
        case skin(SkinVariant?)
        /// The skinless AVD's body; nil when its config declares no screen,
        /// which is "nothing known": the placeholder card.
        case body(DeviceComposition?)
        /// The skinless AVD's config is being read: nothing yet.
        case reading
    }

    var body: some View {
        let shapes = workspace.mirror.displayShapes.shapes(forAvd: avdName)
        let key = SkinlessAvdScreens.Key(avdName: avdName, avdHome: avdHome ?? workspace.context.avdHome)
        Group {
            switch Self.content(
                hasSkin: hasSkin,
                variant: variant,
                screen: hasSkin ? .unread : SkinlessAvdScreens.shared.lookup(key),
                shapes: shapes
            ) {
            case let .skin(variant):
                SkinHero(variant: variant, deviceShapes: shapes)
            case let .body(plan):
                SkinHero(variant: nil, deviceShapes: shapes, vector: plan)
            case .reading:
                Color.clear
            }
        }
        .task(id: hasSkin ? nil : key) {
            guard !hasSkin else { return }
            await SkinlessAvdScreens.shared.load(key)
        }
    }

    /// The skin when there is one; else the body planned from the config
    /// read so far and the displays the AVD last reported; else nothing
    /// while the config is read.
    static func content(
        hasSkin: Bool,
        variant: SkinVariant?,
        screen: SkinlessAvdScreens.Lookup,
        shapes: [DisplayShape]
    ) -> Content {
        if hasSkin { return .skin(variant) }
        switch screen {
        case .unread:
            return .reading
        case .undeclared:
            return .body(nil)
        case let .screen(config):
            return .body(config.vectorPlan(shapes: shapes))
        }
    }
}

/// What a skinless AVD's vector body is planned from in its `config.ini`:
/// the LCD size (`hw.lcd.width`/`height`), `hw.lcd.density` and the hinge
/// count.
struct AvdScreenConfig: Equatable, Sendable {
    let lcdSize: CGSize
    let lcdDensity: Double?
    let hingeCount: Int

    /// The AVD's screen as its config declares it; nil when it declares no
    /// LCD size. Reads the file: call it off the main thread.
    static func read(avdName: String, avdHome: URL?) -> AvdScreenConfig? {
        guard let size = AvdConfig.lcdSize(avdName: avdName, avdHome: avdHome) else { return nil }
        return AvdScreenConfig(
            lcdSize: size,
            lcdDensity: AvdConfig.lcdDensity(avdName: avdName, avdHome: avdHome),
            hingeCount: AvdConfig.hingeCount(avdName: avdName, avdHome: avdHome)
        )
    }

    /// The body (`AvdDetailView.vectorPlan`): the screen in the panel's
    /// natural orientation, so its cutout is upright, with `shapes`' corner
    /// and hole when one of them matches it.
    func vectorPlan(shapes: [DisplayShape]) -> DeviceComposition {
        DeviceCompositionPlanner.vector(
            screen: lcdSize,
            displays: shapes,
            fallbackDensityDpi: lcdDensity,
            hingeCount: hingeCount,
            quarterTurns: 0
        )
    }
}

/// The screens of the skinless AVDs the stage has drawn (`AvdHero`), read
/// from their `config.ini` off the main thread and kept for the process: a
/// few small values per AVD. Observed, so a hero redraws when its read
/// lands.
@MainActor
@Observable
final class SkinlessAvdScreens {
    static let shared = SkinlessAvdScreens()

    /// An AVD's config, by name and AVD home.
    struct Key: Hashable, Sendable {
        let avdName: String
        let avdHome: URL?
    }

    /// What is known of an AVD's screen.
    enum Lookup: Equatable {
        /// Not read yet.
        case unread
        /// Read: the config declares no LCD size.
        case undeclared
        case screen(AvdScreenConfig)
    }

    private var screens: [Key: Lookup] = [:]

    init() {}

    func lookup(_ key: Key) -> Lookup {
        screens[key] ?? .unread
    }

    /// Reads `key`'s config off the main thread and keeps what it declares,
    /// changing nothing a view reads when it is what was known.
    func load(_ key: Key) async {
        let screen = await Task.detached(priority: .userInitiated) {
            AvdScreenConfig.read(avdName: key.avdName, avdHome: key.avdHome)
        }.value
        let read: Lookup = screen.map(Lookup.screen) ?? .undeclared
        if screens[key] != read {
            screens[key] = read
        }
    }
}

/// Centers a stopped-style stage panel's group (hero, name, subtitle, Start)
/// vertically in the stage, as DH does (re-measured
/// live on our own `AQA probe Stage` simulator, unbooted): DH's group
/// centre lands within 0.25 pt of its own window's vertical centre — ours
/// used to pin the group 28 pt from the top instead. `content` supplies the
/// group's children in order (no leading top padding, no trailing spacer:
/// this wrapper owns both, via `GeometryReader` + `.frame(minHeight:)`,
/// which centers content shorter than the stage and falls back to a
/// top-anchored scroll once it is taller).
///
/// Not reproduced: DH's content extends *under* its 52 pt toolbar, so its
/// measured centre is its whole window's, landing ≈26 pt above the visible
/// stage's own centre; our SwiftUI toolbar reserves its own space, so this
/// centers in the stage's own height instead — the nearest equivalent
/// without adopting DH's toolbar-underlap.
struct StoppedStagePanel<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 14, content: content)
                    .padding(.horizontal, 24)
                    // DH centres the group on the whole window: its stage
                    // runs under the 52 pt toolbar band, ours starts below
                    // it, so the band's height is taken off the bottom
                    // (measured: DH 514.75 pt vs ours 540.5 before).
                    .padding(.bottom, ParityMetrics.stoppedStageToolbarBand)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

/// The booting and connecting stage, Device Hub's: no device and no name,
/// just a small spinner in the middle of the stage, and once the display is
/// being connected a caption under it (measured on DH 27.0: a 14 pt spinner
/// at the stage's centre, then "Connecting display…" in 12 pt secondary
/// under it, faded in; the spinner does not move when the caption arrives,
/// so the caption's line is always reserved). The group is centred like the
/// stopped page's (`StoppedStagePanel`).
struct BootSpinnerPanel: View {
    /// The line under the spinner; nil shows the spinner alone.
    let caption: String?
    /// What VoiceOver reads for the spinner (the boot phase).
    var accessibilityLabel: String = "Starting"

    var body: some View {
        StoppedStagePanel {
            VStack(spacing: ParityMetrics.bootSpinnerToCaptionGap) {
                ProgressView()
                    .controlSize(.small)
                Text(caption ?? " ")
                    .font(.system(size: ParityMetrics.bootCaptionFontSize))
                    .foregroundStyle(.secondary)
                    .opacity(caption == nil ? 0 : 1)
                    .animation(.easeIn(duration: 0.25), value: caption)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(caption ?? accessibilityLabel)
        }
    }
}

/// The stopped device's picture: the skin's preview, or for a device without
/// a skin its vector body, over Device Hub's own contact shadow (a thin
/// ellipse under the base, `ContactShadow`, not a halo). The stage's AVD
/// panels draw it through `AvdHero`; the live stage without a mirror draws a
/// phone's body with it too (`ConnectingView`). The preview renders off the
/// main thread (`SkinThumbnailCache`); meanwhile a skin's placeholder card
/// shows, or for a vector body an empty space of its shape.
struct SkinHero: View {
    let variant: SkinVariant?
    /// The displays the AVD last reported (`DisplayShapeLibrary`); the one
    /// matching the variant's screen gives the hero the device's own corner,
    /// the one its live stage clips to. Empty draws the skin's fallback.
    var deviceShapes: [DisplayShape] = []
    /// The body drawn when there is no `variant`: a skinless AVD's, planned
    /// from its `config.ini` (`AvdScreenConfig`), or a phone's, planned from
    /// its model's displays (`ConnectingView.phonePlan`). Nil with no
    /// variant is "nothing known": the placeholder card.
    var vector: DeviceComposition? = nil

    /// DH's stopped-page hero image: 183.5 x 200 pt,
    /// the device and its shadow together.
    static let height: CGFloat = ParityMetrics.stoppedHeroHeight
    /// The device inside it: 194 pt tall (measured on Device Hub 27.0's own
    /// stopped iPhone 17, 92 x 194), the last few points being the shadow's.
    static let deviceHeight: CGFloat = ParityMetrics.stoppedHeroDeviceHeight

    /// What the hero shows.
    enum Presentation {
        /// The rendered preview (the skin's, or the vector body's).
        case image(NSImage)
        /// A vector body still rendering: empty, at its aspect ratio, so
        /// the layout does not jump when it lands.
        case pending(aspectRatio: CGFloat)
        /// The placeholder card: a skin still rendering, or nothing known.
        case placeholder
    }

    var body: some View {
        Group {
            switch Self.presentation(
                variant: variant,
                deviceShapes: deviceShapes,
                vector: vector,
                cache: SkinThumbnailCache.shared
            ) {
            case let .image(image):
                // High interpolation: the preview is rendered `deviceHeight`
                // tall, and a wide one (the tablet's) is drawn smaller in a
                // narrower panel.
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .scaledToFit()
                    .frame(height: Self.deviceHeight)
                    .background(alignment: .bottom) { ContactShadow() }
            case let .pending(aspectRatio):
                Color.clear
                    .aspectRatio(aspectRatio, contentMode: .fit)
                    .frame(height: Self.deviceHeight)
            case .placeholder:
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(nsColor: .systemGray), Color(nsColor: .darkGray)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .aspectRatio(9 / 19, contentMode: .fit)
                    .overlay {
                        Image(systemName: "smartphone")
                            .font(.system(size: 56))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .frame(height: Self.deviceHeight)
                    .background(alignment: .bottom) { ContactShadow() }
            }
        }
        .frame(height: Self.height, alignment: .top)
    }

    /// The skin's preview when there is a `variant` (its placeholder card
    /// while it renders); else `vector`'s body; else the placeholder card.
    /// Reading it from a view body updates the view once a render lands.
    static func presentation(
        variant: SkinVariant?,
        deviceShapes: [DisplayShape],
        vector: DeviceComposition?,
        cache: SkinThumbnailCache
    ) -> Presentation {
        if let variant {
            let image = cache.image(
                for: variant,
                height: deviceHeight,
                deviceCornerRadius: deviceCornerRadius(for: variant, shapes: deviceShapes)
            )
            return image.map(Presentation.image) ?? .placeholder
        }
        guard let vector, vector.layoutSize.width > 0, vector.layoutSize.height > 0 else {
            return .placeholder
        }
        if let image = cache.vectorImage(for: vector, height: deviceHeight) {
            return .image(image)
        }
        return .pending(aspectRatio: vector.layoutSize.width / vector.layoutSize.height)
    }

    /// The device's corner, in layout units, for the screen `variant` shows:
    /// the reported display matching its size (a foldable's inner or cover
    /// panel); nil when none does.
    static func deviceCornerRadius(for variant: SkinVariant, shapes: [DisplayShape]) -> CGFloat? {
        guard !shapes.isEmpty, let display = variant.layout?.preferred else { return nil }
        return ScreenCornerPolicy.deviceRadius(
            of: DisplayShape.matching(frame: display.displaySize, in: shapes),
            displaySize: display.displaySize
        )
    }
}

/// Device Hub's shadow under a stopped device: a thin ellipse hugging the
/// base, a few points tall and a little wider than the device, fading out
/// within about ten points (measured on DH 27.0's stopped iPhone 17: nothing
/// at the sides above the base, 12% black three points under it, gone at
/// eight), not the wide halo the stopped page used to draw all round the
/// device. Sits behind the device, its centre line on the base.
struct ContactShadow: View {
    var body: some View {
        Ellipse()
            .fill(Color.black.opacity(ParityMetrics.contactShadowOpacity))
            .frame(height: ParityMetrics.contactShadowHeight)
            .padding(.horizontal, -ParityMetrics.contactShadowOverhang)
            .blur(radius: ParityMetrics.contactShadowBlur)
            .offset(y: ParityMetrics.contactShadowHeight / 2 - 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
