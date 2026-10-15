import SwiftUI

/// What the stage read from the window on its last layout pass. The stage
/// hands it to the sheet and the log as a value; nothing stores it, so it
/// cannot feed back into the layout it came from.
struct WindowReadings: Equatable {
    var size: CGSize
    var safeArea: EdgeInsets
    var horizontalSizeClass: UserInterfaceSizeClass?
    var verticalSizeClass: UserInterfaceSizeClass?
    /// The division regions with `.includeInactive`, as reported.
    var regions: [FoldRegion]
    var layout: SceneLayout
    /// Where the vertical bar is; nil when the window has top and bottom
    /// bars instead (the tall laptop window).
    var barEdge: HorizontalEdge?

    var sizeText: String {
        String(format: "%.0f × %.0f", size.width, size.height)
    }

    var sizeClassText: String {
        "\(Self.name(of: horizontalSizeClass)) / \(Self.name(of: verticalSizeClass))"
    }

    var regionText: String {
        guard let region = regions.first else { return "none" }
        let frame = String(format: "%.1f, %.1f, %.0f × %.0f", region.x, region.y, region.width, region.height)
        let extra = regions.count > 1 ? " (+\(regions.count - 1))" : ""
        return "\(frame) · \(region.isActive ? "active" : "inactive")\(extra)"
    }

    var barText: String {
        switch barEdge {
        case .leading: return "leading"
        case .trailing: return "trailing"
        case nil: return "none (top and bottom bars)"
        }
    }

    var safeAreaText: String {
        String(format: "%.0f, %.0f, %.0f, %.0f", safeArea.top, safeArea.leading, safeArea.bottom, safeArea.trailing)
    }

    /// The `layout` line of `readings.jsonl`.
    var json: [String: Any] {
        [
            "size": jsonSize(size),
            "sizeClass": "\(Self.letter(horizontalSizeClass))/\(Self.letter(verticalSizeClass))",
            "safeArea": jsonInsets(safeArea.top, safeArea.leading, safeArea.bottom, safeArea.trailing),
            "regions": regions.map { region -> [String: Any] in
                [
                    "frame": jsonRect(CGRect(x: region.x, y: region.y, width: region.width, height: region.height)),
                    "isActive": region.isActive,
                ]
            },
            "layout": layout.readingsJSON,
            "barEdge": barEdge.map { $0 == .leading ? "leading" : "trailing" } ?? NSNull(),
        ]
    }

    private static func name(of sizeClass: UserInterfaceSizeClass?) -> String {
        switch sizeClass {
        case .compact: return "compact"
        case .regular: return "regular"
        case nil: return "unspecified"
        @unknown default: return "unknown"
        }
    }

    private static func letter(_ sizeClass: UserInterfaceSizeClass?) -> String {
        switch sizeClass {
        case .compact: return "C"
        case .regular: return "R"
        case nil: return "?"
        @unknown default: return "?"
        }
    }
}

extension SceneLayout {
    /// One line for the Readings sheet.
    var readingsText: String {
        switch self {
        case let .single(horizonY):
            return String(format: "single · horizon %.1f", horizonY)
        case let .book(spineX, halfWidth, horizonY):
            return String(format: "book · spine %.1f ± %.0f · horizon %.1f", spineX, halfWidth, horizonY)
        case let .lidAndBase(creaseY, halfHeight):
            return String(format: "lid and base · crease %.1f ± %.0f", creaseY, halfHeight)
        }
    }

    var readingsJSON: [String: Any] {
        switch self {
        case let .single(horizonY):
            return ["kind": "single", "horizonY": jsonNumber(horizonY)]
        case let .book(spineX, halfWidth, horizonY):
            return ["kind": "book", "spineX": jsonNumber(spineX), "halfWidth": jsonNumber(halfWidth),
                    "horizonY": jsonNumber(horizonY)]
        case let .lidAndBase(creaseY, halfHeight):
            return ["kind": "lidAndBase", "creaseY": jsonNumber(creaseY), "halfHeight": jsonNumber(halfHeight)]
        }
    }
}

/// The live readings: the hinge as `onHingeChange` reports it, the day it
/// maps to, and the window the stage laid out last. Refreshed twice a
/// second, so the rate and the age of the last update keep moving at rest.
struct ReadingsSheet: View {
    let model: DayModel
    let window: WindowReadings

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                List {
                    Section("Hinge") {
                        row("Status", statusText)
                        row("Angle", model.hingeDegrees.map { String(format: "%.1f°", $0) } ?? "–")
                        row("Updates", "\(model.hingeUpdates)")
                        row("Rate", "\(model.updateRate()) per second")
                        row("Last update", ageText(now: context.date))
                    }
                    Section("Day") {
                        row("Shown angle", shownAngleText)
                        row("Progress", String(format: "%.3f", DayCycle.progress(angleDegrees: shownAngle)))
                        row("Phase", DayCycle.phase(progress: DayCycle.progress(angleDegrees: shownAngle)).title)
                        row("Time-Lapse", model.isTimeLapsing ? "playing" : "off")
                    }
                    Section("Window") {
                        row("Size", window.sizeText)
                        row("Size classes", window.sizeClassText)
                        row("Layout", window.layout.readingsText)
                        row("Division region", window.regionText)
                        row("Vertical bar", window.barText)
                        row("Safe area", window.safeAreaText)
                    }
                }
            }
            .navigationTitle("Readings")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .close) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var shownAngle: Double {
        model.shownAngle(regularWidth: window.horizontalSizeClass == .regular)
    }

    private var shownAngleText: String {
        let text = String(format: "%.1f°", shownAngle)
        return model.displayedAngle == nil ? "\(text) (likeliest for the window)" : text
    }

    private var statusText: String {
        switch model.availability {
        case .waiting: return "waiting for the first reading"
        case .absent: return "no hinge"
        case .present: return model.hinge.map { DayModel.name(of: $0.status) } ?? "–"
        }
    }

    private func ageText(now: Date) -> String {
        guard let last = model.lastHingeUpdate else { return "–" }
        return String(format: "%.1f s ago", max(now.timeIntervalSince(last), 0))
    }

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title) {
            Text(value)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        }
    }
}
