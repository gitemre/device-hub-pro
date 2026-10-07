import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Hand-built binary fixtures for the APK resource parsers: `resources.arsc`
/// tables, compiled `<adaptive-icon>` XML and their string pools, plus small
/// generated rasters. Shared by `ApkIconTests` (end to end through a real zip)
/// and `ApkResourceParsingTests` (the parsers on raw bytes).
enum ApkFixture {
    /// One entry of the synthetic `resources.arsc` tables: a file path the
    /// resource names, a reference to another resource, or a color. `density`
    /// is the raw `ResTable_config` density of the type chunk the entry lives
    /// in.
    struct Entry {
        enum Value {
            case file(String)
            case reference(UInt32)
            case color(UInt32)
        }

        let id: UInt32
        let density: Int
        let value: Value
    }

    /// An `android:drawable` attribute value in a compiled adaptive-icon XML.
    enum Drawable {
        case reference(UInt32)
        case color(UInt32)
        case file(String)
    }

    /// Builds a minimal `resources.arsc` by hand: the global string pool, one
    /// package (id 0x7f) and one type chunk per type/density pair. Type and
    /// key name pools are omitted because the reader resolves resources by ID
    /// and never reads names. `sparse` and `offset16` select the type chunk's
    /// entry offset encoding, `utf16` the string pool encoding.
    static func resourceTable(
        _ entries: [Entry],
        sparse: Bool = false,
        offset16: Bool = false,
        utf16: Bool = false
    ) -> Data {
        var paths: [String] = []
        for entry in entries {
            if case .file(let path) = entry.value, !paths.contains(path) {
                paths.append(path)
            }
        }
        let (pool, stringIndex) = stringPool(paths, utf16: utf16)

        var packageBody = Data()
        let byType = Dictionary(grouping: entries) { UInt8(($0.id >> 16) & 0xFF) }
        for typeId in byType.keys.sorted() {
            let typeEntries = byType[typeId]!
            let byDensity = Dictionary(grouping: typeEntries) { $0.density }
            for density in byDensity.keys.sorted() {
                packageBody.append(typeChunk(
                    typeId: typeId,
                    density: density,
                    entries: byDensity[density]!,
                    stringIndex: stringIndex,
                    sparse: sparse,
                    offset16: offset16
                ))
            }
        }

        var table = Data()
        table.appendU16(0x0002)
        table.appendU16(12)
        table.appendU32(UInt32(12 + pool.count + 288 + packageBody.count))
        table.appendU32(1)
        table.append(pool)
        table.append(packageChunk(packageBody))
        return table
    }

    /// A `RES_STRING_POOL_TYPE` chunk for `strings` plus each string's index.
    /// Lengths use the one-unit prefix when they fit and the two-unit form
    /// (high bit set) when they do not, exactly as aapt2 writes them.
    /// `utf16` selects the older pool encoding.
    static func stringPool(
        _ strings: [String],
        utf16: Bool = false
    ) -> (data: Data, index: [String: Int]) {
        var index: [String: Int] = [:]
        var offsets = Data()
        var contents = Data()
        for (position, string) in strings.enumerated() {
            index[string] = position
            offsets.appendU32(UInt32(contents.count))
            if utf16 {
                let units = Array(string.utf16)
                if units.count > 0x7FFF {
                    contents.appendU16(UInt16(0x8000 | (units.count >> 16)))
                    contents.appendU16(UInt16(units.count & 0xFFFF))
                } else {
                    contents.appendU16(UInt16(units.count))
                }
                for unit in units {
                    contents.appendU16(unit)
                }
                contents.appendU16(0)
            } else {
                appendUTF8Length(string.utf16.count, to: &contents) // UTF-16 length
                appendUTF8Length(string.utf8.count, to: &contents) // UTF-8 length
                contents.append(contentsOf: string.utf8)
                contents.append(0)
            }
        }
        // Chunks are 4-byte aligned.
        while contents.count % 4 != 0 {
            contents.append(0)
        }

        let headerSize = 28
        var pool = Data()
        pool.appendU16(0x0001)
        pool.appendU16(UInt16(headerSize))
        pool.appendU32(UInt32(headerSize + offsets.count + contents.count))
        pool.appendU32(UInt32(strings.count))
        pool.appendU32(0) // style count
        pool.appendU32(utf16 ? 0 : 0x100) // string encoding flag
        pool.appendU32(UInt32(headerSize + offsets.count)) // strings start
        pool.appendU32(0) // styles start
        pool.append(offsets)
        pool.append(contents)
        return (pool, index)
    }

