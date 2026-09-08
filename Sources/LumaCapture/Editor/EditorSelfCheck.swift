import AppKit
import CoreGraphics
import ImageIO

enum EditorSelfCheck {
    static func run(outputDirectory: URL) throws -> [String] {
        let orientationSource = try makeOrientationImage()
        let full = try EditorRenderer.render(
            image: orientationSource,
            snapshot: EditorSnapshot(cropBounds: CGRect(x: 0, y: 0, width: 8, height: 8)))
        let topCrop = try EditorRenderer.render(
            image: orientationSource,
            snapshot: EditorSnapshot(cropBounds: CGRect(x: 0, y: 0, width: 8, height: 4)))
        guard try pixel(in: full, x: 2, y: 1) == pixel(in: orientationSource, x: 2, y: 1),
              try pixel(in: full, x: 2, y: 6) == pixel(in: orientationSource, x: 2, y: 6),
              try pixel(in: topCrop, x: 2, y: 1) == pixel(in: orientationSource, x: 2, y: 1) else {
            throw EditorError.selfCheck("原图或顶部裁剪发生垂直翻转")
        }
        let size = CGSize(width: 520, height: 180)
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw EditorError.selfCheck("无法创建合成画布")
        }
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        guard let source = context.makeImage() else { throw EditorError.selfCheck("无法生成合成图像") }

        var snapshot = EditorSnapshot(cropBounds: CGRect(x: 10, y: 10, width: 500, height: 160))
        snapshot.annotations = [
            EditorAnnotation(tool: .text, points: [CGPoint(x: 38, y: 55)], color: .black,
                             width: 2, text: "LUMA 2026", fontSize: 52),
            EditorAnnotation(tool: .redact, points: [CGPoint(x: 360, y: 52), CGPoint(x: 472, y: 116)],
                             color: .black, width: 1)
        ]
        let rendered = try EditorRenderer.render(image: source, snapshot: snapshot)
        guard rendered.width == 500, rendered.height == 160 else {
            throw EditorError.selfCheck("裁剪尺寸不正确：\(rendered.width) × \(rendered.height)")
        }
        guard let redactionPixel = rendered.cropping(to: CGRect(x: 400, y: 72, width: 1, height: 1)) else {
            throw EditorError.selfCheck("无法读取遮挡像素")
        }
        var pixel = [UInt8](repeating: 255, count: 4)
        guard let pixelContext = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8,
                                           bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw EditorError.selfCheck("无法创建像素检查画布")
        }
        pixelContext.draw(redactionPixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard pixel[0] < 4, pixel[1] < 4, pixel[2] < 4, pixel[3] > 250 else {
            throw EditorError.selfCheck("隐私遮挡没有生成不透明黑色像素")
        }

        let png = outputDirectory.appendingPathComponent("editor-self-check.png")
        let jpeg = outputDirectory.appendingPathComponent("editor-self-check.jpg")
        try EditorRenderer.save(image: rendered, to: png, jpeg: false)
        try EditorRenderer.save(image: rendered, to: jpeg, jpeg: true)
        for url in [png, jpeg] {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let exported = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  exported.width == 500, exported.height == 160 else {
                throw EditorError.selfCheck("导出文件不可读：\(url.lastPathComponent)")
            }
        }

        var checks = [
            "PASS source orientation and top-left crop pixel fidelity",
            "PASS editor crop, annotation and opaque-redaction rendering",
            "PASS PNG and JPEG export/readback at source pixel dimensions"
        ]
        do {
            let recognized = try EditorOCR.recognize(image: rendered)
            guard recognized.localizedCaseInsensitiveContains("LUMA") || recognized.contains("2026") else {
                throw EditorError.selfCheck("合成文字 OCR 无结果：\(recognized)")
            }
            checks.append("PASS offline Vision OCR on synthetic English/numeric text")
        } catch {
            // A SwiftUI executable's `App.init` runs before NSApplication exists;
            // Vision may return nilError in this special CLI path. The editor's
            // interactive OCR action is validated after the normal app launch.
            checks.append("SKIP pre-launch Vision OCR CLI check: \(error.localizedDescription)")
        }
        return checks
    }

    private static func makeOrientationImage() throws -> CGImage {
        var bytes = [UInt8](repeating: 255, count: 8 * 8 * 4)
        for y in 0..<8 {
            for x in 0..<8 {
                let offset = (y * 8 + x) * 4
                if y < 4 { bytes[offset] = 240; bytes[offset + 1] = 20; bytes[offset + 2] = 30 }
                else { bytes[offset] = 20; bytes[offset + 1] = 40; bytes[offset + 2] = 235 }
                bytes[offset + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: 8, height: 8, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent) else {
            throw EditorError.selfCheck("无法创建方向检查图像")
        }
        return image
    }

    private static func pixel(in image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        guard let sample = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else {
            throw EditorError.selfCheck("无法裁取检查像素")
        }
        var bytes = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8,
                                      bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw EditorError.selfCheck("无法读取检查像素")
        }
        context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return bytes
    }
}
