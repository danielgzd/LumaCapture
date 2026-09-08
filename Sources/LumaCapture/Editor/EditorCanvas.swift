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
        let size = document.history.current.cropBounds.size
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
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(imageFrame, cursor: document.tool == .text ? .iBeam : .crosshair)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.09, alpha: 1).setFill()
        dirtyRect.fill()
        guard imageFrame.width > 0 else { return }
        // Checkerboard makes transparent screenshots visible without changing exported pixels.
        NSColor(calibratedWhite: 0.88, alpha: 1).setFill()
        imageFrame.fill()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: imageFrame).addClip()
        let tile: CGFloat = 12
        NSColor(calibratedWhite: 0.76, alpha: 1).setFill()
        let visible = imageFrame.intersection(dirtyRect)
        if !visible.isNull {
            let startX = max(0, Int((visible.minX - imageFrame.minX) / tile))
            let endX = max(startX, Int(ceil((visible.maxX - imageFrame.minX) / tile)))
            let startY = max(0, Int((visible.minY - imageFrame.minY) / tile))
            let endY = max(startY, Int(ceil((visible.maxY - imageFrame.minY) / tile)))
            for row in startY...endY {
                for column in startX...endX where (row + column).isMultiple(of: 2) {
                    NSRect(x: imageFrame.minX + CGFloat(column) * tile, y: imageFrame.minY + CGFloat(row) * tile,
                           width: tile, height: tile).fill()
                }
            }
        }
        NSImage(cgImage: document.preview, size: NSSize(width: document.preview.width, height: document.preview.height))
            .draw(in: imageFrame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        if let draft, let context = NSGraphicsContext.current?.cgContext {
            context.saveGState()
            context.translateBy(x: imageFrame.minX, y: imageFrame.minY)
            context.scaleBy(x: scale, y: scale)
            let crop = document.history.current.cropBounds
            context.translateBy(x: -crop.minX, y: -crop.minY)
            if draft.tool == .crop {
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
            } else {
                EditorRenderer.draw(annotations: [draft], in: context)
            }
            context.restoreGState()
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.16).setStroke()
        NSBezierPath(rect: imageFrame.insetBy(dx: -0.5, dy: -0.5)).stroke()
    }

    private func point(for event: NSEvent, clamp: Bool) -> CGPoint? {
        let local = convert(event.locationInWindow, from: nil)
        guard clamp || imageFrame.contains(local) else { return nil }
        let crop = document.history.current.cropBounds
        return CGPoint(x: min(crop.maxX, max(crop.minX, (local.x - imageFrame.minX) / scale + crop.minX)),
                       y: min(crop.maxY, max(crop.minY, (local.y - imageFrame.minY) / scale + crop.minY)))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let start = point(for: event, clamp: false) else { return }
        var annotation = EditorAnnotation(tool: document.tool, points: [start], color: document.color,
                                          width: document.strokeWidth, text: document.text, fontSize: document.fontSize)
        if document.tool == .text {
            guard !document.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                document.status = "请先在工具栏输入要添加的文字。"
                return
            }
            document.commit(annotation)
        } else {
            if document.tool != .pen { annotation.points.append(start) }
            draft = annotation
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard var annotation = draft, let position = point(for: event, clamp: true) else { return }
        if annotation.tool == .pen { annotation.points.append(position) }
        else { annotation.points[annotation.points.count - 1] = position }
        draft = annotation
        if annotation.tool == .crop {
            document.status = "裁剪区域：\(Int(annotation.bounds.width)) × \(Int(annotation.bounds.height)) 像素 · 松开应用 · Esc 取消"
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let annotation = draft else { return }
        draft = nil
        let valid: Bool
        switch annotation.tool {
        case .pen: valid = true
        case .arrow: valid = hypot(annotation.bounds.width, annotation.bounds.height) >= 2
        default: valid = annotation.bounds.width >= 2 && annotation.bounds.height >= 2
        }
        if valid { document.commit(annotation) }
        else { document.status = "操作已取消：请拖动以选择更大的区域。" }
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            draft = nil
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
