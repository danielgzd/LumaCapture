import AppKit
import SwiftUI

struct EditorCanvas: NSViewRepresentable {
    @ObservedObject var document: EditorDocument

    func makeNSView(context: Context) -> EditorScrollView {
        let scroll = EditorScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        let canvas = EditorCanvasView(document: document)
        scroll.documentView = canvas
        return scroll
    }

    func updateNSView(_ scroll: EditorScrollView, context: Context) {
        guard let canvas = scroll.documentView as? EditorCanvasView else { return }
        canvas.document = document
        canvas.updateLayout(viewport: scroll.contentSize)
        canvas.needsDisplay = true
    }
}

final class EditorScrollView: NSScrollView {
    override func layout() {
        super.layout()
        (documentView as? EditorCanvasView)?.updateLayout(viewport: contentSize)
    }
}

@MainActor
final class EditorCanvasView: NSView {
    var document: EditorDocument
    private var draft: EditorAnnotation?
    private var scale: CGFloat = 1
    private var imageFrame: CGRect = .zero
    private var draftPath: CGMutablePath?
    private var cachedSource: CGImage?
    private var sourceRepresentation: NSImage?
    private let checkerColor: NSColor = {
        let tile = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { _ in
            NSColor.controlBackgroundColor.setFill()
            NSRect(x: 0, y: 0, width: 24, height: 24).fill()
            NSColor.separatorColor.withAlphaComponent(0.55).setFill()
            NSRect(x: 0, y: 0, width: 12, height: 12).fill()
            NSRect(x: 12, y: 12, width: 12, height: 12).fill()
            return true
        }
        return NSColor(patternImage: tile)
    }()

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(document: EditorDocument) {
        self.document = document
        super.init(frame: .zero)
        setAccessibilityLabel("截图标注画布")
        setAccessibilityHelp("先选择工具，再在图像上拖动。按 Escape 取消当前绘制，Command Z 撤销。")
    }

    required init?(coder: NSCoder) { nil }

