import Foundation

/// The icon-rendering view of an APK's binary `resources.arsc`: resolves a
/// resource reference to the `res/...` files its entries name, one per
/// configuration (and therefore per density), or to the color it holds.
///
/// Only the chunks and entry types needed for that resolution are interpreted.
/// Type and key names and complex (map) entries are ignored; full and compact
/// entries are both read (platform-built APKs use compact entries throughout).
/// An entry index or offset outside its type chunk is rejected (as Android's
/// `LoadedArsc` does), which degrades to "no icon" rather than to a wrong
/// file.
struct ApkResourceTable {
    /// One file a resource names, with the density of the configuration the
    /// entry was resolved in. Zero means the table left density unspecified.
    struct FilePath: Equatable {
        let path: String
        let density: Int
    }

    private static let tableType: UInt16 = 0x0002
    private static let stringPoolType: UInt16 = 0x0001
    private static let packageType: UInt16 = 0x0200
    private static let typeType: UInt16 = 0x0201

    private struct TypeChunk {
        let base: Int
        /// One past the chunk's last byte: entries must lie before it.
        let end: Int
        let id: UInt8
        let flags: UInt8
        let entryCount: Int
        let headerSize: Int
        let entriesStart: Int
        let density: Int
        /// Every qualifier of the chunk's `ResTable_config` is unset.
        let isDefaultConfig: Bool

        init?(reader: ApkBinaryReader, base: Int) {
            guard reader.u16(at: base) == ApkResourceTable.typeType,
                  let headerSize = reader.u16(at: base + 2), headerSize >= 20,
                  let size = reader.u32(at: base + 4),
                  let id = reader.u8(at: base + 8),
                  let flags = reader.u8(at: base + 9),
                  let entryCount = reader.u32(at: base + 12),
                  let entriesStart = reader.u32(at: base + 16),
                  let configSize = reader.u32(at: base + 20), configSize >= 16,
                  let density = reader.u16(at: base + 20 + 14) else {
                return nil
            }
            // The offset array sits between the header and the entries:
            // 32-bit slots (dense and sparse) or 16-bit ones (FLAG_OFFSET16).
            let slotSize = flags & 0x01 == 0 && flags & 0x02 != 0 ? 2 : 4
            guard Int(headerSize) + Int(entryCount) * slotSize <= Int(entriesStart),
                  Int(entriesStart) <= Int(size),
                  base + Int(size) <= reader.count else {
                return nil
            }
            self.base = base
            self.end = base + Int(size)
            self.id = id
            self.flags = flags
            self.entryCount = Int(entryCount)
            self.headerSize = Int(headerSize)
            self.entriesStart = base + Int(entriesStart)
            self.density = Int(density)
            let qualifiers = reader.bytes(
                at: base + 20 + 4,
                count: max(0, min(Int(configSize), Int(headerSize) - 20) - 4)
            )
            self.isDefaultConfig = qualifiers?.allSatisfy { $0 == 0 } ?? false
        }
    }

    private struct Package {
        let id: UInt32
        let chunks: [TypeChunk]
    }

    private enum EntryValue {
        case file(String)
        case reference(UInt32)
        /// `0xAARRGGBB`.
        case color(UInt32)
    }

    private let reader: ApkBinaryReader
    private let strings: ApkStringPool
    private let packages: [Package]

    init?(data: Data) {
        let reader = ApkBinaryReader(data)
        guard reader.u16(at: 0) == Self.tableType,
              let headerSize = reader.u16(at: 2),
              let tableSize = reader.u32(at: 4) else {
            return nil
        }
        var strings: ApkStringPool?
        var packages: [Package] = []
        var offset = Int(headerSize)
        let end = min(reader.count, Int(tableSize))
        while offset + 8 <= end {
            guard let chunkType = reader.u16(at: offset),
                  let size = reader.u32(at: offset + 4), size >= 8,
                  offset + Int(size) <= end else {
                return nil
            }
            if chunkType == Self.stringPoolType, strings == nil {
                strings = ApkStringPool(reader: reader, base: offset)
            } else if chunkType == Self.packageType,
                      let package = Self.parsePackage(reader: reader, base: offset) {
                packages.append(package)
            }
            offset += Int(size)
        }
        guard let strings, !packages.isEmpty else { return nil }
        self.reader = reader
        self.strings = strings
        self.packages = packages
    }

