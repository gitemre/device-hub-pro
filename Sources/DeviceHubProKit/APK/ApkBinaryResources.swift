import Foundation

/// A bounds-checked little-endian view over the chunked binary formats APKs
/// use for compiled XML and `resources.arsc`. Both are bytes from files the
/// user opens, so every read is optional rather than trapping on malformed
/// data.
struct ApkBinaryReader {
    private let data: Data

    init(_ data: Data) {
        self.data = data
    }

    var count: Int { data.count }

    func u8(at offset: Int) -> UInt8? {
        guard offset >= 0, offset < data.count else { return nil }
        return data[data.startIndex + offset]
    }

    func u16(at offset: Int) -> UInt16? {
        guard let low = u8(at: offset), let high = u8(at: offset + 1) else { return nil }
        return UInt16(low) | UInt16(high) << 8
    }

    func u32(at offset: Int) -> UInt32? {
        guard let low = u16(at: offset), let high = u16(at: offset + 2) else { return nil }
        return UInt32(low) | UInt32(high) << 16
    }

    func bytes(at offset: Int, count: Int) -> Data? {
        guard offset >= 0, count >= 0, offset + count <= data.count else { return nil }
        let start = data.startIndex + offset
        return data[start..<(start + count)]
    }
}

/// A `RES_STRING_POOL_TYPE` chunk: the shared string table of a compiled XML
/// or `resources.arsc`. APKs contain both UTF-8 and UTF-16 pools, so both
/// encodings are decoded.
struct ApkStringPool {
    private static let chunkType: UInt16 = 0x0001

    private let reader: ApkBinaryReader
    private let count: Int
    private let offsetsBase: Int
    private let stringsBase: Int
    /// The end of the chunk: string data never extends past it into the
    /// next chunk.
    private let end: Int
    private let isUTF8: Bool

    init?(reader: ApkBinaryReader, base: Int) {
        guard reader.u16(at: base) == Self.chunkType,
              let headerSize = reader.u16(at: base + 2), headerSize >= 28,
              let chunkSize = reader.u32(at: base + 4),
              let count = reader.u32(at: base + 8),
              let flags = reader.u32(at: base + 16),
              let stringsStart = reader.u32(at: base + 20) else {
            return nil
        }
        let offsetsBase = base + Int(headerSize)
        let stringsBase = base + Int(stringsStart)
        let end = min(base + Int(chunkSize), reader.count)
        guard offsetsBase + Int(count) * 4 <= end,
              stringsBase >= offsetsBase,
              stringsBase <= end else {
            return nil
        }
        self.reader = reader
        self.count = Int(count)
        self.offsetsBase = offsetsBase
        self.stringsBase = stringsBase
        self.end = end
        self.isUTF8 = flags & 0x100 != 0
    }

    var stringCount: Int { count }

    func string(at index: Int) -> String? {
        guard index >= 0, index < count,
              let offset = reader.u32(at: offsetsBase + index * 4) else {
            return nil
        }
        var position = stringsBase + Int(offset)
        if isUTF8 {
            // The prefixes are the UTF-16 length (unused), then the UTF-8
            // byte length; a high bit means the length continues in the next
            // byte.
            guard skipUTF8Length(at: &position) != nil,
                  let byteCount = skipUTF8Length(at: &position),
                  position + byteCount <= end,
                  let bytes = reader.bytes(at: position, count: byteCount)
            else {
                return nil
            }
            return String(data: bytes, encoding: .utf8)
        }
        guard let first = reader.u16(at: position) else { return nil }
        position += 2
        // Widened before shifting: a 16-bit value shifted by 16 is zero.
        var length = Int(first)
        if first & 0x8000 != 0 {
            guard let low = reader.u16(at: position) else { return nil }
            length = (Int(first & 0x7FFF) << 16) | Int(low)
            position += 2
        }
        guard position + length * 2 <= end,
              let bytes = reader.bytes(at: position, count: length * 2)
        else {
            return nil
        }
        return String(data: bytes, encoding: .utf16LittleEndian)
    }

    /// Reads one UTF-8 pool length prefix at `position` and advances past it:
    /// one byte, or two when the first has its high bit set (lengths of 128
    /// and more). Widened to `Int` before shifting — `UInt8 << 8` is zero,
    /// which used to cut every string of 256+ bytes down to its low byte.
    private func skipUTF8Length(at position: inout Int) -> Int? {
        guard let first = reader.u8(at: position) else { return nil }
        position += 1
        guard first & 0x80 != 0 else { return Int(first) }
        guard let next = reader.u8(at: position) else { return nil }
        position += 1
        return (Int(first & 0x7F) << 8) | Int(next)
    }
}
