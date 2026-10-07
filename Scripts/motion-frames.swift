// motion-frames.swift — frame-level analysis of a window recording.
//
// Reads a video with AVAssetReader, computes a per-frame change metric
// (mean absolute difference of a downsampled grayscale grid between
// consecutive frames), finds the motion window (first/last frame above the
// threshold), prints the velocity profile and optionally writes a frame strip
// and the selected frames as PNGs.
//
// Usage:
//   motion-frames <video> [--threshold T] [--strip out.png] [--frames dir]
//                         [--max-frames N] [--quiet]
//
// Output (stdout):
//   f=<index> t=<seconds> diff=<0..1>
//   ...
//   motion: start=<t> end=<t> duration=<ms> peak=<t> frames=<n>
//   profile: <n> buckets of normalized velocity, one per line
//
// Exit status: 0 ok, 1 no motion found, 2 error.

import AVFoundation
import AppKit
import Foundation

struct Options {
    var video: URL
    var threshold = 0.01
    var strip: URL?
    var framesDir: URL?
    var maxFrames = 12
    var quiet = false
    var range: (start: Double, end: Double)?
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("motion-frames: \(message)\n".utf8))
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
guard !args.isEmpty else {
    fail("usage: motion-frames <video> [--threshold T] [--strip out.png] [--frames dir] [--max-frames N] [--quiet]")
}

var options: Options?
while let arg = args.first {
    args.removeFirst()
    switch arg {
    case "--threshold":
        guard let value = args.first, let parsed = Double(value) else { fail("--threshold needs a number") }
        args.removeFirst()
        options?.threshold = parsed
    case "--strip":
        guard let value = args.first else { fail("--strip needs a path") }
        args.removeFirst()
        options?.strip = URL(fileURLWithPath: value)
    case "--frames":
        guard let value = args.first else { fail("--frames needs a directory") }
        args.removeFirst()
        options?.framesDir = URL(fileURLWithPath: value)
    case "--max-frames":
        guard let value = args.first, let parsed = Int(value) else { fail("--max-frames needs an integer") }
        args.removeFirst()
        options?.maxFrames = max(2, parsed)
    case "--quiet":
        options?.quiet = true
    case "--range":
        guard let value = args.first else { fail("--range needs start,end") }
        args.removeFirst()
        let parts = value.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else { fail("--range needs start,end") }
        options?.range = (start: parts[0], end: parts[1])
    default:
        guard options == nil else { fail("unexpected argument \(arg)") }
        options = Options(video: URL(fileURLWithPath: arg))
    }
}

guard let options else { fail("no video given") }
let video = options.video

let asset = AVURLAsset(url: video)
guard let track = asset.tracks(withMediaType: .video).first else {
    fail("no video track in \(video.path)")
}

let gridWidth = 64
let gridHeight = 36

/// Mean absolute difference between two grayscale grids, 0...1.
func diff(_ a: [Double], _ b: [Double]) -> Double {
    guard a.count == b.count, !a.isEmpty else { return 0 }
    var total = 0.0
    for index in a.indices {
        total += abs(a[index] - b[index])
    }
    return total / Double(a.count)
}

