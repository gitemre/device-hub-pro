import XCTest
@testable import DeviceHubProKit

/// The APK binary-resource parsers on raw fixture bytes: string pools
/// (`ApkStringPool`), `resources.arsc` (`ApkResourceTable`) and compiled
/// adaptive-icon XML (`AdaptiveIconManifest`). Every input is a file the user
/// opened, so malformed and truncated bytes must degrade to "nothing
/// resolved", never to a trap, a hang or a wrong file.
final class ApkResourceParsingTests: XCTestCase {
    // MARK: - String pool

    private func pool(_ data: Data) throws -> ApkStringPool {
        try XCTUnwrap(ApkStringPool(reader: ApkBinaryReader(data), base: 0))
    }

    func testUTF8PoolDecodesShortStrings() throws {
        let (data, index) = ApkFixture.stringPool(["res/a.png", "drawable", ""])
        let pool = try pool(data)

        XCTAssertEqual(pool.stringCount, 3)
        XCTAssertEqual(pool.string(at: index["res/a.png"]!), "res/a.png")
        XCTAssertEqual(pool.string(at: index["drawable"]!), "drawable")
        XCTAssertEqual(pool.string(at: 2), "")
    }

    /// Lengths of 128+ use a two-byte prefix. The old decode shifted a
    /// `UInt8` left by 8 (always 0), so a 300-byte path came back as its
    /// first 44 bytes — the wrong archive member.
    func testUTF8PoolDecodesStringsLongerThan255Bytes() throws {
        let long = "res/" + String(repeating: "obfuscated/", count: 27) + "ic.png"
        XCTAssertGreaterThan(long.utf8.count, 255)
        let multibyte = String(repeating: "ğ", count: 200) // 400 bytes, 200 units
        let (data, index) = ApkFixture.stringPool(["short", long, multibyte])
        let pool = try pool(data)

        XCTAssertEqual(pool.string(at: index[long]!), long)
        XCTAssertEqual(pool.string(at: index[multibyte]!), multibyte)
        XCTAssertEqual(pool.string(at: index["short"]!), "short")
    }

    func testUTF16PoolDecodesShortAndVeryLongStrings() throws {
        // 40 000 units needs the two-unit length prefix (> 0x7FFF).
        let long = String(repeating: "abcd", count: 10_000)
        let (data, index) = ApkFixture.stringPool(["drawable", "çğü", long], utf16: true)
        let pool = try pool(data)

        XCTAssertEqual(pool.string(at: index["drawable"]!), "drawable")
        XCTAssertEqual(pool.string(at: index["çğü"]!), "çğü")
        XCTAssertEqual(pool.string(at: index[long]!), long)
    }

    func testPoolRejectsOutOfRangeIndices() throws {
        let pool = try pool(ApkFixture.stringPool(["one"]).data)

        XCTAssertNil(pool.string(at: -1))
        XCTAssertNil(pool.string(at: 1))
        XCTAssertNil(pool.string(at: Int(Int32.max)))
    }

    /// A length prefix claiming more bytes than the chunk holds must not read
    /// into the following chunk.
    func testPoolStringCannotReadPastItsChunk() throws {
        var (data, _) = ApkFixture.stringPool(["abc"])
        let stringsStart = Int(data[20]) | Int(data[21]) << 8
        data[stringsStart + 1] = 0x40 // UTF-8 byte length 64, the chunk has 4
        data.append(Data(repeating: 0x41, count: 128)) // a "next chunk" of 'A's

        let pool = try pool(data)

        XCTAssertNil(pool.string(at: 0))
    }

    func testPoolRejectsHeadersThatDoNotFit() {
        var (data, _) = ApkFixture.stringPool(["abc", "def"])
        // String count larger than the chunk's offset array can hold.
        data[8] = 0xFF
        data[9] = 0xFF
        XCTAssertNil(ApkStringPool(reader: ApkBinaryReader(data), base: 0))
        // Not a string pool at all.
        XCTAssertNil(ApkStringPool(reader: ApkBinaryReader(Data([0x03, 0x00])), base: 0))
        XCTAssertNil(ApkStringPool(reader: ApkBinaryReader(Data()), base: 0))
    }

    func testTruncatedPoolsNeverTrap() {
        let (data, _) = ApkFixture.stringPool(["res/a.png", String(repeating: "x", count: 300)])
        let (utf16, _) = ApkFixture.stringPool(["res/a.png", "çğü"], utf16: true)
        for fixture in [data, utf16] {
            for length in 0...fixture.count {
                let prefix = fixture.prefix(length)
                if let pool = ApkStringPool(reader: ApkBinaryReader(prefix), base: 0) {
                    for index in 0..<pool.stringCount {
                        _ = pool.string(at: index)
                    }
                }
            }
        }
    }

