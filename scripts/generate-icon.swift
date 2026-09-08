import AppKit

// Original vector artwork, rendered at each required icon scale.
guard CommandLine.arguments.count == 2 else {
    fputs("Usage: generate-icon <output.iconset>\n", stderr)
    exit(2)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func drawIcon(pixels: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "LumaIcon", code: 1)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    defer { NSGraphicsContext.restoreGraphicsState() }
    let context = graphics.cgContext
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    let base = NSBezierPath(roundedRect: NSRect(x: 72, y: 72, width: 880, height: 880), xRadius: 194, yRadius: 194)
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28,
                      color: NSColor.black.withAlphaComponent(0.25).cgColor)
    NSColor(calibratedRed: 0.09, green: 0.13, blue: 0.23, alpha: 1).setFill()
    base.fill()
    context.setShadow(offset: .zero, blur: 0, color: nil)
    NSGradient(starting: NSColor(calibratedRed: 0.16, green: 0.20, blue: 0.35, alpha: 1),
               ending: NSColor(calibratedRed: 0.055, green: 0.08, blue: 0.15, alpha: 1))?.draw(in: base, angle: -90)
    let frame = NSBezierPath(roundedRect: NSRect(x: 252, y: 300, width: 520, height: 420), xRadius: 52, yRadius: 52)
    NSColor(calibratedRed: 0.32, green: 0.86, blue: 0.82, alpha: 1).setStroke()
    frame.lineWidth = 30
    frame.stroke()
    let lens = NSBezierPath(ovalIn: NSRect(x: 408, y: 406, width: 208, height: 208))
    NSColor(calibratedRed: 0.88, green: 0.96, blue: 1, alpha: 1).setFill()
    lens.fill()
    let inner = NSBezierPath(ovalIn: NSRect(x: 450, y: 448, width: 124, height: 124))
    NSColor(calibratedRed: 0.12, green: 0.18, blue: 0.29, alpha: 1).setFill()
    inner.fill()
    let corners: [[NSPoint]] = [
        [NSPoint(x: 176, y: 622), NSPoint(x: 176, y: 792), NSPoint(x: 346, y: 792)],
        [NSPoint(x: 678, y: 792), NSPoint(x: 848, y: 792), NSPoint(x: 848, y: 622)],
        [NSPoint(x: 176, y: 398), NSPoint(x: 176, y: 228), NSPoint(x: 346, y: 228)],
        [NSPoint(x: 678, y: 228), NSPoint(x: 848, y: 228), NSPoint(x: 848, y: 398)]
    ]
    NSColor.white.withAlphaComponent(0.95).setStroke()
    for points in corners {
        let path = NSBezierPath()
        path.move(to: points[0]); path.line(to: points[1]); path.line(to: points[2])
        path.lineWidth = 34; path.lineCapStyle = .round; path.lineJoinStyle = .round
        path.stroke()
    }
    NSColor(calibratedRed: 1, green: 0.35, blue: 0.43, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 676, y: 624, width: 52, height: 52)).fill()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "LumaIcon", code: 2)
    }
    return png
}

for pointSize in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        try drawIcon(pixels: pointSize * scale).write(to: output.appendingPathComponent("icon_\(pointSize)x\(pointSize)\(suffix).png"))
    }
}
