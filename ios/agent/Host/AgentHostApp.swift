import SwiftUI
import os

// A tiny host app. The UI-test runner needs a target application; the spike also
// uses this one as a measurable surface: a full-screen colour that flips on every
// tap (tap latency), a text field (typing), and every orientation enabled.
@main
struct AgentHostApp: App {
    // A harmless line at launch and on each tap: Device Hub Pro's physical-iPhone log pane
    // (devicectl --console) shows it, which is how that bridge is checked live.
    fileprivate static let log = Logger(subsystem: "com.devicehubpro.agent.host", category: "host")

    init() {
        Self.log.notice("host app launched")
    }

    var body: some Scene {
        WindowGroup { HostView() }
    }
}

struct HostView: View {
    @State private var taps = 0
    @State private var text = ""
    // Wall-clock time (same phone clock as the runner) of the last tap the app received.
    @State private var lastTouch = 0.0
    // Where the last tap landed, normalized to the full screen in the current interface
    // orientation ("x,y"): lets a test tell how an input path maps its coordinates.
    @State private var touchPoint = "none"

    var body: some View {
        ZStack {
            GeometryReader { geometry in
                (taps % 2 == 0 ? Color.blue : Color.orange)
                    .gesture(SpatialTapGesture(coordinateSpace: .global).onEnded { value in
                        taps += 1
                        AgentHostApp.log.notice("tap \(taps)")
                        lastTouch = Date().timeIntervalSince1970
                        let size = geometry.frame(in: .global).size
                        touchPoint = String(format: "%.4f,%.4f", value.location.x / max(size.width, 1), value.location.y / max(size.height, 1))
                    })
            }
            .ignoresSafeArea()
            Text(touchPoint)
                .font(.caption2)
                .foregroundStyle(.white)
                .accessibilityIdentifier("touchPoint")
                .allowsHitTesting(false)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 60)
            VStack(spacing: 16) {
                Text("taps \(taps)")
                    .font(.largeTitle)
                    .foregroundStyle(.white)
                    .accessibilityIdentifier("tapCount")
                    .accessibilityValue(String(format: "%.4f", lastTouch))
                TextField("type here", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal)
                    .accessibilityIdentifier("field")
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
        }
    }
}
