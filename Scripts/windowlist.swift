// windowlist.swift — list on-screen windows for the Device Hub Pro parity harness.
//
// Build (the harness does this automatically):
//   swiftc Scripts/windowlist.swift -o /tmp/windowlist
//
// Usage:
//   windowlist [owner-substring]
//
// Prints one tab-separated line per on-screen window:
//   id  owner  name  layer  onscreen  x  y  width  height  pid
//
// `id` is the CGWindowNumber used by `screencapture -x -o -l <id>`; bounds are
// in screen points. The harness filters owner == "DeviceHubPro" and layer == 0 and
// picks the largest window (the compact mirror floats on layer 3 and is thus
// never selected). Only CoreGraphics/Foundation are used.

import CoreGraphics
import Foundation

let arguments = CommandLine.arguments
let nameFilter = arguments.count > 1 ? arguments[1] : ""

let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
    FileHandle.standardError.write(Data("windowlist: CGWindowListCopyWindowInfo failed\n".utf8))
    exit(1)
}

for window in list {
    let windowOwner = window[kCGWindowOwnerName as String] as? String ?? ""
    if !nameFilter.isEmpty && !windowOwner.localizedCaseInsensitiveContains(nameFilter) { continue }

    let id = (window[kCGWindowNumber as String] as? NSNumber)?.intValue ?? -1
    let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.intValue ?? -1
    let name = window[kCGWindowName as String] as? String ?? "-"
    let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1
    let onscreen = (window[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true ? 1 : 0
    let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let x = (bounds["X"] as? NSNumber)?.doubleValue ?? 0
    let y = (bounds["Y"] as? NSNumber)?.doubleValue ?? 0
    let width = (bounds["Width"] as? NSNumber)?.doubleValue ?? 0
    let height = (bounds["Height"] as? NSNumber)?.doubleValue ?? 0

    print("\(id)\t\(windowOwner)\t\(name)\t\(layer)\t\(onscreen)\t\(Int(x.rounded()))\t\(Int(y.rounded()))\t\(Int(width.rounded()))\t\(Int(height.rounded()))\t\(pid)")
}
