import AppKit
import CoreGraphics

/// Presents a borderless overlay on exactly one display and returns a rectangle
/// in ScreenCaptureKit's display-local, top-left logical point coordinate space.
@MainActor
enum RegionSelector {
    private static var active: RegionSelectionController?

    static func select(displayID: CGDirectDisplayID) async -> CGRect? {
        active?.cancel()
        guard !Task.isCancelled else { return nil }
        guard let screen = NSScreen.screens.first(where: { $0.captureDisplayID == displayID }) else { return nil }
        let requestID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: nil); return }
                let controller = RegionSelectionController(id: requestID, screen: screen) { result in
                    if active?.id == requestID { active = nil }
                    continuation.resume(returning: result)
                }
                active = controller
                controller.present()
            }
        } onCancel: {
            Task { @MainActor in
                if active?.id == requestID { active?.cancel() }
            }
        }
    }
}

@MainActor
private final class RegionSelectionController {
    let id: UUID
    private let screen: NSScreen
    private let completion: (CGRect?) -> Void
    private var hasCompleted = false
    private var keyMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var deactivateObserver: NSObjectProtocol?
    private lazy var window: RegionSelectionWindow = {
        let window = RegionSelectionWindow(contentRect: screen.frame,
                                           styleMask: [.borderless], backing: .buffered,
                                           defer: false, screen: screen)
        window.level = .screenSaver
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.ignoresMouseEvents = false
        let view = RegionSelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.onComplete = { [weak self] rect in self?.finish(rect) }
        window.contentView = view
        return window
    }()

    init(id: UUID, screen: NSScreen, completion: @escaping (CGRect?) -> Void) {
        self.id = id
        self.screen = screen
        self.completion = completion
    }

    func present() {
        NSCursor.crosshair.push()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.cancel()
            return nil
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // The old screen's local coordinates are invalid after a resolution,
            // arrangement or display-connection change. Never return a stale crop.
            Task { @MainActor in self?.cancel() }
        }
        deactivateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.cancel() }
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(window.contentView)
    }

    func cancel() { finish(nil) }

    private func finish(_ windowLocalRect: CGRect?) {
        guard !hasCompleted else { return }
        hasCompleted = true
        window.orderOut(nil)
        window.close()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver); self.screenObserver = nil }
        if let deactivateObserver { NotificationCenter.default.removeObserver(deactivateObserver); self.deactivateObserver = nil }
        NSCursor.pop()
        if let rect = windowLocalRect?.standardized,
           rect.width >= CaptureGeometry.minimumRegionSize,
           rect.height >= CaptureGeometry.minimumRegionSize {
            let topLeft = CaptureGeometry.topLeftRegion(fromBottomLeft: rect, displayHeight: screen.frame.height)
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
        guard let start else { return }
        // The final mouse-up can be newer than the last coalesced drag event.
        let result = CaptureGeometry.dragRect(from: start, to: convert(event.locationInWindow, from: nil), bounds: bounds)
        self.start = nil
        guard result.width >= CaptureGeometry.minimumRegionSize,
              result.height >= CaptureGeometry.minimumRegionSize else {
            selection = nil
            needsDisplay = true
            return
        }
        onComplete?(result)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onComplete?(nil) }
        else { super.keyDown(with: event) }
    }

    override func rightMouseDown(with event: NSEvent) { onComplete?(nil) }
}