    func updateLayout(viewport: NSSize) {
        let cropSize = document.history.current.cropBounds.size
        let turns = normalizedTurns
        let size = turns.isMultiple(of: 2) ? cropSize : NSSize(width: cropSize.height, height: cropSize.width)
        guard size.width > 0, size.height > 0, viewport.width > 0, viewport.height > 0 else { return }
        let fit = max(0.01, min((viewport.width - 48) / size.width, (viewport.height - 48) / size.height))
        scale = document.zoom == 0 ? min(fit, 1) : document.zoom
        let displaySize = NSSize(width: size.width * scale, height: size.height * scale)
        let canvasSize = NSSize(width: max(viewport.width, displaySize.width + 48),
                                height: max(viewport.height, displaySize.height + 48))
        if frame.size != canvasSize { setFrameSize(canvasSize) }
        imageFrame = CGRect(x: (canvasSize.width - displaySize.width) / 2,
                            y: (canvasSize.height - displaySize.height) / 2,
                            width: displaySize.width, height: displaySize.height)
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(imageFrame, cursor: document.tool == .text ? .iBeam : (document.tool == nil ? .arrow : .crosshair))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.underPageBackgroundColor.setFill()
        dirtyRect.fill()
        guard imageFrame.width > 0 else { return }
        // Checkerboard makes transparent screenshots visible without changing exported pixels.
        checkerColor.setFill()
        imageFrame.fill()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: imageFrame).addClip()
        let crop = document.history.current.cropBounds
        // Use the display cache when it has enough pixels for the backing scale. Zooming
        // into detail uses the original; neither operation creates a composited full-size copy.
        let cacheScale = CGFloat(document.preview.width) / CGFloat(document.originalImage.width)
        let source = scale * (window?.backingScaleFactor ?? 2) <= cacheScale * 1.05 ? document.preview : document.originalImage
        if cachedSource !== source {
            cachedSource = source
            sourceRepresentation = NSImage(cgImage: source, size: NSSize(width: document.originalImage.width, height: document.originalImage.height))
        }
        if let context = NSGraphicsContext.current?.cgContext {
            context.saveGState()
            context.translateBy(x: imageFrame.minX, y: imageFrame.minY)
            context.scaleBy(x: scale, y: scale)
            context.concatenate(displayTransform(cropSize: crop.size))
            context.translateBy(x: -crop.minX, y: -crop.minY)
            sourceRepresentation?.draw(in: CGRect(x: 0, y: 0, width: document.originalImage.width, height: document.originalImage.height),
                                       from: .zero, operation: .sourceOver, fraction: 1,
                                       respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            EditorRenderer.draw(annotations: document.history.current.annotations, sourceImage: document.originalImage, in: context)
            if let draft, draft.tool == .crop {
                let selected = draft.bounds.intersection(crop)
                context.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
                context.fill(CGRect(x: crop.minX, y: crop.minY, width: crop.width, height: max(0, selected.minY - crop.minY)))
                context.fill(CGRect(x: crop.minX, y: selected.maxY, width: crop.width, height: max(0, crop.maxY - selected.maxY)))
                context.fill(CGRect(x: crop.minX, y: selected.minY, width: max(0, selected.minX - crop.minX), height: selected.height))
                context.fill(CGRect(x: selected.maxX, y: selected.minY, width: max(0, crop.maxX - selected.maxX), height: selected.height))
                context.setLineWidth(1.5 / scale)
                context.setStrokeColor(NSColor.white.cgColor)
                context.setLineDash(phase: 0, lengths: [6 / scale, 4 / scale])
                context.stroke(selected)
            } else if let draft {
                EditorRenderer.draw(annotations: [draft], sourceImage: document.originalImage, in: context)
            }
            context.restoreGState()
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor.separatorColor.setStroke()
        NSBezierPath(rect: imageFrame.insetBy(dx: -0.5, dy: -0.5)).stroke()
    }

    private func point(for event: NSEvent, clamp: Bool) -> CGPoint? {
        let local = convert(event.locationInWindow, from: nil)
        guard clamp || imageFrame.contains(local) else { return nil }
        let crop = document.history.current.cropBounds
        let displayed = CGPoint(x: (local.x - imageFrame.minX) / scale,
                                y: (local.y - imageFrame.minY) / scale)
        let source: CGPoint
        switch normalizedTurns {
        case 1: source = CGPoint(x: displayed.y, y: crop.height - displayed.x)
        case 2: source = CGPoint(x: crop.width - displayed.x, y: crop.height - displayed.y)
        case 3: source = CGPoint(x: crop.width - displayed.y, y: displayed.x)
        default: source = displayed
        }
        return CGPoint(x: min(crop.maxX, max(crop.minX, source.x + crop.minX)),
                       y: min(crop.maxY, max(crop.minY, source.y + crop.minY)))
    }

    private var normalizedTurns: Int {
        let turns = document.history.current.rotationQuarterTurns % 4
        return turns >= 0 ? turns : turns + 4
    }

    /// Maps top-left source coordinates to the clockwise-rotated canvas.
    private func displayTransform(cropSize: CGSize) -> CGAffineTransform {
        switch normalizedTurns {
        case 1: return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: cropSize.height, ty: 0)
        case 2: return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: cropSize.width, ty: cropSize.height)
        case 3: return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: cropSize.width)
        default: return .identity
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let start = point(for: event, clamp: false) else { return }
        guard let tool = document.tool else { return }
        var annotation = EditorAnnotation(tool: tool, points: [start], color: document.color,
                                          width: document.strokeWidth, text: document.text, fontSize: document.fontSize,
                                          isBold: document.isBold, cornerRadius: document.rectangleCornerRadius)
        if tool == .text {
            document.requestText(at: start)
        } else if tool == .image {
            document.status = "请点击工具栏中的“导入贴图”。"
        } else {
            if tool != .pen { annotation.points.append(start) }
            else {
                let path = CGMutablePath()
                path.move(to: start)
                draftPath = path
                annotation.strokePath = path
            }
            draft = annotation
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let tool = draft?.tool, let position = point(for: event, clamp: true) else { return }
        if tool == .pen, let previous = draft?.points.last {
            // Sampling in view points avoids thousands of indistinguishable tablet/mouse events.
            guard hypot(position.x - previous.x, position.y - previous.y) * scale >= 0.7 else { return }
            draft?.points.append(position)
            draftPath?.addLine(to: position)
            let margin = (draft?.width ?? 6) / 2 + 2 / scale
            let changed = CGRect(x: min(position.x, previous.x), y: min(position.y, previous.y),
                                 width: abs(position.x - previous.x), height: abs(position.y - previous.y)).insetBy(dx: -margin, dy: -margin)
            if normalizedTurns == 0 {
                let crop = document.history.current.cropBounds
                setNeedsDisplay(CGRect(x: imageFrame.minX + (changed.minX - crop.minX) * scale,
                                       y: imageFrame.minY + (changed.minY - crop.minY) * scale,
                                       width: changed.width * scale, height: changed.height * scale))
            } else { needsDisplay = true }
        } else {
            if let count = draft?.points.count, count > 0 { draft?.points[count - 1] = position }
            needsDisplay = true
        }
        if tool == .crop, let bounds = draft?.bounds {
            document.status = "裁剪区域：\(Int(bounds.width)) × \(Int(bounds.height)) 像素 · 松开应用 · Esc 取消"
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard var annotation = draft else { return }
        if let finalPoint = point(for: event, clamp: true) {
            if annotation.tool == .pen, annotation.points.last != finalPoint {
                annotation.points.append(finalPoint)
                draftPath?.addLine(to: finalPoint)
            } else if annotation.tool != .pen { annotation.points[annotation.points.count - 1] = finalPoint }
        }
        annotation.strokePath = draftPath?.copy()
        draft = nil
        draftPath = nil
        let valid: Bool
        switch annotation.tool {
        case .pen: valid = true
        case .arrow: valid = hypot(annotation.bounds.width, annotation.bounds.height) >= 2
        case .text, .image: valid = false
        default: valid = annotation.bounds.width >= 2 && annotation.bounds.height >= 2
        }
        if valid { document.commit(annotation) }
        else { document.status = "操作已取消：请拖动以选择更大的区域。" }
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            draft = nil
            draftPath = nil
            document.status = "已取消当前绘制。"
            needsDisplay = true
        } else if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "z" {
            if event.modifierFlags.contains(.shift) { document.redo() }
            else { document.undo() }
        } else if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c" {
            document.copyImage()
        } else {
            super.keyDown(with: event)
        }
    }
}
