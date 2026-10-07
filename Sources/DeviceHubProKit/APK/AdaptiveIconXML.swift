import Foundation

/// The drawable references of a compiled adaptive-icon (`<adaptive-icon>`)
/// XML, each tagged with the layer that encloses it. The references are what
/// Android resolves at render time; the extractor resolves them through the
/// resource table to reach rasters stored under obfuscated names.
struct AdaptiveIconManifest {
    /// The adaptive layer a drawable belongs to. The foreground is the
    /// identifying artwork and outranks the background when both resolve to
    /// rasters; `other` covers drawables outside a layer element.
    enum Layer: Int {
        case other = 0
        case monochrome
        case background
        case foreground
    }

    /// An `android:drawable` value: a resource reference to resolve through
    /// the table, a literal path, or a literal color (`0xAARRGGBB`).
    enum Drawable: Equatable {
        case resource(UInt32)
        case file(String)
        case color(UInt32)
    }

    struct Reference: Equatable {
        let layer: Layer
        let drawable: Drawable
    }

    /// Every drawable reference in document order.
    let references: [Reference]

    private static let xmlType: UInt16 = 0x0003
    private static let stringPoolType: UInt16 = 0x0001
    private static let startElementType: UInt16 = 0x0102
    private static let endElementType: UInt16 = 0x0103
    private static let typeReference: UInt8 = 0x01
    private static let typeString: UInt8 = 0x03
    private static let typeDynamicReference: UInt8 = 0x07
    private static let typeColorARGB8: UInt8 = 0x1C
    private static let typeColorRGB8: UInt8 = 0x1D
    private static let typeColorARGB4: UInt8 = 0x1E
    private static let typeColorRGB4: UInt8 = 0x1F

    init?(data: Data) {
        let reader = ApkBinaryReader(data)
        guard reader.u16(at: 0) == Self.xmlType,
              let headerSize = reader.u16(at: 2),
              let chunkSize = reader.u32(at: 4) else {
            return nil
        }
        var pool: ApkStringPool?
        var stack: [String] = []
        var references: [Reference] = []
        var offset = Int(headerSize)
        let end = min(reader.count, Int(chunkSize))
        while offset + 8 <= end {
            guard let chunkType = reader.u16(at: offset),
                  let size = reader.u32(at: offset + 4), size >= 8,
                  offset + Int(size) <= end else {
                return nil
            }
            switch chunkType {
            case Self.stringPoolType:
                pool = ApkStringPool(reader: reader, base: offset)
            case Self.startElementType:
                guard let pool,
                      let name = Self.elementName(reader: reader, base: offset, pool: pool) else {
                    return nil
                }
                // The element itself counts: the standard layout puts the
                // drawable on the layer element (`<foreground
                // android:drawable=…/>`), not on a child of it.
                stack.append(name)
                if let reference = Self.drawableReference(
                    reader: reader,
                    base: offset,
                    end: offset + Int(size),
                    pool: pool,
                    stack: stack
                ) {
                    references.append(reference)
                }
            case Self.endElementType:
                _ = stack.popLast()
            default:
                break
            }
            offset += Int(size)
        }
        guard !references.isEmpty else { return nil }
        self.references = references
    }

    private static func elementName(
        reader: ApkBinaryReader,
        base: Int,
        pool: ApkStringPool
    ) -> String? {
        guard let nameIndex = reader.u32(at: base + 16 + 4) else { return nil }
        return pool.string(at: Int(nameIndex))
    }

    /// The node's `android:drawable` attribute as a reference, tagged with
    /// the nearest layer element on `stack` (which ends with the node
    /// itself). Elements may nest the drawable in wrappers
    /// (`<foreground><inset android:drawable="..."/>`), so the whole element
    /// stack is consulted. Attributes must lie inside the element's
    /// chunk (`end`); a malformed count or stride never reads a later chunk.
    private static func drawableReference(
        reader: ApkBinaryReader,
        base: Int,
        end: Int,
        pool: ApkStringPool,
        stack: [String]
    ) -> Reference? {
        let extensionBase = base + 16
        guard let attributeStart = reader.u16(at: extensionBase + 8),
              let attributeSize = reader.u16(at: extensionBase + 10), attributeSize >= 20,
              let attributeCount = reader.u16(at: extensionBase + 12) else {
            return nil
        }
        for position in 0..<Int(attributeCount) {
            let attribute = extensionBase + Int(attributeStart) + position * Int(attributeSize)
            guard attribute + 20 <= end else { break }
            guard let nameIndex = reader.u32(at: attribute + 4),
                  pool.string(at: Int(nameIndex)) == "drawable",
                  let dataType = reader.u8(at: attribute + 15),
                  let value = reader.u32(at: attribute + 16) else {
                continue
            }
            let drawable: Drawable
            switch dataType {
            case Self.typeReference, Self.typeDynamicReference:
                drawable = .resource(value)
            case Self.typeString:
                guard let path = pool.string(at: Int(value)) else { continue }
                drawable = .file(path)
            case Self.typeColorARGB8, Self.typeColorARGB4:
                drawable = .color(value)
            case Self.typeColorRGB8, Self.typeColorRGB4:
                drawable = .color(value | 0xFF00_0000)
            default:
                continue
            }
            return Reference(layer: enclosingLayer(of: stack), drawable: drawable)
        }
        return nil
    }

    private static func enclosingLayer(of stack: [String]) -> Layer {
        for name in stack.reversed() {
            switch name {
            case "foreground": return .foreground
            case "background": return .background
            case "monochrome": return .monochrome
            default: continue
            }
        }
        return .other
    }
}
