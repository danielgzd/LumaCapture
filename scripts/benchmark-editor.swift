import AppKit
import Darwin

/// Measures the shipping export renderer, not a substitute implementation.
/// Timings are a local baseline, not a claim about interaction latency on every Mac.
@main
enum EditorBenchmark {
    struct Result: Codable {
        let osVersion: String
        let processorCount: Int
        let sourceWidth: Int
        let sourceHeight: Int
        let annotationCount: Int
        let freehandPointCount: Int
        let iterations: Int
        let renderMilliseconds: [Double]
        let medianRenderMilliseconds: Double
        let p95RenderMilliseconds: Double
        let pngExportMilliseconds: Double
        let jpegExportMilliseconds: Double
        let peakResidentMegabytes: Double
        let pngBytes: Int
        let jpegBytes: Int
    }

    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw EditorError.selfCheck("benchmark-editor requires an output directory")
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let width = 3840, height = 2160
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw EditorError.renderFailed }
        for row in 0..<24 {
            for column in 0..<40 {
                context.setFillColor(NSColor(calibratedHue: CGFloat(row + column) / 64,
                    saturation: 0.13, brightness: 0.92, alpha: 1).cgColor)
                context.fill(CGRect(x: column * 96, y: row * 90, width: 96, height: 90))
            }
        }
        guard let image = context.makeImage() else { throw EditorError.renderFailed }
        var annotations: [EditorAnnotation] = []
        for stroke in 0..<40 {
            var points: [CGPoint] = []
            points.reserveCapacity(250)
            for point in 0..<250 {
                let x = CGFloat(40) + CGFloat(point) * CGFloat(14.5)
                let wave = sin(CGFloat(point) / CGFloat(12)) * CGFloat(20)
                let y = CGFloat(50) + CGFloat(stroke) * CGFloat(50) + wave
                points.append(CGPoint(x: x, y: y))
            }
            annotations.append(EditorAnnotation(tool: .pen, points: points, color: .systemRed, width: 6))
        }
        let tools: [EditorTool] = [.arrow, .rectangle, .ellipse, .highlight, .redact]
        for index in 0..<30 {
            let start = CGPoint(x: 80 + (index % 10) * 360, y: 150 + (index / 10) * 600)
            annotations.append(EditorAnnotation(tool: tools[index % tools.count],
                points: [start, CGPoint(x: start.x + 160, y: start.y + 160)], color: .systemBlue, width: 8))
        }
        for index in 0..<10 {
            annotations.append(EditorAnnotation(tool: .text,
                points: [CGPoint(x: 100 + index * 350, y: 1900)], color: .black,
                width: 4, text: "Luma \(index)", fontSize: 42))
        }
        let snapshot = EditorSnapshot(annotations: annotations, cropBounds: CGRect(x: 0, y: 0, width: width, height: height))
        // Warm CoreText and color conversion caches before measurement.
        try autoreleasepool { _ = try EditorRenderer.render(image: image, snapshot: snapshot) }
        var timings: [Double] = []
        for _ in 0..<9 {
            let elapsed = try measure {
                try autoreleasepool {
                    let rendered = try EditorRenderer.render(image: image, snapshot: snapshot)
                    guard rendered.width == width && rendered.height == height else { throw EditorError.renderFailed }
                }
            }
            timings.append(elapsed)
        }
        let rendered = try EditorRenderer.render(image: image, snapshot: snapshot)
        let png = output.appendingPathComponent("benchmark-4k.png")
        let jpeg = output.appendingPathComponent("benchmark-4k.jpg")
        let pngTime = try measure { try EditorRenderer.save(image: rendered, to: png, jpeg: false) }
        let jpegTime = try measure { try EditorRenderer.save(image: rendered, to: jpeg, jpeg: true) }
        var usage = rusage()
        _ = getrusage(RUSAGE_SELF, &usage)
        let sorted = timings.sorted()
        let median = sorted[sorted.count / 2]
        let p95 = sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1]
        let result = Result(osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            processorCount: ProcessInfo.processInfo.processorCount, sourceWidth: width, sourceHeight: height,
            annotationCount: annotations.count, freehandPointCount: 10_000, iterations: timings.count,
            renderMilliseconds: timings, medianRenderMilliseconds: median, p95RenderMilliseconds: p95,
            pngExportMilliseconds: pngTime, jpegExportMilliseconds: jpegTime,
            peakResidentMegabytes: Double(usage.ru_maxrss) / (1024 * 1024),
            pngBytes: try Data(contentsOf: png).count, jpegBytes: try Data(contentsOf: jpeg).count)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(result).write(to: output.appendingPathComponent("editor-benchmark.json"), options: .atomic)
        print("4K synthetic image · \(annotations.count) annotations · 10,000 freehand points · \(timings.count) iterations")
        print(String(format: "Render median %.1f ms · p95 %.1f ms", median, p95))
        print(String(format: "PNG %.1f ms · JPEG %.1f ms · process peak RSS %.1f MB", pngTime, jpegTime, result.peakResidentMegabytes))
        print("Report: \(output.appendingPathComponent("editor-benchmark.json").path)")
        // A generous ceiling detects catastrophic regressions on shared CI;
        // recorded timings remain the evidence for hardware-specific comparisons.
        guard median < 3000 else { throw EditorError.selfCheck("4K render median exceeded the 3-second regression ceiling") }
    }

    private static func measure(_ work: () throws -> Void) rethrows -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        try work()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }
}
