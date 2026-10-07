import AppKit
import DeviceHubProKit
import SwiftUI

/// Identifies one annotation-editor presentation. Captured when a screenshot
/// is taken (the standalone save flow) and cleared when the editor applies
/// or cancels.
struct AnnotationEditRequest: Identifiable {
    let id = UUID()
    let png: Data
}

/// Sheet for annotating a captured screenshot before it is stored.
///
/// The image is drawn fitted into a fixed-size canvas with one scale for
/// both axes; annotation coordinates live in the canvas' display points, and
/// `AnnotationRenderer` converts them to image pixels with that one scale
/// (`imagePixelWidth / displayedWidth`, equal to the height ratio), so an
/// annotation placed on a feature lands on the same feature in the rendered
/// PNG. Redactions preview as the opaque fill the saved image gets.
/// Rendering runs off the main actor, and a failed render or save is shown
/// here — the window's alert would sit behind this sheet.
struct AnnotationEditorView: View {
    enum Tool: String, CaseIterable, Identifiable {
        case arrow
        case rectangle
        case text
        case blur

        var id: String { rawValue }

        var label: String {
            switch self {
            case .arrow: "Arrow"
            case .rectangle: "Rectangle"
            case .text: "Text"
            case .blur: "Redact"
            }
        }

        var symbol: String {
            switch self {
            case .arrow: "arrow.up.right"
            case .rectangle: "rectangle"
            case .text: "textformat"
            case .blur: "eye.slash"
            }
        }
    }

    let basePNG: Data

    @Environment(AppModel.self) private var model
    @Environment(DeviceWorkspace.self) private var workspace

    @State private var tool: Tool = .arrow
    @State private var color: Color = .red
    @State private var lineWidth: CGFloat = 4
    @State private var annotations: [Annotation] = []
    @State private var redoStack: [Annotation] = []
    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?
    @State private var displayedSize: CGSize = .zero
    @State private var textAnchor: CGPoint?
    @State private var textDraft = ""
    @State private var renderError: String?
    /// Rendering or saving is in flight: Apply is disabled until it ends.
    @State private var isApplying = false

    private let image: NSImage?
    private let pixelSize: CGSize

    static let swatches: [(name: String, color: Color)] = [
        ("Red", .red),
        ("Orange", .orange),
        ("Yellow", .yellow),
        ("Green", .green),
        ("Blue", .blue),
        ("Black", .black),
    ]

    init(basePNG: Data) {
        self.basePNG = basePNG
        if let rep = NSBitmapImageRep(data: basePNG),
           rep.pixelsWide > 0, rep.pixelsHigh > 0,
           let image = NSImage(data: basePNG) {
            self.image = image
            self.pixelSize = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        } else {
            self.image = nil
            self.pixelSize = .zero
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.94)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 18)
                    .padding(.top, 14)
                    .padding(.bottom, 10)

                canvasArea

