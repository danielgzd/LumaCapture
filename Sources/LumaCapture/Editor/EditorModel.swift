import AppKit
import CoreText
import ImageIO
import UniformTypeIdentifiers
import Vision

enum EditorTool: String, CaseIterable, Identifiable {
    case pen, arrow, rectangle, ellipse, highlight, text, redact, crop, image
    var id: String { rawValue }
    var title: String {
        switch self {
        case .pen: return "画笔"
        case .arrow: return "箭头"
        case .rectangle: return "矩形"
        case .ellipse: return "椭圆"
        case .highlight: return "高亮"
        case .text: return "文字"
        case .redact: return "马赛克"
        case .crop: return "裁剪"
        case .image: return "贴图"
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
        case .redact: return "square.grid.3x3.fill"
        case .crop: return "crop"
        case .image: return "photo.badge.plus"
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
    var isBold = false
    var cornerRadius: CGFloat = 0
    var embeddedImage: CGImage? = nil
    var rotationDegrees: CGFloat = 0
    var strokePath: CGPath? = nil
    var bounds: CGRect {
        guard let first = points.first, let last = points.last else { return .zero }
        return CGRect(x: min(first.x, last.x), y: min(first.y, last.y),
                      width: abs(last.x - first.x), height: abs(last.y - first.y))
    }
}

struct EditorSnapshot {
    var annotations: [EditorAnnotation] = []
    var cropBounds: CGRect
    var rotationQuarterTurns: Int = 0
    var imageScale: CGFloat = 1
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
    /// Preview and exported files use the same coordinates and irreversible mosaic renderer.
    static func render(image: CGImage, snapshot: EditorSnapshot, maxPixelDimension: Int? = nil) throws -> CGImage {
        let crop = snapshot.cropBounds.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard crop.width >= 2, crop.height >= 2 else { throw EditorError.invalidCrop }
        let scale = maxPixelDimension.map { min(1, CGFloat(max(1, $0)) / max(crop.width, crop.height)) } ?? 1
        let quarterTurns = ((snapshot.rotationQuarterTurns % 4) + 4) % 4
        let documentScale = max(0.1, min(4, snapshot.imageScale))
        let rotatedSize = quarterTurns.isMultiple(of: 2) ? crop.size : CGSize(width: crop.height, height: crop.width)
        let width = max(1, Int((rotatedSize.width * scale * documentScale).rounded()))
        let height = max(1, Int((rotatedSize.height * scale * documentScale).rounded()))
        let baseWidth = max(1, Int((crop.width * scale).rounded()))
        let baseHeight = max(1, Int((crop.height * scale).rounded()))
        guard let base = CGContext(data: nil, width: baseWidth, height: baseHeight, bitsPerComponent: 8,
                                   bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw EditorError.renderFailed }
        base.interpolationQuality = .high
        base.scaleBy(x: CGFloat(baseWidth) / crop.width, y: CGFloat(baseHeight) / crop.height)
        base.draw(image, in: CGRect(x: -crop.minX, y: crop.maxY - CGFloat(image.height), width: CGFloat(image.width), height: CGFloat(image.height)))
        base.translateBy(x: -crop.minX, y: crop.maxY)
        base.scaleBy(x: 1, y: -1)
        draw(annotations: snapshot.annotations, sourceImage: image, in: base)
        guard let composed = base.makeImage() else { throw EditorError.renderFailed }
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw EditorError.renderFailed
        }
        context.interpolationQuality = .high
        context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        context.rotate(by: -CGFloat(quarterTurns) * .pi / 2)
        let drawWidth = CGFloat(baseWidth) * documentScale
        let drawHeight = CGFloat(baseHeight) * documentScale
        context.draw(composed, in: CGRect(x: -drawWidth / 2, y: -drawHeight / 2, width: drawWidth, height: drawHeight))
        guard let result = context.makeImage() else { throw EditorError.renderFailed }
        return result
    }

    static func draw(annotations: [EditorAnnotation], sourceImage: CGImage? = nil, in context: CGContext) {
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
                    if let path = annotation.strokePath { context.addPath(path) }
                    else {
                        context.move(to: start)
                        for point in annotation.points.dropFirst() { context.addLine(to: point) }
                    }
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
                let radius = min(annotation.cornerRadius, min(annotation.bounds.width, annotation.bounds.height) / 2)
                context.addPath(CGPath(roundedRect: annotation.bounds, cornerWidth: radius, cornerHeight: radius, transform: nil))
                context.strokePath()
            case .ellipse:
                context.strokeEllipse(in: annotation.bounds)
            case .highlight:
                context.setFillColor(color.withAlphaComponent(0.3).cgColor)
                context.fill(annotation.bounds)
            case .redact:
                if let sourceImage { drawMosaic(source: sourceImage, bounds: annotation.bounds, in: context) }
            case .text:
                let font = CTFontCreateWithName((annotation.isBold ? "Helvetica-Bold" : "Helvetica") as CFString, annotation.fontSize, nil)
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
            case .image:
                if let image = annotation.embeddedImage {
                    let bounds = annotation.bounds
                    context.translateBy(x: bounds.midX, y: bounds.midY)
                    context.rotate(by: annotation.rotationDegrees * .pi / 180)
                    context.translateBy(x: -bounds.midX, y: -bounds.midY)
                    context.saveGState()
                    context.translateBy(x: bounds.minX, y: bounds.maxY)
                    context.scaleBy(x: 1, y: -1)
                    context.draw(image, in: CGRect(origin: .zero, size: bounds.size))
                    context.restoreGState()
                }
            case .crop: break
            }
            context.restoreGState()
        }
    }

    private static func drawMosaic(source: CGImage, bounds: CGRect, in context: CGContext) {
        let region = bounds.integral.intersection(CGRect(x: 0, y: 0, width: source.width, height: source.height))
        guard region.width >= 2, region.height >= 2, let cropped = source.cropping(to: region) else { return }
        let block: CGFloat = 12
        let smallWidth = max(1, Int(ceil(region.width / block)))
        let smallHeight = max(1, Int(ceil(region.height / block)))
        guard let small = CGContext(data: nil, width: smallWidth, height: smallHeight, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        small.interpolationQuality = .low
        small.draw(cropped, in: CGRect(x: 0, y: 0, width: smallWidth, height: smallHeight))
        guard let pixels = small.makeImage() else { return }
        context.saveGState()
        context.interpolationQuality = .none
        context.translateBy(x: region.minX, y: region.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(pixels, in: CGRect(origin: .zero, size: region.size))
        context.restoreGState()
    }

    static func save(image: CGImage, to url: URL, jpeg: Bool) throws {
        try encodedData(image: image, jpeg: jpeg).write(to: url, options: .atomic)
    }

    static func encodedData(image: CGImage, jpeg: Bool) throws -> Data {
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
        return data as Data
    }
}

/// Serialize full-resolution work so repeated export clicks cannot allocate many full-size bitmaps.
/// The canvas does not use this queue while drawing annotations.
enum EditorRenderWorker {
    private static let queue = DispatchQueue(label: "LumaCapture.editor.render", qos: .userInitiated)

    static func image(_ source: CGImage, snapshot: EditorSnapshot, maxPixelDimension: Int? = nil) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let result = try autoreleasepool {
                        try EditorRenderer.render(image: source, snapshot: snapshot, maxPixelDimension: maxPixelDimension)
                    }
                    continuation.resume(returning: result)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    static func save(_ source: CGImage, snapshot: EditorSnapshot, to url: URL, jpeg: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try autoreleasepool {
                        let image = try EditorRenderer.render(image: source, snapshot: snapshot)
                        try EditorRenderer.save(image: image, to: url, jpeg: jpeg)
                    }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    static func png(_ source: CGImage, snapshot: EditorSnapshot) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let data = try autoreleasepool {
                        let image = try EditorRenderer.render(image: source, snapshot: snapshot)
                        return try EditorRenderer.encodedData(image: image, jpeg: false)
                    }
                    continuation.resume(returning: data)
                } catch { continuation.resume(throwing: error) }
            }
        }
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