    private static func appendUTF8Length(_ length: Int, to data: inout Data) {
        if length > 0x7F {
            data.append(UInt8(0x80 | (length >> 8)))
            data.append(UInt8(length & 0xFF))
        } else {
            data.append(UInt8(length))
        }
    }

    /// One `RES_TABLE_TYPE_TYPE` chunk for a type/density pair; entries are
    /// written in entry-index order with the requested offset encoding.
    /// `entryCount` overrides the declared count (dense chunks default to the
    /// highest index + 1).
    static func typeChunk(
        typeId: UInt8,
        density: Int,
        entries: [Entry],
        stringIndex: [String: Int],
        sparse: Bool = false,
        offset16: Bool = false,
        entryCount declaredCount: Int? = nil
    ) -> Data {
        let sorted = entries.sorted { ($0.id & 0xFFFF) < ($1.id & 0xFFFF) }
        var entryData = Data()
        var offsets: [(index: UInt16, offset: Int)] = []
        for entry in sorted {
            offsets.append((UInt16(entry.id & 0xFFFF), entryData.count))
            entryData.append(self.entry(entry, stringIndex: stringIndex))
        }

        let entryCount = declaredCount
            ?? (sparse ? offsets.count : Int(offsets.map(\.index).max() ?? 0) + 1)
        let offsetSize = offset16 ? 2 : 4
        let headerSize = 20 + 64
        let entriesStart = headerSize + entryCount * offsetSize

        var offsetData = Data()
        if sparse {
            for (index, offset) in offsets {
                offsetData.appendU16(index)
                offsetData.appendU16(UInt16(offset / 4))
            }
        } else {
            let byIndex = Dictionary(uniqueKeysWithValues: offsets.map { ($0.index, $0.offset) })
            for index in 0..<entryCount {
                let offset = byIndex[UInt16(index)]
                if offset16 {
                    offsetData.appendU16(offset.map { UInt16($0 / 4) } ?? 0xFFFF)
                } else {
                    offsetData.appendU32(offset.map(UInt32.init) ?? 0xFFFF_FFFF)
                }
            }
        }

        var chunk = Data()
        chunk.appendU16(0x0201)
        chunk.appendU16(UInt16(headerSize))
        chunk.appendU32(UInt32(headerSize + offsetData.count + entryData.count))
        chunk.append(typeId)
        chunk.append(sparse ? 0x01 : (offset16 ? 0x02 : 0x00))
        chunk.appendU16(0)
        chunk.appendU32(UInt32(entryCount))
        chunk.appendU32(UInt32(entriesStart))
        chunk.append(config(density: density))
        chunk.append(offsetData)
        chunk.append(entryData)
        return chunk
    }

    /// A `ResTable_entry` followed by its `Res_value`.
    static func entry(_ entry: Entry, stringIndex: [String: Int]) -> Data {
        let dataType: UInt8
        let data: UInt32
        switch entry.value {
        case .file(let path):
            dataType = 0x03 // TYPE_STRING
            data = UInt32(stringIndex[path] ?? 0)
        case .reference(let id):
            dataType = 0x01 // TYPE_REFERENCE
            data = id
        case .color(let color):
            dataType = 0x1C // TYPE_INT_COLOR_ARGB8
            data = color
        }

        var bytes = Data()
        bytes.appendU16(8) // entry header size
        bytes.appendU16(0) // entry flags
        bytes.appendU32(0) // key
        bytes.appendU16(8) // value size
        bytes.append(0) // res0
        bytes.append(dataType)
        bytes.appendU32(data)
        return bytes
    }

