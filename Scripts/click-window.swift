// click-window.swift — post a click to a window, but only when it is frontmost.
//
// The parity skill's hard rule: synthetic input must never land in another
// app. This helper checks the front-to-back window order (CGWindowList) and
// refuses to click unless the target window is the first normal-layer window
// on screen.
//
// Usage:
//   click-window <windowID> <screenX> <screenY> [--right] [--double] [--hold ms]
//
// Exit status: 0 clicked, 2 target not frontmost / not found, 3 event error.

import AppKit
import CoreGraphics
import Foundation

var args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 3,
      let targetID = Int(args[0]),
      let x = Double(args[1]),
      let y = Double(args[2])
else {
    FileHandle.standardError.write(Data("usage: click-window <windowID> <x> <y> [--right] [--double] [--hold ms]\n".utf8))
    exit(2)
}
args.removeFirst(3)

var rightClick = false
var doubleClick = false
var holdMilliseconds = 0
while let flag = args.first {
    args.removeFirst()
    switch flag {
    case "--right": rightClick = true
    case "--double": doubleClick = true
    case "--hold":
        guard let value = args.first, let parsed = Int(value) else {
            FileHandle.standardError.write(Data("--hold needs milliseconds\n".utf8))
            exit(2)
        }
        args.removeFirst()
        holdMilliseconds = parsed
    default:
        FileHandle.standardError.write(Data("unknown flag \(flag)\n".utf8))
        exit(2)
    }
}

func frontmostNormalWindow() -> (id: Int, owner: String, name: String)? {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]]
    else { return nil }
    for entry in list {
        let layer = entry[kCGWindowLayer as String] as? Int ?? -1
        let alpha = entry[kCGWindowAlpha as String] as? Double ?? 0
        guard layer == 0, alpha > 0 else { continue }
        guard let id = entry[kCGWindowNumber as String] as? Int else { continue }
        return (
            id: id,
            owner: entry[kCGWindowOwnerName as String] as? String ?? "?",
            name: entry[kCGWindowName as String] as? String ?? ""
        )
    }
    return nil
}

guard let front = frontmostNormalWindow() else {
    FileHandle.standardError.write(Data("click-window: no on-screen normal-layer window\n".utf8))
    exit(2)
}
guard front.id == targetID else {
    FileHandle.standardError.write(Data(
        "click-window: refusing to click — frontmost is id=\(front.id) \"\(front.owner) — \(front.name)\", target is \(targetID)\n".utf8
    ))
    exit(2)
}

let point = CGPoint(x: x, y: y)
let source = CGEventSource(stateID: .hidSystemState)
let button: CGMouseButton = rightClick ? .right : .left
let downType: CGEventType = rightClick ? .rightMouseDown : .leftMouseDown
let upType: CGEventType = rightClick ? .rightMouseUp : .leftMouseUp
let clickCount = doubleClick ? 2 : 1

for count in 1...clickCount {
    guard let down = CGEvent(mouseEventSource: source, mouseType: downType, mouseCursorPosition: point, mouseButton: button),
          let up = CGEvent(mouseEventSource: source, mouseType: upType, mouseCursorPosition: point, mouseButton: button)
    else {
        FileHandle.standardError.write(Data("click-window: could not create events\n".utf8))
        exit(3)
    }
    down.setIntegerValueField(.mouseEventClickState, value: Int64(count))
    up.setIntegerValueField(.mouseEventClickState, value: Int64(count))
    down.post(tap: .cghidEventTap)
    if holdMilliseconds > 0 {
        Thread.sleep(forTimeInterval: Double(holdMilliseconds) / 1000.0)
    } else {
        Thread.sleep(forTimeInterval: 0.03)
    }
    up.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.05)
}

print("clicked id=\(targetID) at (\(Int(x)),\(Int(y)))\(rightClick ? " right" : "")\(doubleClick ? " double" : "")")