enum EditorBarcode {
    static func recognize(image: CGImage) async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNDetectBarcodesRequest()
                request.symbologies = [.qr]
                do {
                    try VNImageRequestHandler(cgImage: image).perform([request])
                    continuation.resume(returning: (request.results ?? []).compactMap(\.payloadStringValue))
                } catch { continuation.resume(throwing: error) }
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
    /// Downsampled, unannotated original. The canvas overlays vector annotations directly.
    /// Never use this bitmap for exports; output always renders an immutable document snapshot.
    @Published private(set) var preview: CGImage
    @Published var tool: EditorTool? = nil
    @Published var color: NSColor = .systemRed
    @Published var strokeWidth: Double = 6
    @Published var fontSize: Double = 36
    @Published var text = ""
    @Published var isBold = false
    @Published var rectangleCornerRadius: Double = 0
    @Published var stickerScale: Double = 1
    @Published var stickerRotation: Double = 0
    @Published private(set) var selectedStickerIndex: Int?
    @Published var status = "请选择工具，或直接保存当前图像。"
    @Published var errorMessage: String?
    @Published var isRecognizing = false
    @Published private(set) var isExporting = false
    @Published var ocrText = ""
    @Published var showsOCR = false
    @Published var qrResults: [String] = []
    @Published var showsQR = false
    @Published var base64Text = ""
    @Published var showsBase64 = false
    @Published var base64ModeIsDecode = false
    @Published var pendingTextPoint: CGPoint?
    @Published var showsTextEntry = false
    @Published var zoom: Double = 0 // 0 means fit; otherwise image pixels per view point.
    var outputSize: CGSize {
        let size = history.current.cropBounds.size
        let rotated = history.current.rotationQuarterTurns.isMultiple(of: 2) ? size : CGSize(width: size.height, height: size.width)
        return CGSize(width: rotated.width * history.current.imageScale, height: rotated.height * history.current.imageScale)
    }