    /// A zeroed 64-byte `ResTable_config` with only the density qualifier set.
    static func config(density: Int) -> Data {
        var config = Data(repeating: 0, count: 64)
        config[0] = 64
        config[14] = UInt8(density & 0xFF)
        config[15] = UInt8((density >> 8) & 0xFF)
        return config
    }

    /// A `RES_TABLE_PACKAGE_TYPE` chunk wrapping `body`; the type and key
    /// string offsets stay zero because the reader never follows them.
    static func packageChunk(_ body: Data) -> Data {
        var chunk = Data()
        chunk.appendU16(0x0200)
        chunk.appendU16(288)
        chunk.appendU32(UInt32(288 + body.count))
        chunk.appendU32(0x7F) // package id
        var name = Array("com.example.app".utf16)
        name.append(contentsOf: repeatElement(0, count: 128 - name.count))
        for unit in name {
            chunk.appendU16(UInt16(unit))
        }
        chunk.appendU32(0) // type strings offset
        chunk.appendU32(0) // last public type
        chunk.appendU32(0) // key strings offset
        chunk.appendU32(0) // last public key
        chunk.appendU32(0) // type id offset
        chunk.append(body)
        return chunk
    }

    /// Builds a compiled `<adaptive-icon>` XML where each layer entry carries
    /// one `android:drawable` reference; `path` may nest the drawable in
    /// wrapper elements (`["foreground", "inset"]`, as a shrunk release build ships).
    static func adaptiveIconXML(
        layers: [(path: [String], reference: UInt32)],
        utf16: Bool = false
    ) -> Data {
        adaptiveIconXML(
            drawables: layers.map { ($0.path, Drawable.reference($0.reference)) },
            utf16: utf16
        )
    }

    /// The general form: each layer's innermost element carries one
    /// `android:drawable` attribute of the given kind.
    static func adaptiveIconXML(
        drawables layers: [(path: [String], drawable: Drawable)],
        utf16: Bool = false
    ) -> Data {
        var names = ["adaptive-icon", "drawable"]
        for layer in layers {
            names.append(contentsOf: layer.path)
            if case .file(let path) = layer.drawable {
                names.append(path)
            }
        }
        var seen = Set<String>()
        names = names.filter { seen.insert($0).inserted }
        let (pool, index) = stringPool(names, utf16: utf16)

        var body = Data()
        body.append(xmlStartElement(nameIndex: index["adaptive-icon"]!))
        for layer in layers {
            for name in layer.path {
                let isDrawable = name == layer.path.last
                let value: (type: UInt8, data: UInt32)? = switch layer.drawable {
                case .reference(let id): (0x01, id)
                case .color(let color): (0x1C, color)
                case .file(let path): (0x03, UInt32(index[path]!))
                }
                body.append(xmlStartElement(
                    nameIndex: index[name]!,
                    drawable: isDrawable
                        ? (name: index["drawable"]!, type: value!.type, data: value!.data)
                        : nil
                ))
            }
            for name in layer.path.reversed() {
                body.append(xmlEndElement(nameIndex: index[name]!))
            }
        }
        body.append(xmlEndElement(nameIndex: index["adaptive-icon"]!))

        var xml = Data()
        xml.appendU16(0x0003)
        xml.appendU16(8)
        xml.appendU32(UInt32(8 + pool.count + body.count))
        xml.append(pool)
        xml.append(body)
        return xml
    }

