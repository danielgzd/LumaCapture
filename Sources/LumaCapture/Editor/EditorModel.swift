import AppKit
import CoreText
import ImageIO
import UniformTypeIdentifiers
import Vision

enum EditorTool: String, CaseIterable, Identifiable {
    case pen, arrow, rectangle, ellipse, highlight, text, redact, crop
    var id: String { rawValue }
    var title: String {
        switch self {
        case .pen: return "画笔"
        case .arrow: return "箭头"
        case .rectangle: return "矩形"
        case .ellipse: return "椭圆"
        case .highlight: return "高亮"
        case .text: return "文字"
        case .redact: return "遮挡"
        case .crop: return "裁剪"
        }
    }
    var symbol: String {
        switch self {
        case .pen: return "pencil.tip"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .highlight: return "highlighter"
        case .text: return "textformat"
        case .redact: return "rectangle.fill"
        case .crop: return "crop"
        }
    }
}

struct EditorAnnotation {
    var tool: EditorTool
    var points: [CGPoint]
    var color: NSColor
    var width: CGFloat
    var text: String = ""
    var fontSize: CGFloat = 36
    var bounds: CGRect {
        guard let first = points.first, let last = points.last else { return .zero }
        return CGRect(x: min(first.x, last.x), y: min(first.y, last.y),
                      width: abs(last.x - first.x), height: abs(last.y - first.y))
    }
}

struct EditorSnapshot {
    var annotations: [EditorAnnotation] = []
    var cropBounds: CGRect
}

/// History contains lightweight annotation/crop state; the original bitmap stays immutable.
struct EditorHistory {
    private(set) var current: EditorSnapshot
    private var past: [EditorSnapshot] = []
    private var future: [EditorSnapshot] = []
    var canUndo: Bool { !past.isEmpty }
    var canRedo: Bool { !future.isEmpty }

    init(imageSize: CGSize) { current = EditorSnapshot(cropBounds: CGRect(origin: .zero, size: imageSize)) }
    mutating func commit(_ snapshot: EditorSnapshot) {
        past.append(current)
        current = snapshot
        future.removeAll()
    }
    mutating func undo() {
        guard let previous = past.popLast() else { return }
        future.append(current)
        current = previous
    }
    mutating func redo() {
        guard let next = future.popLast() else { return }
        past.append(current)
        current = next
    }
}

enum EditorError: LocalizedError {
    case renderFailed, exportFailed, invalidCrop, selfCheck(String)
    var errorDescription: String? {
        switch self {
        case .renderFailed: return "无法生成编辑图像。请尝试关闭其他大型图像后重试。"
        case .exportFailed: return "无法保存图像。请检查目标目录的写入权限和可用磁盘空间。"
        case .invalidCrop: return "裁剪区域至少需要 2 × 2 像素。"
        case .selfCheck(let reason): return "编辑器自检失败：\(reason)"
        }
    }
}

