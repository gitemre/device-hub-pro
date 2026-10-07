// activate-app.swift — bring a running app's existing windows to the front.
//
// Unlike `open -a`, this never asks LaunchServices to reopen the app, so it
// does not spawn a new main window; it activates the process and (optionally)
// raises one specific window by ID with the AX API.
//
// Usage:
//   activate-app <pid> [windowID]
//
// Exit status: 0 activated, 2 not running / no window, 3 AX failure.

import AppKit
import ApplicationServices
import Foundation

var args = Array(CommandLine.arguments.dropFirst())
guard let pidValue = args.first, let pid = pid_t(pidValue) else {
    FileHandle.standardError.write(Data("usage: activate-app <pid> [windowID]\n".utf8))
    exit(2)
}
args.removeFirst()
let wantedWindow = args.first.flatMap { Int($0) }

guard let app = NSRunningApplication(processIdentifier: pid) else {
    FileHandle.standardError.write(Data("activate-app: no process \(pid)\n".utf8))
    exit(2)
}

let activated = app.activate(options: [.activateAllWindows])
if !activated {
    // Fall back to the AX raise below even when activation reports false.
    FileHandle.standardError.write(Data("activate-app: NSRunningApplication.activate returned false\n".utf8))
}
Thread.sleep(forTimeInterval: 0.4)

if let wantedWindow {
    let axApp = AXUIElementCreateApplication(pid)
    var windowsValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsValue) == .success,
          let windows = windowsValue as? [AXUIElement]
    else {
        FileHandle.standardError.write(Data("activate-app: AX windows unavailable\n".utf8))
        exit(3)
    }
    for window in windows {
        var numberValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, "AXWindowNumber" as CFString, &numberValue) == .success,
           let number = numberValue as? Int, number == wantedWindow {
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            print("raised window \(wantedWindow)")
            exit(0)
        }
    }
    FileHandle.standardError.write(Data("activate-app: window \(wantedWindow) not found in AX\n".utf8))
    exit(3)
}
print("activated pid \(pid)")
