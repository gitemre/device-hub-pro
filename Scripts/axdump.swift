// axdump.swift — dump an app's accessibility tree (with the enhanced-UI nudge).
//
// Some apps (SwiftUI/Catalyst) build their AX tree lazily; setting
// AXEnhancedUserInterface on the application element usually forces it.
//
// Usage:
//   axdump <pid> [maxDepth] [--press <substring>] [--select <substring>]
//
// With --press, the first element whose role/title/description/help contains
// the substring (case-insensitive) receives AXPress instead of the dump.
// With --select, the matching element's nearest AXRow ancestor is selected
// (AXPress, then AXSelected) — for SwiftUI lists whose rows do not press
// directly.

import AppKit
import ApplicationServices
import Foundation

var args = Array(CommandLine.arguments.dropFirst())
guard let pidValue = args.first, let pid = pid_t(pidValue) else {
    FileHandle.standardError.write(Data("usage: axdump <pid> [maxDepth] [--press <substring>]\n".utf8))
    exit(2)
}
args.removeFirst()
var maxDepth = 8
var pressSubstring: String?
var selectSubstring: String?
while let arg = args.first {
    args.removeFirst()
    if arg == "--press" {
        pressSubstring = args.first
        if pressSubstring == nil { exit(2) }
        args.removeFirst()
    } else if arg == "--select" {
        selectSubstring = args.first
        if selectSubstring == nil { exit(2) }
        args.removeFirst()
    } else if let value = Int(arg) {
        maxDepth = value
    }
}

let app = AXUIElementCreateApplication(pid)
AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
Thread.sleep(forTimeInterval: 0.3)

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

func text(_ element: AXUIElement, _ name: String) -> String {
    if let value = attribute(element, name) as? String { return value }
    return ""
}

func role(_ element: AXUIElement) -> String { text(element, kAXRoleAttribute as String) }

func walk(_ element: AXUIElement, depth: Int) -> Bool {
    let line = "\(String(repeating: "  ", count: depth))\(role(element))"
        + (text(element, kAXTitleAttribute as String).isEmpty ? "" : " title=\"\(text(element, kAXTitleAttribute as String))\"")
        + (text(element, kAXDescriptionAttribute as String).isEmpty ? "" : " desc=\"\(text(element, kAXDescriptionAttribute as String))\"")
        + (text(element, kAXHelpAttribute as String).isEmpty ? "" : " help=\"\(text(element, kAXHelpAttribute as String))\"")
        + (text(element, kAXIdentifierAttribute as String).isEmpty ? "" : " id=\"\(text(element, kAXIdentifierAttribute as String))\"")
    print(line)

    if let needle = pressSubstring {
        let haystack = [text(element, kAXTitleAttribute as String),
                        text(element, kAXDescriptionAttribute as String),
                        text(element, kAXHelpAttribute as String),
                        text(element, kAXIdentifierAttribute as String),
                        role(element)].joined(separator: " ").lowercased()
        if haystack.contains(needle.lowercased()) {
            let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
            print("PRESS \(needle) on \(role(element)) → \(result == .success ? "ok" : "failed \(result.rawValue)")")
            return true
        }
    }

    if let needle = selectSubstring {
        let haystack = [text(element, kAXTitleAttribute as String),
                        text(element, kAXDescriptionAttribute as String),
                        text(element, kAXHelpAttribute as String),
                        text(element, kAXIdentifierAttribute as String),
                        role(element)].joined(separator: " ").lowercased()
        if haystack.contains(needle.lowercased()) {
            // Diagnostics: what can this element do?
            var actions: CFArray?
            if AXUIElementCopyActionNames(element, &actions) == .success,
               let names = actions as? [String] {
                print("actions on \(role(element)): \(names.joined(separator: ", "))")
            }
            var attributeNames: CFArray?
            if AXUIElementCopyAttributeNames(element, &attributeNames) == .success,
               let names = attributeNames as? [String] {
                print("attributes: \(names.joined(separator: ", "))")
            }
            // Walk up to the nearest row-like ancestor and select it.
            var current: AXUIElement? = element
            var depthUp = 0
            while let candidate = current, depthUp < 8 {
                let roleName = role(candidate)
                if roleName == "AXRow" || roleName == "AXCell" || roleName == "AXButton" || roleName == "AXRadioButton" {
                    var candidateActions: CFArray?
                    if AXUIElementCopyActionNames(candidate, &candidateActions) == .success,
                       let names = candidateActions as? [String] {
                        print("actions on \(roleName): \(names.joined(separator: ", "))")
                    }
                    for action in ["AXPress", "AXOpen", "AXConfirm", "AXPick"] {
                        if AXUIElementPerformAction(candidate, action as CFString) == .success {
                            print("SELECT \(needle) via \(action) on \(roleName)")
                            return true
                        }
                    }
                    // Outline rows select through the outline's AXSelectedRows.
                    var ancestor: AXUIElement? = candidate
                    var up = 0
                    while let node = ancestor, up < 6 {
                        if role(node) == "AXOutline" || role(node) == "AXList" || role(node) == "AXTable" {
                            let result = AXUIElementSetAttributeValue(
                                node,
                                kAXSelectedRowsAttribute as CFString,
                                [candidate] as CFArray
                            )
                            var selectedValue: CFTypeRef?
                            let readBack = AXUIElementCopyAttributeValue(candidate, kAXSelectedAttribute as CFString, &selectedValue)
                            print("SELECT \(needle) via AXSelectedRows on \(role(node)) → set=\(result == .success), rowSelected=\(readBack == .success ? String(describing: selectedValue) : "?")")
                            if result == .success { return true }
                        }
                        var parentValue: CFTypeRef?
                        guard AXUIElementCopyAttributeValue(node, kAXParentAttribute as CFString, &parentValue) == .success,
                              let parent = parentValue
                        else { break }
                        ancestor = (parent as! AXUIElement)
                        up += 1
                    }
                    let selected = AXUIElementSetAttributeValue(candidate, kAXSelectedAttribute as CFString, kCFBooleanTrue)
                    if selected == .success {
                        print("SELECT \(needle) via AXSelected on \(roleName)")
                        return true
                    }
                }
                var parentValue: CFTypeRef?
                guard AXUIElementCopyAttributeValue(candidate, kAXParentAttribute as CFString, &parentValue) == .success,
                      let parent = parentValue
                else { break }
                current = (parent as! AXUIElement)
                depthUp += 1
            }
            FileHandle.standardError.write(Data("axdump: matched \(needle) but no selectable ancestor\n".utf8))
            exit(3)
        }
    }

    guard depth < maxDepth else { return false }
    guard let children = attribute(element, kAXChildrenAttribute as String) as? [AXUIElement] else { return false }
    for child in children where walk(child, depth: depth + 1) {
        return true
    }
    return false
}

if let windows = attribute(app, kAXWindowsAttribute as String) as? [AXUIElement] {
    print("windows: \(windows.count)")
    for window in windows {
        if walk(window, depth: 0) { exit(0) }
    }
} else {
    print("windows: 0 (AX tree unavailable)")
    if walk(app, depth: 0) { exit(0) }
}
if pressSubstring != nil {
    FileHandle.standardError.write(Data("axdump: no element matched \"\(pressSubstring!)\"\n".utf8))
    exit(3)
}