enum EditorRenderer {
    /// All annotation coordinates use original-image pixels, with the origin at the upper left.
    /// Preview and exported files use this same renderer, including the exact opaque redaction.
    static func render(image: CGImage, snapshot: EditorSnapshot) throws -> CGImage {
        let crop = snapshot.cropBounds.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard crop.width >= 2, crop.height >= 2 else { throw EditorError.invalidCrop }
        let width = Int(crop.width), height = Int(crop.height)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw EditorError.renderFailed
        }
        context.interpolationQuality = .high
        // CGContext is bottom-up here. Position the source so a top-left crop stays pixel exact.
        context.draw(image, in: CGRect(x: -crop.minX, y: crop.maxY - CGFloat(image.height),
                                      width: CGFloat(image.width), height: CGFloat(image.height)))
        context.translateBy(x: -crop.minX, y: crop.maxY)
        context.scaleBy(x: 1, y: -1)
        draw(annotations: snapshot.annotations, in: context)
        guard let result = context.makeImage() else { throw EditorError.renderFailed }
        return result
    }

    static func draw(annotations: [EditorAnnotation], in context: CGContext) {
        for annotation in annotations {
            guard let start = annotation.points.first else { continue }
            let end = annotation.points.last ?? start
            context.saveGState()
            context.setShouldAntialias(true)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.setLineWidth(annotation.width)
            let color = annotation.color.usingColorSpace(.sRGB) ?? annotation.color
            context.setStrokeColor(color.withAlphaComponent(1).cgColor)
            context.setFillColor(color.withAlphaComponent(1).cgColor)
            switch annotation.tool {
            case .pen:
                if annotation.points.count == 1 {
                    context.fillEllipse(in: CGRect(x: start.x - annotation.width / 2, y: start.y - annotation.width / 2,
                                                  width: annotation.width, height: annotation.width))
                } else {
                    context.beginPath()
                    context.move(to: start)
                    for point in annotation.points.dropFirst() { context.addLine(to: point) }
                    context.strokePath()
                }
            case .arrow:
                let length = hypot(end.x - start.x, end.y - start.y)
                guard length > 0 else { context.restoreGState(); continue }
                let angle = atan2(end.y - start.y, end.x - start.x)
                let head = min(length * 0.65, max(14, annotation.width * 4))
                context.beginPath()
                context.move(to: start)
                context.addLine(to: end)
                context.strokePath()
                context.beginPath()
                context.move(to: end)
                context.addLine(to: CGPoint(x: end.x - head * cos(angle - .pi / 6), y: end.y - head * sin(angle - .pi / 6)))
                context.addLine(to: CGPoint(x: end.x - head * cos(angle + .pi / 6), y: end.y - head * sin(angle + .pi / 6)))
                context.closePath()
                context.fillPath()
            case .rectangle:
                context.stroke(annotation.bounds)
            case .ellipse:
                context.strokeEllipse(in: annotation.bounds)
            case .highlight:
                context.setFillColor(color.withAlphaComponent(0.3).cgColor)
                context.fill(annotation.bounds)
            case .redact:
                // A solid black fill hides underlying pixels. This is deliberately not blur/pixelation.
                context.setShouldAntialias(false)
                context.setBlendMode(.copy)
                context.setFillColor(NSColor.black.cgColor)
                context.fill(annotation.bounds.integral)
            case .text:
                let font = CTFontCreateWithName("Helvetica-Bold" as CFString, annotation.fontSize, nil)
                let attributes: [NSAttributedString.Key: Any] = [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor
                ]
                for (index, line) in annotation.text.components(separatedBy: .newlines).enumerated() {
                    context.saveGState()
                    context.translateBy(x: start.x, y: start.y + CTFontGetAscent(font) + CGFloat(index) * annotation.fontSize * 1.25)
                    context.scaleBy(x: 1, y: -1)
                    context.textMatrix = .identity
                    context.textPosition = .zero
                    CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: attributes)), context)
                    context.restoreGState()
                }
            case .crop: break
            }
            context.restoreGState()
        }
    }

    static func save(image: CGImage, to url: URL, jpeg: Bool) throws {
        let type = jpeg ? UTType.jpeg.identifier : UTType.png.identifier
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else {
            throw EditorError.exportFailed
        }
        var exportedImage = image
        if jpeg {
            // JPEG has no alpha; composite transparent pixels on white rather than turning them black.
            guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw EditorError.renderFailed }
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard let flattened = context.makeImage() else { throw EditorError.renderFailed }
            exportedImage = flattened
        }
        CGImageDestinationAddImage(destination, exportedImage,
                                  [kCGImageDestinationLossyCompressionQuality: 0.94] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw EditorError.exportFailed }
        try (data as Data).write(to: url, options: .atomic)
    }
}