    // MARK: - Resource table

    func testTableResolvesFilesDensestFirstAndColors() throws {
        let table = try XCTUnwrap(ApkResourceTable(data: ApkFixture.resourceTable([
            ApkFixture.Entry(id: 0x7F080001, density: 160, value: .file("res/mdpi.png")),
            ApkFixture.Entry(id: 0x7F080001, density: 640, value: .file("res/xxxhdpi.png")),
            ApkFixture.Entry(id: 0x7F080002, density: 0, value: .reference(0x7F080001)),
            ApkFixture.Entry(id: 0x7F060000, density: 0, value: .color(0xFF3366CC)),
            ApkFixture.Entry(id: 0x7F060001, density: 0, value: .reference(0x7F060000)),
        ])))

        XCTAssertEqual(table.filePaths(for: 0x7F080001).map(\.path), ["res/xxxhdpi.png", "res/mdpi.png"])
        XCTAssertEqual(table.filePaths(for: 0x7F080002).map(\.path), ["res/xxxhdpi.png", "res/mdpi.png"])
        XCTAssertEqual(table.color(for: 0x7F060000), 0xFF3366CC)
        XCTAssertEqual(table.color(for: 0x7F060001), 0xFF3366CC)
        XCTAssertNil(table.color(for: 0x7F080001))
        XCTAssertEqual(table.filePaths(for: 0x7F060000), [])
        XCTAssertEqual(table.filePaths(for: 0x7F09FFFF), [])
        XCTAssertEqual(table.filePaths(for: 0x01080001), [], "another package id resolves nothing")
    }

    /// A dense type chunk only has slots for `entryCount` entries. Reading
    /// the "slot" of an index past it took entry bytes for an offset and
    /// resolved an unrelated string — a real raster path that would have
    /// been cached as the app icon.
    func testIndexPastTheEntryCountResolvesNothing() throws {
        let (pool, _) = ApkFixture.stringPool(["res/right.png", "res/wrong.png"])
        var entries = Data()
        entries.append(rawEntry(dataType: 0x03, data: 0)) // entry 0 → res/right.png
        entries.append(rawValue(dataType: 0x03, data: 1)) // stray bytes → res/wrong.png
        let chunk = rawTypeChunk(typeId: 1, entryCount: 1, slots: [0], entries: entries)
        let table = try XCTUnwrap(ApkResourceTable(data: rawTable(pool: pool, typeChunks: [chunk])))

        XCTAssertEqual(table.filePaths(for: 0x7F010000).map(\.path), ["res/right.png"])
        XCTAssertEqual(table.filePaths(for: 0x7F010001), [])
    }

    /// An entry offset whose entry (or its `Res_value`) extends past the type
    /// chunk would parse whatever follows as an entry.
    func testEntryOutsideItsChunkResolvesNothing() throws {
        let (pool, _) = ApkFixture.stringPool(["res/right.png", "res/wrong.png"])
        let entries = rawEntry(dataType: 0x03, data: 0)
        // Slot 0 points just past the entries, where the next table chunk
        // carries an entry-shaped header and a TYPE_STRING value.
        let chunk = rawTypeChunk(typeId: 1, entryCount: 1, slots: [UInt32(entries.count)], entries: entries)
        var trailing = Data()
        trailing.appendU16(0x0008) // unknown chunk type; read as entry size 8
        trailing.appendU16(0x0010) // header size; read as entry flags 0x10
        trailing.appendU32(16)
        trailing.append(rawValue(dataType: 0x03, data: 1))
        let table = try XCTUnwrap(ApkResourceTable(
            data: rawTable(pool: pool, typeChunks: [chunk], trailing: trailing)
        ))

        XCTAssertEqual(table.filePaths(for: 0x7F010000), [])
    }