    /// Every distinct file the reference names across configurations, the
    /// densest first; ties fall back to the lexicographically first path so
    /// the order is deterministic.
    func filePaths(for reference: UInt32) -> [FilePath] {
        var visited = Set<UInt32>()
        var paths: [FilePath] = []
        var colors: [(color: UInt32, isDefault: Bool)] = []
        resolve(reference, depth: 0, visited: &visited, paths: &paths, colors: &colors)
        let sorted = paths.sorted {
            if $0.density != $1.density { return $0.density > $1.density }
            return $0.path < $1.path
        }
        var seen = Set<String>()
        return sorted.filter { seen.insert($0.path).inserted }
    }

    /// The `0xAARRGGBB` color the reference resolves to (an adaptive icon's
    /// `@color/…` background), preferring the default configuration over
    /// qualified ones (night mode, …); nil when it names no color.
    func color(for reference: UInt32) -> UInt32? {
        var visited = Set<UInt32>()
        var paths: [FilePath] = []
        var colors: [(color: UInt32, isDefault: Bool)] = []
        resolve(reference, depth: 0, visited: &visited, paths: &paths, colors: &colors)
        return (colors.first { $0.isDefault } ?? colors.first)?.color
    }

    /// Collects the files and colors `reference` resolves to. Aliases chain
    /// through the table; the depth cap and the visited set turn a malformed
    /// cycle or an exponential fan-out of aliases into "no icon" instead of
    /// endless work.
    private func resolve(
        _ reference: UInt32,
        depth: Int,
        visited: inout Set<UInt32>,
        paths: inout [FilePath],
        colors: inout [(color: UInt32, isDefault: Bool)]
    ) {
        guard depth < 8, visited.insert(reference).inserted else { return }
        let packageId = (reference >> 24) & 0xFF
        let typeId = UInt8((reference >> 16) & 0xFF)
        let entryIndex = Int(reference & 0xFFFF)

        for package in packages where package.id == packageId {
            for chunk in package.chunks where chunk.id == typeId {
                guard let offset = entryOffset(of: entryIndex, in: chunk),
                      let value = entryValue(at: offset, in: chunk) else {
                    continue
                }
                switch value {
                case .file(let path):
                    paths.append(FilePath(path: path, density: densityRank(chunk.density)))
                case .color(let color):
                    colors.append((color, chunk.isDefaultConfig))
                case .reference(let target):
                    resolve(target, depth: depth + 1, visited: &visited, paths: &paths, colors: &colors)
                }
            }
        }
    }

    private static func parsePackage(reader: ApkBinaryReader, base: Int) -> Package? {
        guard reader.u16(at: base) == Self.packageType,
              let headerSize = reader.u16(at: base + 2),
              let size = reader.u32(at: base + 4),
              let id = reader.u32(at: base + 8) else {
            return nil
        }
        var chunks: [TypeChunk] = []
        var offset = base + Int(headerSize)
        let end = base + Int(size)
        while offset + 8 <= end {
            guard let chunkType = reader.u16(at: offset),
                  let chunkSize = reader.u32(at: offset + 4), chunkSize >= 8,
                  offset + Int(chunkSize) <= end else {
                return nil
            }
            if chunkType == Self.typeType, let chunk = TypeChunk(reader: reader, base: offset) {
                chunks.append(chunk)
            }
            offset += Int(chunkSize)
        }
        return Package(id: id, chunks: chunks)
    }