    init(image: CGImage, sourceURL: URL?, onExport: @escaping (URL) -> Void) {
        self.originalImage = image
        self.preview = image
        self.sourceURL = sourceURL
        self.onExport = onExport
        self.history = EditorHistory(imageSize: CGSize(width: image.width, height: image.height))
        // Large Retina captures get one display cache, not a new full-size image per stroke.
        if max(image.width, image.height) > 2560 {
            let snapshot = history.current
            Task { [weak self] in
                do {
                    let thumbnail = try await EditorRenderWorker.image(image, snapshot: snapshot, maxPixelDimension: 2560)
                    self?.preview = thumbnail
                } catch {
                    // The original is already available; cache allocation failure is non-fatal.
                }
            }
        }
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
        status = annotation.tool == .crop ? "已裁剪；可撤销恢复完整图像。" : "已添加\(annotation.tool.title)。"
    }

    func rotateClockwise() {
        var next = history.current
        next.rotationQuarterTurns = (next.rotationQuarterTurns + 1) % 4
        history.commit(next); status = "图像已顺时针旋转 90°。"
    }

    func setImageScale(_ value: Double) {
        var next = history.current
        next.imageScale = CGFloat(value)
        history.commit(next); status = "输出缩放已设为 \(Int(value * 100))%。"
    }

    func requestText(at point: CGPoint) {
        pendingTextPoint = point; text = ""; showsTextEntry = true
    }

    func commitPendingText() {
        guard let point = pendingTextPoint else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { showsTextEntry = false; pendingTextPoint = nil; return }
        commit(EditorAnnotation(tool: .text, points: [point], color: color, width: strokeWidth,
                                text: value, fontSize: fontSize, isBold: isBold))
        showsTextEntry = false; pendingTextPoint = nil; text = ""
    }