enum EditorOCR {
    static func recognize(image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        // Revision 3 is available throughout the supported macOS range and has
        // stable offline Chinese/English support. Newer OS-default revisions can
        // require assets that are not yet present on a freshly installed Mac.
        request.revision = VNRecognizeTextRequestRevision3
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    static func recognizeAsync(image: CGImage) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try recognize(image: image)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}

@MainActor
final class EditorDocument: ObservableObject {
    let originalImage: CGImage
    let sourceURL: URL?
    let onExport: (URL) -> Void
    @Published var history: EditorHistory
    @Published var preview: CGImage
    @Published var tool: EditorTool = .arrow
    @Published var color: NSColor = .systemRed
    @Published var strokeWidth: Double = 6
    @Published var fontSize: Double = 36
    @Published var text = "标注文字"
    @Published var status = "选择工具，在图像上拖动即可标注。"
    @Published var errorMessage: String?
    @Published var isRecognizing = false
    @Published var ocrText = ""
    @Published var showsOCR = false
    @Published var zoom: Double = 0 // 0 means fit; otherwise image pixels per view point.

    init(image: CGImage, sourceURL: URL?, onExport: @escaping (URL) -> Void) {
        self.originalImage = image
        self.preview = image
        self.sourceURL = sourceURL
        self.onExport = onExport
        self.history = EditorHistory(imageSize: CGSize(width: image.width, height: image.height))
    }

    func commit(_ annotation: EditorAnnotation) {
        var next = history.current
        if annotation.tool == .crop {
            let bounds = annotation.bounds.integral.intersection(next.cropBounds)
            guard bounds.width >= 2, bounds.height >= 2 else { status = "裁剪已取消：区域至少需要 2 × 2 像素。"; return }
            next.cropBounds = bounds
        } else {
            next.annotations.append(annotation)
        }
        history.commit(next)
        refreshPreview()
        status = annotation.tool == .crop ? "已裁剪；可撤销恢复完整图像。" : "已添加\(annotation.tool.title)。"
    }

    func undo() { history.undo(); refreshPreview(); status = "已撤销。" }
    func redo() { history.redo(); refreshPreview(); status = "已重做。" }

    private func refreshPreview() {
        do { preview = try EditorRenderer.render(image: originalImage, snapshot: history.current) }
        catch { errorMessage = error.localizedDescription }
    }

    func copyImage() {
        let image = NSImage(cgImage: preview, size: NSSize(width: preview.width, height: preview.height))
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.writeObjects([image]) { status = "已复制当前图像（\(preview.width) × \(preview.height) 像素）。" }
        else { errorMessage = "复制失败，请稍后重试。" }
    }

    func recognizeText() {
        guard !isRecognizing else { return }
        isRecognizing = true
        let image = preview
        Task { [weak self] in
            do {
                let result = try await EditorOCR.recognizeAsync(image: image)
                guard let self else { return }
                self.ocrText = result
                self.showsOCR = true
                self.status = result.isEmpty ? "未识别到文字。请尝试更清晰或更大的截图。" : "文字识别完成，所有处理均在本机进行。"
                self.isRecognizing = false
            } catch {
                self?.isRecognizing = false
                self?.errorMessage = "文字识别失败：\(error.localizedDescription)"
            }
        }
    }

    func save(jpeg: Bool, window: NSWindow?) {
        let panel = NSSavePanel()
        panel.title = jpeg ? "另存为 JPEG" : "另存为 PNG"
        panel.allowedContentTypes = [jpeg ? .jpeg : .png]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.directoryURL = sourceURL?.deletingLastPathComponent()
        let basename = sourceURL?.deletingPathExtension().lastPathComponent ?? "LumaCapture"
        panel.nameFieldStringValue = basename + "-已编辑." + (jpeg ? "jpg" : "png")
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                try EditorRenderer.save(image: self.preview, to: url, jpeg: jpeg)
                self.status = "已保存：\(url.lastPathComponent)"
                self.onExport(url)
            } catch { self.errorMessage = error.localizedDescription }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) }
        else { panel.begin(completionHandler: finish) }
    }
}
