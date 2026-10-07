import XCTest
import DeviceHubProKit
import AppKit
import ImageIO
@testable import DeviceHubProApp

final class SkinArtworkCacheTests: XCTestCase {
    @MainActor
    func testFallbackArtworkIsCachedByDirectory() throws {
        // A skin whose declared background is missing takes the fallback
        // path, which scans the directory and used to mint a fresh NSImage
        // per call (a re-decode on every view refresh).
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Self.writePNG(to: directory.appendingPathComponent("zz.png"))

        let display = SkinDisplay(
            displaySize: CGSize(width: 4, height: 4), origin: .zero,
            layoutSize: CGSize(width: 4, height: 4),
            backgroundImage: nil, maskImage: nil, orientation: .portrait)
        let variant = SkinVariant(
            id: "default", directory: directory,
            layout: SkinLayoutFile(portrait: display, landscape: nil))

        // Its own cache: the shared one holds only 12 images, and other
        // tests running at the same time could evict this one between the
        // two calls (a flake seen under a loaded full run).
        let cache = SkinThumbnailCache()
        let first = cache.artwork(for: variant, display: display).background
        let second = cache.artwork(for: variant, display: display).background
        XCTAssertNotNil(first)
        XCTAssertTrue(first === second)
    }

    @MainActor
    func testDeclaredArtworkStillWinsAndIsCached() throws {
        // A declared background is returned (not the directory fallback) and
        // is cached by file path: the second call is the same instance.
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Self.writePNG(to: directory.appendingPathComponent("bg.png"))

        let display = SkinDisplay(
            displaySize: CGSize(width: 4, height: 4), origin: .zero,
            layoutSize: CGSize(width: 4, height: 4),
            backgroundImage: "bg.png", maskImage: nil, orientation: .portrait)
        let variant = SkinVariant(
            id: "default", directory: directory,
            layout: SkinLayoutFile(portrait: display, landscape: nil))

        let cache = SkinThumbnailCache.shared
        let first = cache.artwork(for: variant, display: display).background
        let second = cache.artwork(for: variant, display: display).background
        XCTAssertNotNil(first)
        XCTAssertTrue(first === second)
    }

    // MARK: - Live side buttons

    /// The side buttons are split once per frame artwork, off the main
    /// thread, and only when asked to build: generated input (a 60x1000
    /// body whose right edge at x 29 bulges 8 px on rows 250–290 and
    /// 400–500, the power button and the rocker), not SDK artwork.
    @MainActor
    func testButtonArtIsSplitOnceOffTheMainThread() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Self.writeBody(to: directory.appendingPathComponent("back.png"), bulges: [250...290, 400...500])
        let (display, variant) = Self.variant(in: directory, width: 60, height: 1000)
        let calls = SplitCalls()
        let cache = SkinThumbnailCache(makeButtonArt: { url in
            calls.record(onMain: Thread.isMainThread)
            return LiveButtonArt.make(artworkURL: url)
        })

        XCTAssertNil(cache.buttonArt(for: variant, display: display, build: false))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(calls.count, 0, "nothing is split unless asked to build")

