import AppKit
import CoreGraphics

/// Presents a borderless overlay on exactly one display and returns a rectangle
/// in ScreenCaptureKit's display-local, top-left logical point coordinate space.
@MainActor
enum RegionSelector {
    private static var active: RegionSelectionController?

    static func select(displayID: CGDirectDisplayID) async -> CGRect? {
        active?.cancel()
        guard let screen = NSScreen.screens.first(where: { $0.captureDisplayID == displayID }) else { return nil }
        return await withCheckedContinuation { continuation in
            let controller = RegionSelectionController(screen: screen) { result in
                active = nil
                continuation.resume(returning: result)
            }
            active = controller
            controller.present()
        }
    }
}

@MainActor
private final class RegionSelectionController {
    private let screen: NSScreen
    private let completion: (CGRect?) -> Void
    private var hasCompleted = false
    private lazy var window: RegionSelectionWindow = {
        let window = RegionSelectionWindow(contentRect: screen.frame,
                                           styleMask: [.borderless], backing: .buffered,
                                           defer: false, screen: screen)
        window.level = .screenSaver
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.ignoresMouseEvents = false
        let view = RegionSelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.onComplete = { [weak self] rect in self?.finish(rect) }
        window.contentView = view
        return window
    }()

    init(screen: NSScreen, completion: @escaping (CGRect?) -> Void) {
        self.screen = screen
        self.completion = completion
    }

    func present() {
        NSCursor.crosshair.push()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(window.contentView)
    }

    func cancel() { finish(nil) }

    private func finish(_ windowLocalRect: CGRect?) {
        guard !hasCompleted else { return }
        hasCompleted = true
        window.orderOut(nil)
        NSCursor.pop()
        if let rect = windowLocalRect?.standardized,
           rect.width >= CaptureGeometry.minimumRegionSize,
           rect.height >= CaptureGeometry.minimumRegionSize {
            let topLeft = CGRect(x: rect.minX,
                                 y: screen.frame.height - rect.maxY,
                                 width: rect.width,
                                 height: rect.height)
            completion(topLeft)
        } else {
            completion(nil)
        }
    }
}

private final class RegionSelectionWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class RegionSelectionView: NSView {
    var onComplete: ((CGRect?) -> Void)?
    private var start: CGPoint?
    private var selection: CGRect?

    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.34).setFill()
        bounds.fill()
        if let selection, selection.width > 0, selection.height > 0 {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .clear
            selection.fill()
            NSGraphicsContext.restoreGraphicsState()

            NSColor.white.setStroke()
            let border = NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 1
            border.stroke()

            let label = "\(Int(selection.width)) × \(Int(selection.height))"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.white,
                .backgroundColor: NSColor.black.withAlphaComponent(0.72)
            ]
            let size = label.size(withAttributes: attributes)
            let x = min(max(8, selection.minX), max(8, bounds.maxX - size.width - 14))
            let preferredY = selection.maxY + 8
            let y = preferredY + size.height < bounds.maxY ? preferredY : max(8, selection.minY - size.height - 8)
            label.draw(at: CGPoint(x: x + 5, y: y + 3), withAttributes: attributes)
        } else {
            let hint = "拖动选择区域  ·  Esc 取消"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 15, weight: .medium),
                .foregroundColor: NSColor.white
            ]
            let size = hint.size(withAttributes: attributes)
            hint.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
                      withAttributes: attributes)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        start = point
        selection = CGRect(origin: point, size: .zero)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let point = convert(event.locationInWindow, from: nil)
        selection = CaptureGeometry.dragRect(from: start, to: point, bounds: bounds)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard start != nil else { return }
        let result = selection
        start = nil
        onComplete?(result)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onComplete?(nil) }
        else { super.keyDown(with: event) }
    }

    override func rightMouseDown(with event: NSEvent) { onComplete?(nil) }
}
