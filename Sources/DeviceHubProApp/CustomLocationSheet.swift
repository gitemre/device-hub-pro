import SwiftUI
import DeviceHubProKit

/// The Location menu's Custom Location… sheet, the same on an emulator and a
/// simulator: a coordinate, or a route between two points walked at a speed.
/// A physical iPhone's sheet offers the coordinate only (`allowsRoute` off,
/// devicectl cannot play a route).
///
/// Coordinates are validated as typed (`CoordinateInput`: finite, on the
/// globe) and Apply stays disabled until they are. Failures show inline: the
/// window's error alert would sit behind the sheet.
struct CustomLocationSheet: View {
    enum Mode: String, CaseIterable, Identifiable {
        case coordinate = "Coordinate"
        case route = "Route"
        var id: String { rawValue }
    }

    let title: String
    var allowsRoute = true
    var initialLatitude = ""
    var initialLongitude = ""
    /// Applies a coordinate; returns the message to show when it failed.
    let onCoordinate: (Double, Double) async -> String?
    /// Plays a route between two points at a speed (m/s).
    var onRoute: ((GpsPoint, GpsPoint, Double) async -> String?)?

    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .coordinate
    @State private var latitude = ""
    @State private var longitude = ""
    @State private var endLatitude = ""
    @State private var endLongitude = ""
    @State private var speed = "5"
    @State private var applyError: String?
    @State private var isApplying = false

    var body: some View {
        VStack(spacing: 14) {
            Text(title)
                .font(.headline)
            if allowsRoute {
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Kind of location")
            }
            Grid(alignment: .trailing, horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Text(mode == .route ? "From latitude" : "Latitude")
                    TextField("", text: $latitude)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(mode == .route ? "Start latitude" : "Latitude")
                }
                GridRow {
                    Text(mode == .route ? "From longitude" : "Longitude")
                    TextField("", text: $longitude)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(mode == .route ? "Start longitude" : "Longitude")
                }
                if mode == .route {
                    GridRow {
                        Text("To latitude")
                        TextField("", text: $endLatitude)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("End latitude")
                    }
                    GridRow {
                        Text("To longitude")
                        TextField("", text: $endLongitude)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("End longitude")
                    }
                    GridRow {
                        Text("Speed (m/s)")
                        TextField("", text: $speed)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Speed in meters per second")
                    }
                }
            }
            if let message = applyError ?? validationMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canApply || isApplying)
            }
        }
        .padding(20)
        .frame(width: 320)
        .onAppear {
            if latitude.isEmpty { latitude = initialLatitude }
            if longitude.isEmpty { longitude = initialLongitude }
        }
        .onChange(of: mode) { applyError = nil }
    }

    private var start: CoordinateInput { CoordinateInput(latitude: latitude, longitude: longitude) }
    private var end: CoordinateInput { CoordinateInput(latitude: endLatitude, longitude: endLongitude) }

    /// A positive, finite number of meters per second.
    private var parsedSpeed: Double? {
        guard let value = Double(speed.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")),
              value.isFinite, value > 0
        else { return nil }
        return value
    }

    private var canApply: Bool {
        switch mode {
        case .coordinate: start.isValid
        case .route: start.isValid && end.isValid && parsedSpeed != nil
        }
    }

    /// What is wrong with the numbers, once something is typed.
    private var validationMessage: String? {
        switch mode {
        case .coordinate:
            guard !latitude.isEmpty || !longitude.isEmpty else { return nil }
            if case .invalid(let text) = start { return text }
            return nil
        case .route:
            if (!latitude.isEmpty || !longitude.isEmpty), case .invalid(let text) = start { return text }
            if (!endLatitude.isEmpty || !endLongitude.isEmpty), case .invalid(let text) = end { return text }
            if !speed.isEmpty, parsedSpeed == nil { return "Enter a speed above 0 meters per second." }
            return nil
        }
    }

    private func apply() {
        guard canApply else { return }
        isApplying = true
        applyError = nil
        Task {
            var failure: String?
            switch mode {
            case .coordinate:
                if case .valid(let lat, let lng) = start { failure = await onCoordinate(lat, lng) }
            case .route:
                if case .valid(let lat, let lng) = start, case .valid(let endLat, let endLng) = end, let speed = parsedSpeed {
                    failure = await onRoute?(
                        GpsPoint(latitude: lat, longitude: lng),
                        GpsPoint(latitude: endLat, longitude: endLng),
                        speed
                    )
                }
            }
            isApplying = false
            if let failure {
                applyError = failure
            } else {
                dismiss()
            }
        }
    }
}