    /// The byte offset of an entry inside its type chunk, following the type
    /// chunk's offset encoding: plain 32-bit, 16-bit (`FLAG_OFFSET16`) or
    /// sparse (`FLAG_SPARSE`). An index past the chunk's `entryCount` has no
    /// slot: reading one would take entry bytes for an offset.
    private func entryOffset(of index: Int, in chunk: TypeChunk) -> Int? {
        if chunk.flags & 0x01 != 0 {
            for position in 0..<chunk.entryCount {
                let sparse = chunk.base + chunk.headerSize + position * 4
                guard let candidate = reader.u16(at: sparse),
                      let offset = reader.u16(at: sparse + 2) else {
                    return nil
                }
                if candidate == UInt16(truncatingIfNeeded: index) {
                    return chunk.entriesStart + Int(offset) * 4
                }
            }
            return nil
        }
        guard index < chunk.entryCount else { return nil }
        if chunk.flags & 0x02 != 0 {
            guard let raw = reader.u16(at: chunk.base + chunk.headerSize + index * 2) else {
                return nil
            }
            return raw == 0xFFFF ? nil : chunk.entriesStart + Int(raw) * 4
        }
        guard let raw = reader.u32(at: chunk.base + chunk.headerSize + index * 4) else {
            return nil
        }
        return raw == 0xFFFF_FFFF ? nil : chunk.entriesStart + Int(raw)
    }

    /// The value of the entry at `offset`, which must lie — header and
    /// value both — inside `chunk`; an offset that lands in a later chunk
    /// would otherwise be parsed as an unrelated entry.
    ///
    /// Two entry layouts exist (`ResTable_entry` in AOSP's
    /// `ResourceTypes.h`). A full entry is `size`, `flags`, `key` followed
    /// by a `Res_value` at `offset + size`. A compact entry
    /// (`FLAG_COMPACT`, which the platform build enables for every system
    /// app since Android 14) is 8 bytes on its own: a 16-bit `key`, the
    /// `flags` whose high byte is the value's data type, and the 32-bit
    /// value data — there is no `size` field and no `Res_value` after it.
    private func entryValue(at offset: Int, in chunk: TypeChunk) -> EntryValue? {
        guard offset >= chunk.entriesStart,
              let entryFlags = reader.u16(at: offset + 2) else {
            return nil
        }
        // FLAG_COMPLEX points at a map (a style, an array), not a file or a
        // color; it is never compact.
        guard entryFlags & 0x0001 == 0 else { return nil }

        let dataType: UInt8
        let value: UInt32
        if entryFlags & 0x0008 != 0 {
            guard offset + 8 <= chunk.end,
                  let data = reader.u32(at: offset + 4) else {
                return nil
            }
            dataType = UInt8(entryFlags >> 8)
            value = data
        } else {
            guard let entrySize = reader.u16(at: offset), entrySize >= 8 else { return nil }
            let valueBase = offset + Int(entrySize)
            // `Res_value`: size (2), res0 (1), dataType (1), data (4).
            guard valueBase + 8 <= chunk.end,
                  let type = reader.u8(at: valueBase + 3),
                  let data = reader.u32(at: valueBase + 4) else {
                return nil
            }
            dataType = type
            value = data
        }
        switch dataType {
        case 0x01, 0x07: // TYPE_REFERENCE, TYPE_DYNAMIC_REFERENCE
            return .reference(value)
        case 0x03: // TYPE_STRING
            guard let path = strings.string(at: Int(value)) else { return nil }
            return .file(path)
        case 0x1C, 0x1E: // TYPE_INT_COLOR_ARGB8, TYPE_INT_COLOR_ARGB4
            return .color(value)
        case 0x1D, 0x1F: // TYPE_INT_COLOR_RGB8, TYPE_INT_COLOR_RGB4
            return .color(value | 0xFF00_0000)
        default:
            return nil
        }
    }

    /// `ResTable_config` densities: zero means "default" (mdpi); `anydpi` and
    /// `nodpi` carry no raster density and rank below every real one.
    private func densityRank(_ raw: Int) -> Int {
        switch raw {
        case 0: return 160
        case 0xFFFE, 0xFFFF: return 0
        default: return raw
        }
    }
}
