import Foundation
import UIKit
import XCTest
import AVFoundation

// Endpoint handlers. Everything here runs on the main thread (the UI-test thread) and
// uses only public XCTest API.
enum AgentActions {
    static let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    static var stopRequested = false
    static var startedAt = Date()
    static var lastTapCall = 0.0

    /// Runs one action so that an XCTest issue (e.g. "no keyboard focus") becomes a 500
    /// answer instead of ending the long-running test.
    static func guarded(_ body: () -> HTTPResponse) -> HTTPResponse {
        var issues: [String] = []
        var result = HTTPResponse.error(500, "no result")
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        options.issueMatcher = { issue in issues.append(issue.compactDescription); return true }
        XCTExpectFailure("agent action", options: options) { result = body() }
        if !issues.isEmpty { return .error(500, issues.joined(separator: "; ")) }
        return result
    }

    static func interfaceAddresses() -> [[String: String]] {
        var out: [[String: String]] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return out }
        defer { freeifaddrs(head) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            if let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) || sa.pointee.sa_family == UInt8(AF_INET6) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    out.append(["name": String(cString: cur.pointee.ifa_name), "addr": String(cString: host)])
                }
            }
            p = cur.pointee.ifa_next
        }
        return out
    }

    static let springboardID = "com.apple.springboard"
    /// The runner's own bundle identifiers: an XCUIApplication for one of them hangs the runner.
    static let refusedPrefixes = ["com.devicehubpro.agent.uitests"]
    static func isRefused(_ id: String) -> Bool { refusedPrefixes.contains { id.hasPrefix($0) } }
    /// Overlay services that always report `runningForeground`: never a reference (a tap resolved
    /// against one waits on a snapshot that never comes). Measured on iOS 27.0.
    static let overlayIDs: Set<String> = ["com.apple.HangHUD"]

    /// One XCUIApplication per bundle id, kept: making one and asking its state is an XPC round trip.
    static var appCache: [String: XCUIApplication] = [:]
    static func app(_ id: String) -> XCUIApplication? {
        if isRefused(id) { return nil }
        if id == springboardID { return springboard }
        if let cached = appCache[id] { return cached }
        let made = XCUIApplication(bundleIdentifier: id)
        appCache[id] = made
        return made
    }

    /// The app that was the foreground reference last time (a hint, re-checked every time).
    static var lastForegroundRef: String?

    /// The last full scan of `refs` that found no foreground app (home screen): when it ran and
    /// for which list. Repeated taps within `emptyScanReuse` seconds use Springboard without
    /// scanning again; another refs list, or any hit, resets it.
    static var lastEmptyScan: (at: TimeInterval, refs: [String])?
    static let emptyScanReuse: TimeInterval = 1.0

    /// Which app the coordinates of a tap or swipe are resolved against. `ref` wins; else the
    /// first of `refs` in the foreground (the sticky one first); else Springboard.
    static func reference(_ body: [String: Any]) -> (app: XCUIApplication, id: String)? {
        if let id = body["ref"] as? String {
            guard let a = app(id) else { return nil }
            return (a, id)
        }
        if let refs = body["refs"] as? [String] {
            let usable = refs.filter { $0 != springboardID && !isRefused($0) && !overlayIDs.contains($0) }
            if let sticky = lastForegroundRef, usable.contains(sticky), let a = app(sticky), a.state == .runningForeground {
                return (a, sticky)
            }
            let now = ProcessInfo.processInfo.systemUptime
            if let scan = lastEmptyScan, scan.refs == usable, now - scan.at < emptyScanReuse {
                lastForegroundRef = nil
                return (springboard, springboardID)
            }
            for id in usable {
                if let a = app(id), a.state == .runningForeground {
                    lastForegroundRef = id
                    lastEmptyScan = nil
                    return (a, id)
                }
            }
            lastForegroundRef = nil
            lastEmptyScan = (ProcessInfo.processInfo.systemUptime, usable)
        }
        return (springboard, springboardID)
    }

    static func coordinate(_ ref: XCUIApplication, _ x: Double, _ y: Double) -> XCUICoordinate {
        ref.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0)).withOffset(CGVector(dx: x, dy: y))
    }

    static func milliseconds(_ from: Double, _ to: Double) -> Double { (to - from) * 1000 }

    static func number(_ d: [String: Any], _ k: String) -> Double? {
        if let n = d[k] as? NSNumber { return n.doubleValue }
        return nil
    }

    static func orientationName(_ o: UIDeviceOrientation) -> String {
        switch o {
        case .portrait: return "portrait"
        case .portraitUpsideDown: return "portraitUpsideDown"
        case .landscapeLeft: return "landscapeLeft"
        case .landscapeRight: return "landscapeRight"
        case .faceUp: return "faceUp"
        case .faceDown: return "faceDown"
        default: return "unknown"
        }
    }

    static func orientation(named n: String) -> UIDeviceOrientation? {
        switch n {
        case "portrait": return .portrait
        case "portraitUpsideDown": return .portraitUpsideDown
        case "landscapeLeft": return .landscapeLeft
        case "landscapeRight": return .landscapeRight
        case "faceUp": return .faceUp
        case "faceDown": return .faceDown
        default: return nil
        }
    }

    static func screenInfo() -> [String: Any] {
        let s = UIScreen.main
        return [
            "widthPoints": s.fixedCoordinateSpace.bounds.width,
            "heightPoints": s.fixedCoordinateSpace.bounds.height,
            "scale": s.scale,
            "nativeScale": s.nativeScale,
            "currentBoundsWidth": s.bounds.width,
            "currentBoundsHeight": s.bounds.height,
        ]
    }

    static func handle(_ req: HTTPRequest) -> HTTPResponse {
        guarded { handleUnguarded(req) }
    }

    static func handleUnguarded(_ req: HTTPRequest) -> HTTPResponse {
        let body = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any] ?? [:]
        switch (req.method, req.path) {
        case ("GET", "/status"):
            return .json([
                "ok": true,
                "uptimeSeconds": Date().timeIntervalSince(startedAt),
                "orientation": orientationName(XCUIDevice.shared.orientation),
                "volume": Double(AVAudioSession.sharedInstance().outputVolume),
                "iosVersion": UIDevice.current.systemVersion,
            ])

        case ("GET", "/screen"):
            var info = screenInfo()
            let f = springboard.frame
            info["springboardFrameWidth"] = f.width
            info["springboardFrameHeight"] = f.height
            let shot = XCUIScreen.main.screenshot().image
            info["screenshotWidthPixels"] = (shot.cgImage?.width ?? 0)
            info["screenshotHeightPixels"] = (shot.cgImage?.height ?? 0)
            info["screenshotWidthPoints"] = shot.size.width
            info["screenshotHeightPoints"] = shot.size.height
            return .json(info)

        case ("GET", "/ifaddrs"):  // spike only: lets the Mac probe the phone's LAN address
            return .json(["addresses": interfaceAddresses()])

        case ("POST", "/tap"):
            guard let x = number(body, "x"), let y = number(body, "y") else { return .error(400, "x, y required") }
            let m0 = CACurrentMediaTime()
            guard let ref = reference(body) else { return .error(400, "ref refused") }
            let target = coordinate(ref.app, x, y)
            let m1 = CACurrentMediaTime()
            let t0 = Date().timeIntervalSince1970  // phone clock, for the touch-delivery measurement
            defer { lastTapCall = t0 }
            if let d = number(body, "doubleTap"), d != 0 { target.doubleTap() }
            else if let hold = number(body, "hold"), hold > 0 { target.press(forDuration: hold) }
            else { target.tap() }
            let m2 = CACurrentMediaTime()
            return .json(["ok": true, "t0": t0, "ref": ref.id,
                          "timing": ["resolveMs": milliseconds(m0, m1), "actionMs": milliseconds(m1, m2)]])

        case ("POST", "/swipe"):
            guard let x1 = number(body, "x1"), let y1 = number(body, "y1"),
                  let x2 = number(body, "x2"), let y2 = number(body, "y2") else { return .error(400, "x1,y1,x2,y2 required") }
            let duration = max(number(body, "duration") ?? 0.3, 0.05)
            let dist = ((x2 - x1) * (x2 - x1) + (y2 - y1) * (y2 - y1)).squareRoot()
            let m0 = CACurrentMediaTime()
            guard let ref = reference(body) else { return .error(400, "ref refused") }
            let from = coordinate(ref.app, x1, y1), to = coordinate(ref.app, x2, y2)
            let m1 = CACurrentMediaTime()
            // Public API: a press of 0.05 s then a drag at the velocity that covers the distance in `duration`.
            from.press(forDuration: 0.05, thenDragTo: to,
                       withVelocity: XCUIGestureVelocity(rawValue: CGFloat(max(dist / duration, 1))),
                       thenHoldForDuration: 0)
            let m2 = CACurrentMediaTime()
            return .json(["ok": true, "ref": ref.id,
                          "timing": ["resolveMs": milliseconds(m0, m1), "actionMs": milliseconds(m1, m2)]])

        case ("POST", "/type"):
            guard let text = body["text"] as? String else { return .error(400, "text required") }
            let bundle = body["bundleId"] as? String
            if let bundle, isRefused(bundle) { return .error(400, "bundleId refused") }
            let app = bundle.flatMap { app($0) } ?? springboard
            // typeText raises an XCTest issue when nothing has keyboard focus; refuse first.
            if !app.keyboards.firstMatch.exists && !springboard.keyboards.firstMatch.exists {
                return .error(409, "no keyboard is showing")
            }
            app.typeText(text)
            return .json(["ok": true, "chars": text.count])

        case ("POST", "/button"):
            switch body["name"] as? String {
            case "home": XCUIDevice.shared.press(.home)
            case "volumeUp": XCUIDevice.shared.press(.volumeUp)
            case "volumeDown": XCUIDevice.shared.press(.volumeDown)
            default: return .error(400, "name must be home|volumeUp|volumeDown")
            }
            return .json(["ok": true])

        case ("POST", "/siri"):
            // Public XCUISiriService: presents Siri and, with a text, processes it as recognised
            // speech. A phone or an OS without it makes XCTest raise an issue, which `guarded`
            // answers as 500 (the Mac reports "unsupported").
            let text = (body["text"] as? String) ?? ""
            XCUIDevice.shared.siriService.activate(voiceRecognitionText: text)
            return .json(["ok": true])

        case ("POST", "/appSwitcher"):
            // Public XCUICoordinate gesture: a swipe up from the bottom edge to about the middle
            // of the screen, held there, which opens the App Switcher on a phone with the
            // gesture home indicator.
            let start = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.995))
            let end = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.8)
            return .json(["ok": true])

        case ("GET", "/orientation"):
            return .json(["value": orientationName(XCUIDevice.shared.orientation)])

        case ("POST", "/orientation"):
            guard let n = body["value"] as? String, let o = orientation(named: n) else { return .error(400, "value required") }
            XCUIDevice.shared.orientation = o
            return .json(["ok": true, "value": orientationName(XCUIDevice.shared.orientation)])

        case ("GET", "/screenshot"):
            let shot = XCUIScreen.main.screenshot()
            if req.query["format"] == "jpeg" {
                let q = Double(req.query["q"] ?? "0.6") ?? 0.6
                guard let d = shot.image.jpegData(compressionQuality: q) else { return .error(500, "jpeg failed") }
                return HTTPResponse(status: 200, contentType: "image/jpeg", body: d)
            }
            return HTTPResponse(status: 200, contentType: "image/png", body: shot.pngRepresentation)

        case ("POST", "/stop"):
            stopRequested = true
            return .json(["ok": true])

        // ---- measurement helpers (spike only) ----
        case ("POST", "/launch"):  // activate an app by bundle id (host app for measurements)
            guard let b = body["bundleId"] as? String else { return .error(400, "bundleId required") }
            guard let a = app(b) else { return .error(400, "bundleId refused") }
            a.activate()
            return .json(["ok": true])

        case ("GET", "/probe"):  // colour of one pixel in a fresh on-device screenshot (points)
            let x = Double(req.query["x"] ?? "0") ?? 0, y = Double(req.query["y"] ?? "0") ?? 0
            let shot = XCUIScreen.main.screenshot()
            guard let cg = shot.image.cgImage else { return .error(500, "no image") }
            let scale = Double(cg.width) / Double(shot.image.size.width)
            guard let px = cg.cropping(to: CGRect(x: x * scale, y: y * scale, width: 1, height: 1)) else { return .error(400, "out of range") }
            var rgba = [UInt8](repeating: 0, count: 4)
            let ctx = CGContext(data: &rgba, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            ctx?.draw(px, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return .json(["r": Int(rgba[0]), "g": Int(rgba[1]), "b": Int(rgba[2]),
                          "imageWidth": cg.width, "imageHeight": cg.height])

        case ("GET", "/foreground"):  // which of the given bundle ids is in the foreground (state 4)
            let ids = (req.query["ids"] ?? "").split(separator: ",").map(String.init)
            var front: [String] = []
            for id in ids where !isRefused(id) && id != springboardID && !overlayIDs.contains(id) {
                if let a = app(id), a.state == .runningForeground { front.append(id) }
            }
            return .json(["foreground": front])

        case ("GET", "/host"):  // read the host app's tap counter and text field
            guard let app = app(req.query["bundleId"] ?? "com.devicehubpro.agent.host") else { return .error(400, "bundleId refused") }
            let field = app.textFields["field"]
            let touchPoint = app.staticTexts["touchPoint"]
            let touchPointLabel = touchPoint.exists ? touchPoint.label : ""
            return .json(["tapCount": app.staticTexts["tapCount"].label,
                          "field": (field.value as? String) ?? "",
                          "fieldFrame": [field.frame.midX, field.frame.midY, field.frame.width, field.frame.height],
                          "touchTime": app.staticTexts["tapCount"].value as? String ?? "",
                          "touchPoint": touchPointLabel,
                          "state": app.state.rawValue])

        default:
            return .error(404, "not found")
        }
    }
}