        XCTAssertNil(cache.buttonArt(for: variant, display: display), "not ready at once")
        let built = await cache.builtButtonArt(for: variant, display: display)
        let art = try XCTUnwrap(built)
        XCTAssertEqual(art.buttons.map(\.key), [.power, .volumeUp, .volumeDown])
        let again = try XCTUnwrap(cache.buttonArt(for: variant, display: display))
        XCTAssertTrue(again.background === art.background, "kept, not split again")
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.onMain, [false], "split off the main thread")
        // The artwork itself stays what the stage draws at rest.
        let background = try XCTUnwrap(cache.artwork(for: variant, display: display).background)
        XCTAssertFalse(background === art.background)
        XCTAssertEqual(background.artworkPixelSize, art.pixelSize)
    }

    /// A frame without buttons is scanned once and never again.
    @MainActor
    func testAFrameWithoutButtonsIsScannedOnce() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Self.writeBody(to: directory.appendingPathComponent("back.png"), bulges: [])
        let (display, variant) = Self.variant(in: directory, width: 60, height: 1000)
        let calls = SplitCalls()
        let cache = SkinThumbnailCache(makeButtonArt: { url in
            calls.record(onMain: Thread.isMainThread)
            return LiveButtonArt.make(artworkURL: url)
        })
        let none = await cache.builtButtonArt(for: variant, display: display)
        XCTAssertNil(none)
        XCTAssertNil(cache.buttonArt(for: variant, display: display))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(calls.count, 1)
    }

    /// A split holds a full-size bitmap of its frame, so only the splits of
    /// the variants last asked for are kept (here 2): a third variant drops
    /// the one least recently asked for, which is split again when it is
    /// asked for again, while one asked for since is kept. Generated input
    /// (the 60x1000 body with buttons, once in each of three directories).
    @MainActor
    func testOnlyTheSplitsLastAskedForAreKept() async throws {
        var directories: [URL] = []
        defer { directories.forEach { try? FileManager.default.removeItem(at: $0) } }
        var variants: [(SkinDisplay, SkinVariant)] = []
        for _ in 0..<3 {
            let directory = try Self.makeDirectory()
            directories.append(directory)
            try Self.writeBody(to: directory.appendingPathComponent("back.png"), bulges: [250...290, 400...500])
            variants.append(Self.variant(in: directory, width: 60, height: 1000))
        }
        let made = MadeSplits()
        let cache = SkinThumbnailCache(
            makeButtonArt: { url in
                made.record(url.deletingLastPathComponent().lastPathComponent)
                return LiveButtonArt.make(artworkURL: url)
            },
            buttonArtLimit: 2
        )
        let names = directories.map(\.lastPathComponent)
        func built(_ index: Int) async -> LiveButtonArt? {
            await cache.builtButtonArt(for: variants[index].1, display: variants[index].0)
        }
        func kept(_ index: Int) -> LiveButtonArt? {
            cache.buttonArt(for: variants[index].1, display: variants[index].0, build: false)
        }

        let first = await built(0)
        XCTAssertNotNil(first)
        let second = await built(1)
        XCTAssertNotNil(second)
        XCTAssertNotNil(kept(0), "the first asked for again")
        let third = await built(2)
        XCTAssertNotNil(third)
        XCTAssertEqual(made.names, [names[0], names[1], names[2]])
        XCTAssertTrue(kept(0)?.background === first?.background, "asked for since: kept")

        let again = await built(1)
        XCTAssertNotNil(again, "the least recently asked for was dropped and is split again")
        XCTAssertFalse(again?.background === second?.background)
        XCTAssertEqual(made.names, [names[0], names[1], names[2], names[1]])
    }

    /// The live split of the installed SDK's artwork (read in place, never
    /// copied; skipped without the SDK): drawn one pixel to one pixel, the
    /// buttons' sprites at rest under the frame without them give back the
    /// artwork's bytes exactly, whether the stage draws each key's piece or
    /// a group's joined one; a held key's piece has the same cover, 8 %
    /// darker.
    func testTheLiveSplitAtRestIsTheArtworkByteForByte() throws {
        for (skin, variant) in [("pixel_10_pro", nil), ("pixel_8", nil), ("pixel_9_pro_fold", "default")] as [(String, String?)] {
            let url = try Self.sdkArtwork(skin, variant: variant)
            let art = try XCTUnwrap(LiveButtonArt.make(artworkURL: url), skin)
            let width = Int(art.pixelSize.width)
            let height = Int(art.pixelSize.height)
            let original = try Self.rgba(url)
            XCTAssertEqual(original.count, width * height * 4, skin)

            let byKey = try Self.draw(width, height) { context in
                for piece in art.keys.values { Self.place(piece.sprite, at: piece.rect, height: height, in: context) }
                context.draw(art.art.base, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            XCTAssertTrue(art.groups.values.allSatisfy { $0[[]] != nil }, skin)
            let byGroup = try Self.draw(width, height) { context in
                for piece in art.groups.values.compactMap({ $0[[]] }) {
                    Self.place(piece.sprite, at: piece.rect, height: height, in: context)
                }
                context.draw(art.art.base, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            XCTAssertTrue(byKey == original, "\(skin): each key's sprite under the frame without them")
            XCTAssertTrue(byGroup == original, "\(skin): each group joined under the frame without them")

            for key in HardwareKey.allCases {
                let plain = try Self.rgba(XCTUnwrap(art.keys[key]?.sprite, "\(skin) \(key)"))
                let dark = try Self.rgba(XCTUnwrap(art.darkKeys[key]?.sprite, "\(skin) \(key)"))
                XCTAssertEqual(plain.count, dark.count)
                for index in plain.indices {
                    if index % 4 == 3 {
                        XCTAssertEqual(dark[index], plain[index], "\(skin) \(key): same cover")
                    } else {
                        XCTAssertEqual(Double(dark[index]), (Double(plain[index]) * 0.92).rounded(), accuracy: 0.5, "\(skin) \(key)")
                    }
                }
            }
            // The rocker joined with its upper half held: that half dark,
            // the lower plain.
            let rocker = try XCTUnwrap(art.groups[1]?[[.volumeUp]], skin)
            let up = try XCTUnwrap(art.darkKeys[.volumeUp])
            let down = try XCTUnwrap(art.keys[.volumeDown])
            let joined = try Self.rgba(rocker.sprite)
            let apart = try Self.draw(rocker.sprite.width, rocker.sprite.height) { context in
                for piece in [up, down] {
                    Self.place(
                        piece.sprite,
                        at: piece.rect.offsetBy(dx: -rocker.rect.minX, dy: -rocker.rect.minY),
                        height: rocker.sprite.height,
                        in: context
                    )
                }
            }
            XCTAssertTrue(joined == apart, "\(skin): the rocker joins its halves pixel for pixel")
        }
    }

    // MARK: - Helpers

    /// The directories whose frames were split, in order.
    private final class MadeSplits: @unchecked Sendable {
        private let lock = NSLock()
        private var made: [String] = []

        func record(_ name: String) {
            lock.withLock { made.append(name) }
        }

        var names: [String] { lock.withLock { made } }
    }

    private final class SplitCalls: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [Bool] = []

        func record(onMain: Bool) {
            lock.withLock { calls.append(onMain) }
        }

        var count: Int { lock.withLock { calls.count } }
        var onMain: [Bool] { lock.withLock { calls } }
    }

    private static func variant(in directory: URL, width: CGFloat, height: CGFloat) -> (SkinDisplay, SkinVariant) {
        let display = SkinDisplay(
            displaySize: CGSize(width: 20, height: 900), origin: CGPoint(x: 5, y: 50),
            layoutSize: CGSize(width: width, height: height),
            backgroundImage: "back.png", maskImage: nil, orientation: .portrait)
        let variant = SkinVariant(
            id: "default", directory: directory,
            layout: SkinLayoutFile(portrait: display, landscape: nil))
        return (display, variant)
    }

    /// A 60x1000 PNG: opaque grey up to x 29 on every row, reaching 8 px
    /// further on the `bulges` rows. Generated input, not device output.
    private static func writeBody(to url: URL, bulges: [ClosedRange<Int>]) throws {
        let width = 60
        let height = 1000
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32))
        let data = try XCTUnwrap(rep.bitmapData)
        for y in 0..<height {
            let edge = bulges.contains { $0.contains(y) } ? 37 : 29
            for x in 0...edge {
                let offset = (y * width + x) * 4
                data[offset] = 90
                data[offset + 1] = 90
                data[offset + 2] = 90
                data[offset + 3] = 255
            }
        }
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: url)
    }

    private static func sdkArtwork(_ name: String, variant id: String?) throws -> URL {
        guard let skins = SkinLocator.skinsDirectory() else { throw XCTSkip("no Android SDK skins directory") }
        guard let entry = SkinResolver.catalog(skinsDirectory: skins).first(where: { $0.name == name }) else {
            throw XCTSkip("\(name) is not installed")
        }
        let variant = try XCTUnwrap(id.map { id in entry.variants.first { $0.id == id } } ?? entry.preferredVariant)
        let display = try XCTUnwrap(variant.layout?.preferred)
        return variant.directory.appendingPathComponent(try XCTUnwrap(display.backgroundImage))
    }

    /// A file's or image's premultiplied sRGB RGBA bytes, drawn
    /// independently of the code under test.
    private static func rgba(_ url: URL) throws -> [UInt8] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try rgba(XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil)))
    }

    private static func rgba(_ image: CGImage) throws -> [UInt8] {
        try draw(image.width, image.height) { context in
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
    }

    private static func draw(_ width: Int, _ height: Int, _ body: (CGContext) -> Void) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.interpolationQuality = .none
            body(context)
        }
        return bytes
    }

    /// Draws `image` at a top-left artwork rect of a canvas `height` tall.
    private static func place(_ image: CGImage, at rect: CGRect, height: Int, in context: CGContext) {
        context.draw(image, in: CGRect(x: rect.minX, y: CGFloat(height) - rect.maxY, width: rect.width, height: rect.height))
    }

    private static func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("devicehubpro-skin-artwork-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func writePNG(to url: URL) throws {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        NSGraphicsContext.restoreGraphicsState()
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: url)
    }
}