                toolCapsule
                    .padding(.bottom, 16)
            }
        }
        .frame(
            width: ParityMetrics.annotationSheetWidth,
            height: ParityMetrics.annotationSheetHeight
        )
        .alert(
            "Add Text",
            isPresented: Binding(
                get: { textAnchor != nil },
                set: { if !$0 { textAnchor = nil } }
            )
        ) {
            TextField("Text", text: $textDraft)
            Button("Cancel", role: .cancel) {
                textAnchor = nil
                textDraft = ""
            }
            Button("Add") { commitText() }
        } message: {
            Text("The text is placed where you clicked.")
        }
        .alert(
            "Screenshot Not Saved",
            isPresented: Binding(
                get: { renderError != nil },
                set: { if !$0 { renderError = nil } }
            )
        ) {
            Button("OK") { renderError = nil }
        } message: {
            Text(renderError ?? "")
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Annotate Screenshot")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("\(Int(pixelSize.width)) × \(Int(pixelSize.height)) px")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
            }

            Spacer()

            Button("Cancel") {
                workspace.capture.cancelAnnotationEditing()
            }
            .glassButton()
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Cancel Annotations")

            Button("Apply") {
                apply()
            }
            .glassProminentButton()
            .keyboardShortcut(.defaultAction)
            .disabled(image == nil || isApplying)
            .accessibilityLabel("Apply Annotations")
        }
    }

    private var canvasArea: some View {
        GeometryReader { proxy in
            if let image {
                let fitted = fittedSize(in: proxy.size)
                canvas(for: image, fitted: fitted)
                    .frame(width: fitted.width, height: fitted.height)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                    )
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                    .onAppear { displayedSize = fitted }
                    .onChange(of: fitted) { _, newValue in displayedSize = newValue }
            } else {
                ContentUnavailableView(
                    "Screenshot unavailable",
                    systemImage: "photo.badge.exclamationmark",
                    description: Text("The captured PNG could not be decoded.")
                )
            }
        }
        .padding(.horizontal, ParityMetrics.annotationCanvasInset)
    }

    private func canvas(for image: NSImage, fitted: CGSize) -> some View {
        Canvas { context, size in
            context.draw(Image(nsImage: image), in: CGRect(origin: .zero, size: size))
            for annotation in annotations {
                draw(annotation, in: &context, isPreview: false)
            }
            if let preview = previewAnnotation {
                draw(preview, in: &context, isPreview: true)
            }
        }
        .contentShape(Rectangle())
        .gesture(dragGesture(fitted: fitted))
        .simultaneousGesture(
            SpatialTapGesture()
                .onEnded { value in
                    guard tool == .text else { return }
                    beginText(at: clamped(value.location, to: fitted))
                }
        )
    }

    private var toolCapsule: some View {
        HStack(spacing: 6) {
            ForEach(Tool.allCases) { candidate in
                toolButton(candidate)
            }

            capsuleDivider

            colorControls

            capsuleDivider

            widthControls

            capsuleDivider

            Button {
                undo()
            } label: {
                toolIcon("arrow.uturn.backward")
            }
            .buttonStyle(.plain)
            .disabled(annotations.isEmpty)
            .keyboardShortcut("z", modifiers: .command)
            .help("Undo (⌘Z)")
            .accessibilityLabel("Undo")

            Button {
                redo()
            } label: {
                toolIcon("arrow.uturn.forward")
            }
            .buttonStyle(.plain)
            .disabled(redoStack.isEmpty)
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .help("Redo (⇧⌘Z)")
            .accessibilityLabel("Redo")
        }
        .padding(.horizontal, ParityMetrics.annotationCapsulePadding)
        .padding(.vertical, 4)
        .liquidGlass(in: Capsule())
        .glassHairline(in: Capsule())
    }

    private var capsuleDivider: some View {
        Divider()
            .frame(height: 18)
    }

    private var colorControls: some View {
        HStack(spacing: 5) {
            ColorPicker("Color", selection: $color, supportsOpacity: false)
                .labelsHidden()
                .help("Color")
                .accessibilityLabel("Color")

            ForEach(Self.swatches, id: \.name) { swatch in
                Button {
                    color = swatch.color
                } label: {
                    Circle()
                        .fill(swatch.color)
                        .frame(
                            width: ParityMetrics.annotationSwatchSize,
                            height: ParityMetrics.annotationSwatchSize
                        )
                        .overlay(
                            Circle().strokeBorder(.white.opacity(0.65), lineWidth: 1)
                        )
                        .overlay(
                            Circle()
                                .strokeBorder(Color.accentColor, lineWidth: 2)
                                .opacity(color == swatch.color ? 1 : 0)
                        )
                        // Clicks land up to the neighbours (half the gap),
                        // not only on the 16 pt dot; the layout is unchanged.
                        .padding(ParityMetrics.annotationSwatchHitOutset)
                        .contentShape(Rectangle())
                        .padding(-ParityMetrics.annotationSwatchHitOutset)
                }
                .buttonStyle(.plain)
                .help(swatch.name)
                .accessibilityLabel(swatch.name)
            }
        }
    }

    private var widthControls: some View {
        HStack(spacing: 6) {
            Image(systemName: "lineweight")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            Slider(value: $lineWidth, in: 2...16, step: 1)
                .frame(width: ParityMetrics.annotationWidthSliderWidth)
                .accessibilityLabel("Stroke width")
                .accessibilityValue("\(Int(lineWidth))")

            Text("\(Int(lineWidth))")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .leading)
        }
    }

    private func toolButton(_ candidate: Tool) -> some View {
        Button {
            tool = candidate
            textAnchor = nil
            textDraft = ""
        } label: {
            toolIcon(candidate.symbol)
                .background(
                    Circle().fill(
                        tool == candidate
                            ? Color.primary.opacity(0.12)
                            : Color.clear
                    )
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(tool == candidate ? .primary : .secondary)
        .help(candidate.label)
        .accessibilityLabel(candidate.label)
    }

    private func toolIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: ParityMetrics.annotationToolIconSize, weight: .medium))
            .frame(
                width: ParityMetrics.annotationToolButtonSize,
                height: ParityMetrics.annotationToolButtonSize
            )
            .contentShape(Rectangle())
    }

    // MARK: - Gestures

    private func dragGesture(fitted: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard tool != .text else { return }
                if dragStart == nil {
                    dragStart = clamped(value.startLocation, to: fitted)
                }
                dragCurrent = clamped(value.location, to: fitted)
            }
            .onEnded { value in
                defer {
                    dragStart = nil
                    dragCurrent = nil
                }
                guard tool != .text, let start = dragStart else { return }
                let end = clamped(value.location, to: fitted)
                switch tool {
                case .arrow:
                    guard start.distance(to: end) >= 4 else { return }
                    commit(.arrow(from: start, to: end, color: rgba, width: lineWidth))
                case .rectangle:
                    let rect = CGRect(from: start, to: end)
                    guard rect.width >= 4, rect.height >= 4 else { return }
                    commit(.rectangle(rect, color: rgba, width: lineWidth, filled: false))
                case .blur:
                    let rect = CGRect(from: start, to: end)
                    guard rect.width >= 4, rect.height >= 4 else { return }
                    commit(.blur(rect))
                case .text:
                    break
                }
            }
    }

    private func beginText(at point: CGPoint) {
        textAnchor = point
        textDraft = ""
    }

    private func commitText() {
        let text = textDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty, let anchor = textAnchor {
            commit(.text(text, at: anchor, color: rgba, size: textSize))
        }
        textAnchor = nil
        textDraft = ""
    }

    // MARK: - Editing state

    private func commit(_ annotation: Annotation) {
        annotations.append(annotation)
        redoStack.removeAll()
    }

    private func undo() {
        guard let last = annotations.popLast() else { return }
        redoStack.append(last)
    }

    private func redo() {
        guard let next = redoStack.popLast() else { return }
        annotations.append(next)
    }

    /// Renders off the main actor (a full-resolution decode, composite and
    /// PNG encode), then saves; a failure of either is shown in this sheet.
    private func apply() {
        guard !isApplying else { return }
        isApplying = true
        let base = basePNG
        let annotations = annotations
        let scale = pixelScale
        Task {
            defer { isApplying = false }
            do {
                let png = try await AnnotationRenderer.renderInBackground(
                    base: base,
                    annotations: annotations,
                    scale: scale
                )
                if case .failed(let message) = workspace.capture.saveAnnotatedScreenshot(png) {
                    renderError = message
                }
            } catch {
                renderError = "\(error)"
            }
        }
    }

    // MARK: - Geometry

    /// The fit scale handed to the renderer: image pixels per editor point.
    /// `fittedSize` keeps the aspect ratio exactly, so the width ratio is
    /// the height ratio too.
    private var pixelScale: CGFloat {
        guard displayedSize.width > 0 else { return 1 }
        return pixelSize.width / displayedSize.width
    }

    private var textSize: CGFloat {
        max(16, lineWidth * 4)
    }

    private var rgba: RGBA {
        guard let converted = NSColor(color).usingColorSpace(.sRGB) else {
            return RGBA(red: 1, green: 0, blue: 0)
        }
        return RGBA(
            red: Double(converted.redComponent),
            green: Double(converted.greenComponent),
            blue: Double(converted.blueComponent)
        )
    }

    private var previewAnnotation: Annotation? {
        guard let start = dragStart, let current = dragCurrent, tool != .text else { return nil }
        switch tool {
        case .arrow:
            return .arrow(from: start, to: current, color: rgba, width: lineWidth)
        case .rectangle:
            let rect = CGRect(from: start, to: current)
            guard rect.width >= 4, rect.height >= 4 else { return nil }
            return .rectangle(rect, color: rgba, width: lineWidth, filled: false)
        case .blur:
            let rect = CGRect(from: start, to: current)
            guard rect.width >= 4, rect.height >= 4 else { return nil }
            return .blur(rect)
        case .text:
            return nil
        }
    }

    private func fittedSize(in container: CGSize) -> CGSize {
        Self.fittedSize(pixelSize: pixelSize, in: container)
    }

    /// The image fitted into `container` with one scale for both axes. Not
    /// rounded: rounding width and height separately skews the aspect, and
    /// the renderer's single scale (taken from the width) then misplaces
    /// annotations vertically — about 4 px at the bottom of a 1080×2400
    /// capture fitted to 523 pt.
    static func fittedSize(pixelSize: CGSize, in container: CGSize) -> CGSize {
        guard pixelSize.width > 0, pixelSize.height > 0,
              container.width > 0, container.height > 0 else { return .zero }
        let scale = min(container.width / pixelSize.width, container.height / pixelSize.height)
        return CGSize(width: pixelSize.width * scale, height: pixelSize.height * scale)
    }

    private func clamped(_ point: CGPoint, to size: CGSize) -> CGPoint {
        CGPoint(
            x: min(max(point.x, 0), size.width),
            y: min(max(point.y, 0), size.height)
        )
    }

    // MARK: - Canvas drawing

    private func draw(
        _ annotation: Annotation,
        in context: inout GraphicsContext,
        isPreview: Bool
    ) {
        switch annotation {
        case .arrow(let from, let to, let color, let width):
            context.stroke(
                arrowPath(from: from, to: to, width: width),
                with: .color(Color(rgba: color)),
                style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
            )
        case .rectangle(let rect, let color, let width, let filled):
            if filled {
                context.fill(Path(rect), with: .color(Color(rgba: color)))
            } else {
                context.stroke(
                    Path(rect),
                    with: .color(Color(rgba: color)),
                    lineWidth: width
                )
            }
        case .text(let string, let at, let color, let size):
            let text = Text(string)
                .font(.system(size: size))
                .foregroundStyle(Color(rgba: color))
            context.draw(text, at: at, anchor: .topLeading)
        case .blur(let rect):
            // The saved image gets an opaque fill (a blur or mosaic can be
            // reversed on text); the preview shows exactly that.
            context.fill(Path(rect), with: .color(Color(rgba: AnnotationRenderer.redactionColor)))
            if isPreview {
                // Only while dragging: the region being drawn stays visible
                // over dark content. Committed redactions look as saved.
                context.stroke(
                    Path(rect),
                    with: .color(.white.opacity(0.55)),
                    style: StrokeStyle(lineWidth: 1, dash: [5, 3])
                )
            }
        }
    }

    private func arrowPath(from: CGPoint, to: CGPoint, width: CGFloat) -> Path {
        var path = Path()
        path.move(to: from)
        path.addLine(to: to)

        let headLength = max(width * 3, 8)
        let spread = CGFloat.pi / 7
        let angle = atan2(to.y - from.y, to.x - from.x)
        for side in [angle + .pi - spread, angle + .pi + spread] {
            path.move(to: to)
            path.addLine(
                to: CGPoint(
                    x: to.x + cos(side) * headLength,
                    y: to.y + sin(side) * headLength
                )
            )
        }
        return path
    }
}

private extension CGRect {
    /// The rect spanning two drag points, normalized.
    init(from: CGPoint, to: CGPoint) {
        self.init(
            x: min(from.x, to.x),
            y: min(from.y, to.y),
            width: abs(to.x - from.x),
            height: abs(to.y - from.y)
        )
    }
}

private extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat {
        hypot(other.x - x, other.y - y)
    }
}

private extension Color {
    init(rgba: RGBA) {
        self.init(
            .sRGB,
            red: rgba.red,
            green: rgba.green,
            blue: rgba.blue,
            opacity: rgba.alpha
        )
    }
}