    /// A `RES_XML_START_ELEMENT_TYPE` node with at most one typed
    /// `android:drawable` attribute.
    static func xmlStartElement(
        nameIndex: Int,
        drawable: (name: Int, type: UInt8, data: UInt32)? = nil
    ) -> Data {
        let attributeCount = drawable == nil ? 0 : 1
        var element = Data()
        element.appendU16(0x0102)
        element.appendU16(16)
        element.appendU32(UInt32(16 + 20 + attributeCount * 20))
        element.appendU32(0) // line number
        element.appendU32(0xFFFF_FFFF) // comment
        element.appendU32(0xFFFF_FFFF) // attribute namespace
        element.appendU32(UInt32(nameIndex))
        element.appendU16(20) // attribute start
        element.appendU16(20) // attribute size
        element.appendU16(UInt16(attributeCount))
        element.appendU16(0) // id index
        element.appendU16(0) // class index
        element.appendU16(0) // style index
        if let drawable {
            element.appendU32(0xFFFF_FFFF) // attribute namespace
            element.appendU32(UInt32(drawable.name))
            element.appendU32(0xFFFF_FFFF) // raw value
            element.appendU16(8) // value size
            element.append(0) // res0
            element.append(drawable.type)
            element.appendU32(drawable.data)
        }
        return element
    }

    /// A `RES_XML_END_ELEMENT_TYPE` node.
    static func xmlEndElement(nameIndex: Int) -> Data {
        var element = Data()
        element.appendU16(0x0103)
        element.appendU16(16)
        element.appendU32(24)
        element.appendU32(0) // line number
        element.appendU32(0xFFFF_FFFF) // comment
        element.appendU32(0xFFFF_FFFF) // namespace
        element.appendU32(UInt32(nameIndex))
        return element
    }

    // MARK: - Rasters

    /// An RGBA color for the generated rasters, components 0…255.
    struct Color: Equatable, CustomStringConvertible {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
        let alpha: UInt8

        init(_ red: UInt8, _ green: UInt8, _ blue: UInt8, _ alpha: UInt8 = 255) {
            self.red = red
            self.green = green
            self.blue = blue
            self.alpha = alpha
        }

        var description: String { "rgba(\(red), \(green), \(blue), \(alpha))" }

        static let clear = Color(0, 0, 0, 0)
    }

    /// A PNG of `size`×`size` pixels painted by `pixel(x, y)` (top-left
    /// origin, straight alpha).
    static func png(size: Int, pixel: (Int, Int) -> Color) -> Data {
        let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let buffer = context.data!.bindMemory(to: UInt8.self, capacity: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let color = pixel(x, y)
                let offset = (y * size + x) * 4
                let alpha = Int(color.alpha)
                buffer[offset] = UInt8(Int(color.red) * alpha / 255)
                buffer[offset + 1] = UInt8(Int(color.green) * alpha / 255)
                buffer[offset + 2] = UInt8(Int(color.blue) * alpha / 255)
                buffer[offset + 3] = color.alpha
            }
        }
        let image = context.makeImage()!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        )!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    /// A solid, opaque PNG.
    static func solidPNG(size: Int = 12, _ color: Color) -> Data {
        png(size: size) { _, _ in color }
    }

    /// Decodes a raster and reads one pixel (top-left origin, straight
    /// alpha), plus the image size.
    static func decodePixel(_ data: Data, x: Int, y: Int) -> (color: Color, width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let context = CGContext(
                  data: nil,
                  width: image.width,
                  height: image.height,
                  bitsPerComponent: 8,
                  bytesPerRow: image.width * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ),
              x >= 0, y >= 0, x < image.width, y < image.height
        else {
            return nil
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let buffer = context.data!.bindMemory(to: UInt8.self, capacity: image.width * image.height * 4)
        let offset = (y * image.width + x) * 4
        let alpha = buffer[offset + 3]
        func unpremultiply(_ value: UInt8) -> UInt8 {
            alpha == 0 ? 0 : UInt8(min(255, (Int(value) * 255 + Int(alpha) / 2) / Int(alpha)))
        }
        return (
            Color(
                unpremultiply(buffer[offset]),
                unpremultiply(buffer[offset + 1]),
                unpremultiply(buffer[offset + 2]),
                alpha
            ),
            image.width,
            image.height
        )
    }
}

/// Little-endian appends for the hand-built binary fixtures.
extension Data {
    mutating func appendU16(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func appendU32(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }
}