/// Downsamples a BGRA pixel buffer to a normalized grayscale grid.
func grid(from pixelBuffer: CVPixelBuffer) -> [Double]? {
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    guard width >= gridWidth, height >= gridHeight else { return nil }
    let pixels = base.assumingMemoryBound(to: UInt8.self)
    var values = [Double](repeating: 0, count: gridWidth * gridHeight)
    let cellWidth = width / gridWidth
    let cellHeight = height / gridHeight
    for gy in 0..<gridHeight {
        for gx in 0..<gridWidth {
            var sum = 0.0
            var count = 0.0
            let startX = gx * cellWidth
            let startY = gy * cellHeight
            var y = startY
            while y < startY + cellHeight {
                var x = startX
                let row = pixels + y * bytesPerRow
                while x < startX + cellWidth {
                    let pixel = row + x * 4
                    let b = Double(pixel[0])
                    let g = Double(pixel[1])
                    let r = Double(pixel[2])
                    sum += (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255.0
                    count += 1
                    x += 2
                }
                y += 2
            }
            values[gy * gridWidth + gx] = count > 0 ? sum / count : 0
        }
    }
    return values
}

guard let reader = try? AVAssetReader(asset: asset) else {
    fail("could not create an asset reader")
}
let output = AVAssetReaderTrackOutput(
    track: track,
    outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
)
output.alwaysCopiesSampleData = false
guard reader.canAdd(output) else { fail("could not add the reader output") }
reader.add(output)
guard reader.startReading() else {
    fail("reader failed to start: \(reader.error.map(String.init(describing:)) ?? "unknown")")
}

struct Sample {
    var time: Double
    var diff: Double
    var grid: [Double]
}

var samples: [Sample] = []
var previous: [Double]?
var index = 0
while let sampleBuffer = output.copyNextSampleBuffer() {
    let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
       let values = grid(from: pixelBuffer) {
        let delta = previous.map { diff($0, values) } ?? 0
        samples.append(Sample(time: time, diff: delta, grid: values))
        previous = values
    }
    index += 1
    if index > 60 * 60 { break }
}
guard samples.count > 2 else { fail("fewer than three frames read") }

if let range = options.range {
    samples = samples.filter { $0.time >= range.start && $0.time <= range.end }
    guard samples.count > 2 else { fail("fewer than three frames in the requested range") }
}

let motionIndices = samples.indices.filter { samples[$0].diff >= options.threshold }
guard let first = motionIndices.first, let last = motionIndices.last, last > first else {
    print("motion: none (threshold \(options.threshold))")
    exit(1)
}

let start = samples[first].time
let end = samples[last].time
let duration = end - start
let peak = samples.max(by: { $0.diff < $1.diff })?.time ?? start

if !options.quiet {
    for (i, sample) in samples.enumerated() {
        print(String(format: "f=%d t=%.4f diff=%.5f", i, sample.time, sample.diff))
    }
}
print(String(format: "motion: start=%.4f end=%.4f duration=%.1fms peak=%.4f frames=%d",
             start, end, duration * 1000, peak, last - first + 1))

// Velocity profile: the motion window split into 10 buckets, each the mean
// diff of its frames normalized against the peak bucket.
let bucketCount = 10
let span = max(last - first + 1, 1)
var buckets = [Double](repeating: 0, count: bucketCount)
var counts = [Int](repeating: 0, count: bucketCount)
for i in first...last {
    let bucket = min(bucketCount - 1, (i - first) * bucketCount / span)
    buckets[bucket] += samples[i].diff
    counts[bucket] += 1
}
let bucketMeans = zip(buckets, counts).map { $1 > 0 ? $0 / Double($1) : 0 }
let peakMean = bucketMeans.max() ?? 1
let profile = bucketMeans.map { peakMean > 0 ? $0 / peakMean : 0 }
print("profile: " + profile.map { String(format: "%.2f", $0) }.joined(separator: " "))

// Strip + frames for the evidence trail.
func writeImage(_ image: CGImage, to url: URL) {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else { return }
    try? data.write(to: url)
}

let selected: [Int] = {
    if options.maxFrames >= (last - first + 1) {
        return Array(first...last)
    }
    return (0..<options.maxFrames).map { step in
        first + step * (last - first) / (options.maxFrames - 1)
    }
}()

if options.strip != nil || options.framesDir != nil {
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero

    var images: [(time: Double, image: CGImage)] = []
    for i in selected {
        let time = CMTime(seconds: samples[i].time, preferredTimescale: 600)
        if let image = try? generator.copyCGImage(at: time, actualTime: nil) {
            images.append((samples[i].time, image))
        }
    }

    if let framesDir = options.framesDir {
        try? FileManager.default.createDirectory(at: framesDir, withIntermediateDirectories: true)
        for (i, entry) in images.enumerated() {
            let name = String(format: "frame-%02d-t%.3f.png", i, entry.time)
            writeImage(entry.image, to: framesDir.appendingPathComponent(name))
        }
    }

    if let strip = options.strip, !images.isEmpty {
        let gap = 8
        let totalWidth = images.reduce(0) { $0 + $1.image.width } + gap * (images.count - 1)
        let totalHeight = images.map(\.image.height).max() ?? 0
        guard let context = CGContext(
            data: nil,
            width: totalWidth,
            height: totalHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { fail("could not create the strip context") }
        context.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: totalWidth, height: totalHeight))
        var x = 0
        for entry in images {
            context.draw(entry.image, in: CGRect(x: x, y: 0, width: entry.image.width, height: entry.image.height))
            x += entry.image.width + gap
        }
        if let stripImage = context.makeImage() {
            writeImage(stripImage, to: strip)
        }
    }
}
