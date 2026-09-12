import CoreGraphics

enum CaptureSelfCheck {
    static func run() throws -> [String] {
        let display = CGSize(width: 1440, height: 900)
        let clipped = try CaptureGeometry.validatedRegion(
            CGRect(x: -20, y: 30, width: 220, height: 170), displaySize: display)
        guard clipped == CGRect(x: 0, y: 30, width: 200, height: 170) else {
            throw CaptureError.invalidRegion
        }
        let drag = CaptureGeometry.dragRect(from: CGPoint(x: 300, y: 250),
                                            to: CGPoint(x: 100, y: 50),
                                            bounds: CGRect(origin: .zero, size: display))
        guard drag == CGRect(x: 100, y: 50, width: 200, height: 200) else {
            throw CaptureError.invalidRegion
        }
        let screenshot = try CaptureGeometry.pixelSize(points: CGSize(width: 500, height: 300),
                                                       scale: 2, recording: false)
        let video = try CaptureGeometry.pixelSize(points: CGSize(width: 2560, height: 1440),
                                                  scale: 2, recording: true)
        guard screenshot.width == 1000, screenshot.height == 600,
              video.width.isMultiple(of: 2), video.height.isMultiple(of: 2),
              video.width <= 4096, video.height <= 2160 else {
            throw CaptureError.invalidRegion
        }
        let selection = CGRect(x: 20, y: 30, width: 320, height: 180)
        let copyResult = RegionSelectionResult(
            rect: selection,
            destination: .primary(allowsCopy: true))
        let editResult = RegionSelectionResult(rect: selection, destination: .editor)
        guard copyResult.copiesToPasteboard,
              !editResult.copiesToPasteboard,
              RegionSelectionDestination.primary(allowsCopy: false) == .useRegion else {
            throw CaptureError.invalidRegion
        }
        return [
            "PASS capture geometry clipping and reverse dragging",
            "PASS Retina screenshot sizing and H.264 dimension constraints",
            "PASS region copy action routes to pasteboard without opening editor",
            "SKIP real ScreenCaptureKit capture (requires interactive user permission)"
        ]
    }
}