    func importSticker(window: NSWindow?) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .jpeg, .gif, .tiff, .heic]
        panel.allowsMultipleSelection = false; panel.title = "选择自定义贴图"
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url, let self,
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
            let crop = self.history.current.cropBounds
            let maxSide = min(crop.width, crop.height) * 0.4 * self.stickerScale
            let ratio = min(1, maxSide / max(CGFloat(image.width), CGFloat(image.height)))
            let size = CGSize(width: CGFloat(image.width) * ratio, height: CGFloat(image.height) * ratio)
            let origin = CGPoint(x: crop.midX - size.width / 2, y: crop.midY - size.height / 2)
            self.commit(EditorAnnotation(tool: .image, points: [origin, CGPoint(x: origin.x + size.width, y: origin.y + size.height)],
                                         color: .clear, width: 0, embeddedImage: image, rotationDegrees: self.stickerRotation))
            self.selectedStickerIndex = self.history.current.annotations.count - 1
            self.status = "贴图已导入，可继续调整大小和旋转角度。"
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) } else { panel.begin(completionHandler: finish) }
    }

    func setStickerScale(_ value: Double) {
        let clamped = min(2, max(0.25, value))
        let previous = stickerScale
        stickerScale = clamped
        guard let index = selectedStickerIndex,
              history.current.annotations.indices.contains(index),
              history.current.annotations[index].tool == .image,
              previous > 0 else { return }
        var next = history.current
        let annotation = next.annotations[index]
        let center = CGPoint(x: annotation.bounds.midX, y: annotation.bounds.midY)
        let factor = CGFloat(clamped / previous)
        let halfWidth = annotation.bounds.width * factor / 2
        let halfHeight = annotation.bounds.height * factor / 2
        next.annotations[index].points = [CGPoint(x: center.x - halfWidth, y: center.y - halfHeight),
                                          CGPoint(x: center.x + halfWidth, y: center.y + halfHeight)]
        history.commit(next)
        status = "贴图大小已调整为 (Int(clamped * 100))%。"
    }

    func setStickerRotation(_ value: Double) {
        let clamped = min(180, max(-180, value))
        stickerRotation = clamped
        guard let index = selectedStickerIndex,
              history.current.annotations.indices.contains(index),
              history.current.annotations[index].tool == .image else { return }
        var next = history.current
        next.annotations[index].rotationDegrees = CGFloat(clamped)
        history.commit(next)
        status = "贴图已旋转 (Int(clamped))°。"
    }

    func recognizeQR() {
        guard !isRecognizing, !isExporting else { return }
        isRecognizing = true; let snapshot = history.current
        Task { [weak self, originalImage] in
            do {
                let image = try await EditorRenderWorker.image(originalImage, snapshot: snapshot)
                let values = try await EditorBarcode.recognize(image: image)
                self?.qrResults = values; self?.showsQR = true; self?.isRecognizing = false
                self?.status = values.isEmpty ? "未识别到二维码。" : "已识别 \(values.count) 个二维码。"
            } catch { self?.isRecognizing = false; self?.errorMessage = "二维码识别失败：\(error.localizedDescription)" }
        }
    }

    func encodeBase64() {
        guard !isExporting else { return }; isExporting = true; let snapshot = history.current
        Task { [weak self, originalImage] in
            do { self?.base64Text = try await EditorRenderWorker.png(originalImage, snapshot: snapshot).base64EncodedString(); self?.base64ModeIsDecode = false; self?.showsBase64 = true; self?.isExporting = false }
            catch { self?.isExporting = false; self?.errorMessage = error.localizedDescription }
        }
    }

    func decodeBase64(window: NSWindow?) {
        let cleaned = base64Text.components(separatedBy: .whitespacesAndNewlines).joined()
        guard let data = Data(base64Encoded: cleaned), let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { errorMessage = "Base64 不是可识别的图片数据。"; return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]; panel.nameFieldStringValue = "Base64-图片.png"
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do { try EditorRenderer.save(image: image, to: url, jpeg: false) } catch { self.errorMessage = error.localizedDescription }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) } else { panel.begin(completionHandler: finish) }
    }

    func undo() { guard history.canUndo else { return }; history.undo(); status = "已撤销。" }
    func redo() { guard history.canRedo else { return }; history.redo(); status = "已重做。" }

    func copyImage() {
        guard !isExporting, !isRecognizing else { return }
        isExporting = true
        status = "正在准备复制…"
        let snapshot = history.current
        Task { [weak self, originalImage] in
            do {
                let data = try await EditorRenderWorker.png(originalImage, snapshot: snapshot)
                guard let self else { return }
                defer { self.isExporting = false }
                NSPasteboard.general.clearContents()
                if NSPasteboard.general.setData(data, forType: .png) {
                    self.status = "已复制图像（\(Int(snapshot.cropBounds.width)) × \(Int(snapshot.cropBounds.height)) 像素）。"
                } else { self.errorMessage = "复制失败，请稍后重试。" }
            } catch { self?.isExporting = false; self?.errorMessage = error.localizedDescription }
        }
    }

    func preparePin(onReady: @escaping (CGImage) -> Void) {
        guard !isExporting, !isRecognizing else { return }
        isExporting = true
        let snapshot = history.current
        Task { [weak self, originalImage] in
            do {
                let image = try await EditorRenderWorker.image(originalImage, snapshot: snapshot)
                guard let self else { return }
                self.isExporting = false
                self.status = "已创建置顶贴图。"
                onReady(image)
            } catch { self?.isExporting = false; self?.errorMessage = error.localizedDescription }
        }
    }

    func recognizeText() {
        guard !isRecognizing, !isExporting else { return }
        isRecognizing = true
        let snapshot = history.current
        Task { [weak self, originalImage] in
            do {
                let image = try await EditorRenderWorker.image(originalImage, snapshot: snapshot)
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
        guard !isExporting else { return }
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
            self.isExporting = true
            self.status = "正在保存…"
            let snapshot = self.history.current
            let source = self.originalImage
            Task { [weak self] in
                do {
                    try await EditorRenderWorker.save(source, snapshot: snapshot, to: url, jpeg: jpeg)
                    guard let self else { return }
                    self.isExporting = false
                    self.status = "已保存：\(url.lastPathComponent)"
                    self.onExport(url)
                } catch { self?.isExporting = false; self?.errorMessage = error.localizedDescription }
            }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) }
        else { panel.begin(completionHandler: finish) }
    }
}