    /// Aliases fanning out across many configurations used to be resolved
    /// again for every path to them (50 configurations over 8 hops is 50⁸
    /// visits); each reference now resolves once.
    func testAliasFanOutResolvesQuickly() throws {
        var entries: [ApkFixture.Entry] = []
        for hop in 0..<8 {
            for density in 1...50 {
                entries.append(ApkFixture.Entry(
                    id: 0x7F080000 | UInt32(hop),
                    density: density,
                    value: .reference(0x7F080000 | UInt32(hop + 1))
                ))
            }
        }
        entries.append(ApkFixture.Entry(id: 0x7F080008, density: 640, value: .file("res/end.png")))
        let table = try XCTUnwrap(ApkResourceTable(data: ApkFixture.resourceTable(entries)))

        let started = ContinuousClock.now
        let paths = table.filePaths(for: 0x7F080000)

        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2))
        XCTAssertEqual(paths.map(\.path), [], "the chain is deeper than the alias cap")
        XCTAssertEqual(table.filePaths(for: 0x7F080002).map(\.path), ["res/end.png"])
    }

    func testAliasCycleTerminates() throws {
        let table = try XCTUnwrap(ApkResourceTable(data: ApkFixture.resourceTable([
            ApkFixture.Entry(id: 0x7F080000, density: 0, value: .reference(0x7F080001)),
            ApkFixture.Entry(id: 0x7F080001, density: 0, value: .reference(0x7F080000)),
        ])))

        XCTAssertEqual(table.filePaths(for: 0x7F080000), [])
        XCTAssertNil(table.color(for: 0x7F080000))
    }

    func testMalformedTablesAreRejected() {
        XCTAssertNil(ApkResourceTable(data: Data()))
        XCTAssertNil(ApkResourceTable(data: Data([0x02, 0x00, 0x0C, 0x00])))
        // A chunk size below the 8-byte header would never advance.
        var table = ApkFixture.resourceTable([
            ApkFixture.Entry(id: 0x7F080001, density: 0, value: .file("res/a.png")),
        ])
        table[16] = 4
        table[17] = 0
        table[18] = 0
        table[19] = 0
        XCTAssertNil(ApkResourceTable(data: table))
    }

    func testTruncatedTablesNeverTrap() {
        for fixture in tableFixtures() {
            for length in 0...fixture.count {
                resolveEverything(in: fixture.prefix(length))
            }
        }
    }

    func testCorruptedTablesNeverTrap() {
        var generator = LCG(seed: 0xA11C_E5ED)
        for fixture in tableFixtures() {
            for _ in 0..<600 {
                var corrupted = fixture
                for _ in 0..<(1 + generator.next() % 6) {
                    let position = Int(generator.next() % UInt64(corrupted.count))
                    corrupted[position] = UInt8(truncatingIfNeeded: generator.next())
                }
                resolveEverything(in: corrupted)
            }
        }
    }

    // MARK: - Adaptive-icon XML

    func testManifestTagsDrawablesWithTheirEnclosingLayer() throws {
        let manifest = try XCTUnwrap(AdaptiveIconManifest(data: ApkFixture.adaptiveIconXML(drawables: [
            (["background"], .color(0xFF112233)),
            (["foreground", "inset"], .reference(0x7F080001)),
            (["monochrome"], .file("res/mono.png")),
        ])))

        XCTAssertEqual(manifest.references, [
            AdaptiveIconManifest.Reference(layer: .background, drawable: .color(0xFF112233)),
            AdaptiveIconManifest.Reference(layer: .foreground, drawable: .resource(0x7F080001)),
            AdaptiveIconManifest.Reference(layer: .monochrome, drawable: .file("res/mono.png")),
        ])
    }

    func testManifestDecodesUTF16Pools() throws {
        let manifest = try XCTUnwrap(AdaptiveIconManifest(data: ApkFixture.adaptiveIconXML(
            layers: [(["foreground"], 0x7F080001)],
            utf16: true
        )))

        XCTAssertEqual(manifest.references, [
            AdaptiveIconManifest.Reference(layer: .foreground, drawable: .resource(0x7F080001)),
        ])
    }

    func testManifestWithoutDrawablesIsNil() {
        XCTAssertNil(AdaptiveIconManifest(data: Data("<adaptive-icon/>".utf8)))
        XCTAssertNil(AdaptiveIconManifest(data: ApkFixture.adaptiveIconXML(drawables: [])))
        XCTAssertNil(AdaptiveIconManifest(data: Data()))
    }

    /// Attributes are read only inside their own element: a malformed
    /// attribute start/count on `<adaptive-icon>` used to read the next
    /// element's `android:drawable` a second time, as a layer-less drawable.
    func testAttributesAreBoundedByTheirElement() throws {
        var xml = ApkFixture.adaptiveIconXML(drawables: [(["foreground"], .reference(0x7F080001))])
        // <adaptive-icon> (36 bytes, no attributes) follows the header and
        // the pool; <foreground> and its one attribute come right after.
        let poolSize = Int(xml[12]) | Int(xml[13]) << 8
        let root = 8 + poolSize
        XCTAssertEqual(xml[root], 0x02)
        XCTAssertEqual(xml[root + 36], 0x02)
        // Attribute start 56 from the root's extension lands exactly on the
        // <foreground> element's attribute; count 1.
        xml[root + 16 + 8] = 56
        xml[root + 16 + 12] = 1

        let manifest = try XCTUnwrap(AdaptiveIconManifest(data: xml))
        XCTAssertEqual(manifest.references, [
            AdaptiveIconManifest.Reference(layer: .foreground, drawable: .resource(0x7F080001)),
        ])

        // A stride below the attribute size, or a huge count, never traps.
        xml[root + 16 + 10] = 0
        xml[root + 16 + 12] = 0xFF
        xml[root + 16 + 13] = 0xFF
        XCTAssertNotNil(AdaptiveIconManifest(data: xml))
    }

    func testTruncatedAndCorruptedManifestsNeverTrap() {
        let fixtures = [
            ApkFixture.adaptiveIconXML(drawables: [
                (["background"], .color(0xFF112233)),
                (["foreground", "inset"], .reference(0x7F080001)),
                (["monochrome"], .file("res/mono.png")),
            ]),
            ApkFixture.adaptiveIconXML(layers: [(["foreground"], 0x7F080001)], utf16: true),
        ]
        var generator = LCG(seed: 0x0DDB_A11)
        for fixture in fixtures {
            for length in 0...fixture.count {
                _ = AdaptiveIconManifest(data: fixture.prefix(length))
            }
            for _ in 0..<600 {
                var corrupted = fixture
                for _ in 0..<(1 + generator.next() % 6) {
                    let position = Int(generator.next() % UInt64(corrupted.count))
                    corrupted[position] = UInt8(truncatingIfNeeded: generator.next())
                }
                _ = AdaptiveIconManifest(data: corrupted)
            }
        }
    }

    // MARK: - Helpers

    private func tableFixtures() -> [Data] {
        let entries = [
            ApkFixture.Entry(id: 0x7F060000, density: 0, value: .color(0xFF3366CC)),
            ApkFixture.Entry(id: 0x7F080001, density: 160, value: .file("res/mdpi.png")),
            ApkFixture.Entry(id: 0x7F080001, density: 640, value: .file("res/xxxhdpi.png")),
            ApkFixture.Entry(id: 0x7F080002, density: 0, value: .reference(0x7F080001)),
        ]
        return [
            ApkFixture.resourceTable(entries),
            ApkFixture.resourceTable(entries, sparse: true),
            ApkFixture.resourceTable(entries, offset16: true, utf16: true),
        ]
    }

    private func resolveEverything(in data: Data) {
        guard let table = ApkResourceTable(data: data) else { return }
        for reference: UInt32 in [0x7F060000, 0x7F080000, 0x7F080001, 0x7F080002, 0x7F08FFFF] {
            _ = table.filePaths(for: reference)
            _ = table.color(for: reference)
        }
    }

    /// A `ResTable_entry` (8 bytes) plus its `Res_value`.
    private func rawEntry(dataType: UInt8, data: UInt32) -> Data {
        var bytes = Data()
        bytes.appendU16(8)
        bytes.appendU16(0)
        bytes.appendU32(0)
        bytes.append(rawValue(dataType: dataType, data: data))
        return bytes
    }

    private func rawValue(dataType: UInt8, data: UInt32) -> Data {
        var bytes = Data()
        bytes.appendU16(8)
        bytes.append(0)
        bytes.append(dataType)
        bytes.appendU32(data)
        return bytes
    }

    /// A dense type chunk with explicit slots (byte offsets into `entries`).
    private func rawTypeChunk(typeId: UInt8, entryCount: Int, slots: [UInt32], entries: Data) -> Data {
        let headerSize = 20 + 64
        let entriesStart = headerSize + slots.count * 4
        var chunk = Data()
        chunk.appendU16(0x0201)
        chunk.appendU16(UInt16(headerSize))
        chunk.appendU32(UInt32(entriesStart + entries.count))
        chunk.append(typeId)
        chunk.append(0) // flags: dense
        chunk.appendU16(0)
        chunk.appendU32(UInt32(entryCount))
        chunk.appendU32(UInt32(entriesStart))
        chunk.append(ApkFixture.config(density: 0))
        for slot in slots {
            chunk.appendU32(slot)
        }
        chunk.append(entries)
        return chunk
    }

    /// A table of `pool`, one package holding `typeChunks`, then `trailing`
    /// raw bytes (still inside the table).
    private func rawTable(pool: Data, typeChunks: [Data], trailing: Data = Data()) -> Data {
        let package = ApkFixture.packageChunk(typeChunks.reduce(Data(), +))
        var table = Data()
        table.appendU16(0x0002)
        table.appendU16(12)
        table.appendU32(UInt32(12 + pool.count + package.count + trailing.count))
        table.appendU32(1)
        table.append(pool)
        table.append(package)
        table.append(trailing)
        return table
    }

    /// A deterministic generator, so a failing corruption reproduces.
    private struct LCG {
        private var state: UInt64

        init(seed: UInt64) {
            state = seed
        }

        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state >> 33
        }
    }
}
