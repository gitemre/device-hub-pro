#!/usr/bin/env swift
// Converts THIRD_PARTY_NOTICES.md into the Credits.rtf that the standard
// About panel shows. Scripts/package-app.sh runs it for every package.
//
//   swift Scripts/make-credits.swift THIRD_PARTY_NOTICES.md Credits.rtf
//
// It understands the Markdown subset the notices file uses: `#`–`###`
// headings, paragraphs, `- ` bullets (with indented continuation lines),
// **bold**, `code` and [links](url); HTML comments are dropped. Text keeps
// the default colour so the panel can adapt it to dark mode.

import AppKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: swift Scripts/make-credits.swift <notices.md> <Credits.rtf>\n".utf8))
    exit(64)
}
let inputURL = URL(fileURLWithPath: arguments[1])
let outputURL = URL(fileURLWithPath: arguments[2])

let bodySize: CGFloat = 11
let bodyFont = NSFont.systemFont(ofSize: bodySize)
let boldFont = NSFont.boldSystemFont(ofSize: bodySize)
let codeFont = NSFont.monospacedSystemFont(ofSize: bodySize - 1, weight: .regular)

func paragraphStyle(indent: CGFloat = 0, spacingBefore: CGFloat = 0, bullet: Bool = false) -> NSParagraphStyle {
    let style = NSMutableParagraphStyle()
    style.paragraphSpacing = 4
    style.paragraphSpacingBefore = spacingBefore
    if bullet {
        style.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
        style.defaultTabInterval = indent
        style.firstLineHeadIndent = 0
        style.headIndent = indent
    }
    return style
}

/// Applies **bold**, `code` and [text](url) to one line of text.
func inline(_ text: String, font: NSFont, style: NSParagraphStyle) -> NSAttributedString {
    let result = NSMutableAttributedString()
    let base: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: style]
    // Longest-first alternation: links, bold, code.
    let pattern = try! NSRegularExpression(pattern: #"\[([^\]]+)\]\(([^)\s]+)\)|\*\*([^*]+)\*\*|`([^`]+)`"#)
    let ns = text as NSString
    var cursor = 0
    for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
        if match.range.location > cursor {
            result.append(NSAttributedString(
                string: ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)),
                attributes: base
            ))
        }
        if match.range(at: 1).location != NSNotFound {
            var attributes = base
            if let url = URL(string: ns.substring(with: match.range(at: 2))) {
                attributes[.link] = url
            }
            result.append(NSAttributedString(string: ns.substring(with: match.range(at: 1)), attributes: attributes))
        } else if match.range(at: 3).location != NSNotFound {
            var attributes = base
            attributes[.font] = boldFont
            result.append(NSAttributedString(string: ns.substring(with: match.range(at: 3)), attributes: attributes))
        } else {
            var attributes = base
            attributes[.font] = codeFont
            result.append(NSAttributedString(string: ns.substring(with: match.range(at: 4)), attributes: attributes))
        }
        cursor = match.range.location + match.range.length
    }
    if cursor < ns.length {
        result.append(NSAttributedString(string: ns.substring(from: cursor), attributes: base))
    }
    return result
}

let markdown: String
do {
    markdown = try String(contentsOf: inputURL, encoding: .utf8)
} catch {
    FileHandle.standardError.write(Data("make-credits: cannot read \(inputURL.path): \(error)\n".utf8))
    exit(1)
}

// Drop HTML comments, then group lines into blocks.
let withoutComments = markdown.replacingOccurrences(
    of: #"<!--[\s\S]*?-->"#,
    with: "",
    options: .regularExpression
)

enum Block {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(String)
}

var blocks: [Block] = []
var pending: [String] = []
var pendingIsBullet = false

func flush() {
    guard !pending.isEmpty else { return }
    let text = pending.joined(separator: " ")
    blocks.append(pendingIsBullet ? .bullet(text) : .paragraph(text))
    pending = []
    pendingIsBullet = false
}

for rawLine in withoutComments.components(separatedBy: "\n") {
    let line = rawLine.trimmingCharacters(in: .whitespaces)
    if line.isEmpty {
        flush()
        continue
    }
    if let hashes = line.firstIndex(where: { $0 != "#" }), line.hasPrefix("#"),
       line[hashes] == " " {
        flush()
        let level = line.distance(from: line.startIndex, to: hashes)
        blocks.append(.heading(level: level, text: String(line[line.index(after: hashes)...])))
        continue
    }
    if line.hasPrefix("- ") || line.hasPrefix("* ") {
        flush()
        pending = [String(line.dropFirst(2))]
        pendingIsBullet = true
        continue
    }
    pending.append(line)
}
flush()

let document = NSMutableAttributedString()
for (index, block) in blocks.enumerated() {
    if index > 0 {
        document.append(NSAttributedString(string: "\n", attributes: [.font: bodyFont]))
    }
    switch block {
    case .heading(let level, let text):
        let size: CGFloat = level == 1 ? 14 : (level == 2 ? 12.5 : bodySize)
        let style = paragraphStyle(spacingBefore: index == 0 ? 0 : (level == 3 ? 4 : 10))
        document.append(inline(text, font: .boldSystemFont(ofSize: size), style: style))
    case .paragraph(let text):
        document.append(inline(text, font: bodyFont, style: paragraphStyle()))
    case .bullet(let text):
        let style = paragraphStyle(indent: 14, bullet: true)
        document.append(NSAttributedString(string: "•\t", attributes: [.font: bodyFont, .paragraphStyle: style]))
        document.append(inline(text, font: bodyFont, style: style))
    }
}

do {
    let data = try document.data(
        from: NSRange(location: 0, length: document.length),
        documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
    )
    try data.write(to: outputURL, options: .atomic)
} catch {
    FileHandle.standardError.write(Data("make-credits: cannot write \(outputURL.path): \(error)\n".utf8))
    exit(1)
}
