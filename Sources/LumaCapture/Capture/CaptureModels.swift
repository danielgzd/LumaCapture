import AppKit
import AVFoundation
import CoreGraphics
import ScreenCaptureKit

struct CaptureTarget: Identifiable, Hashable {
    let id: String
    let name: String
    let isWindow: Bool
    let displayID: CGDirectDisplayID?
    let windowID: CGWindowID?

    init(id: String, name: String, isWindow: Bool, displayID: CGDirectDisplayID? = nil,
         windowID: CGWindowID? = nil) {
        self.id = id
        self.name = name
        self.isWindow = isWindow
        self.displayID = displayID
        self.windowID = windowID
    }

    static func == (lhs: CaptureTarget, rhs: CaptureTarget) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct RecordingOptions {
    var framesPerSecond: Int = 30
    var showsCursor: Bool = true
    var capturesSystemAudio: Bool = true
    var capturesMicrophone: Bool = false
}

enum CaptureError: LocalizedError {
    case screenPermissionRequired
    case microphonePermissionRequired
    case microphoneUnavailable
    case targetUnavailable
    case invalidRegion
    case recordingAlreadyActive
    case notRecording
    case recordingStillStarting
    case invalidFrameRate
    case invalidOutputURL
    case outputAlreadyExists
    case recordingStartTimedOut
    case recordingFinishTimedOut
    case emptyRecording
    case unsupportedRecordingFormat

    var errorDescription: String? {
        switch self {
        case .screenPermissionRequired:
            return "需要屏幕录制权限。请在「系统设置 → 隐私与安全性 → 屏幕与系统音频录制」允许 LumaCapture；若系统要求，请退出并重新打开应用。"
        case .microphonePermissionRequired:
            return "麦克风访问未获允许。请在「系统设置 → 隐私与安全性 → 麦克风」允许 LumaCapture，或关闭录屏的麦克风选项。"
        case .microphoneUnavailable:
            return "没有可用的麦克风。请连接输入设备，或关闭录屏的麦克风选项。"
        case .targetUnavailable:
            return "所选窗口已关闭、最小化，或显示器已断开。请刷新目标并重新选择。"
        case .invalidRegion:
            return "截图区域无效。请在所选显示器内拖出至少 4 × 4 点的区域。"
        case .recordingAlreadyActive:
            return "已有录屏正在开始、录制或结束。请等待当前操作完成。"
        case .notRecording:
            return "当前没有可停止的录屏。"
        case .recordingStillStarting:
            return "录屏仍在准备，请等待录制开始后再停止。"
        case .invalidFrameRate:
            return "录屏帧率仅支持 30 或 60 fps。"
        case .invalidOutputURL:
            return "录屏需要保存到本地的 .mp4 文件。请重新选择保存目录。"
        case .outputAlreadyExists:
            return "目标录屏文件已经存在。请使用新的文件名，避免覆盖已有文件。"
        case .recordingStartTimedOut:
            return "录屏未能在 20 秒内开始。请检查屏幕录制权限与所选目标，再重试。"
        case .recordingFinishTimedOut:
            return "录屏文件未能在 30 秒内完成封装。请检查磁盘空间；该文件可能不完整。"
        case .emptyRecording:
            return "录屏没有生成可播放的视频。请至少录制一秒，并确认捕获目标仍然存在。"
        case .unsupportedRecordingFormat:
            return "此系统没有提供 H.264 / MP4 录制支持。请检查 macOS 更新。"
        }
    }
}

@MainActor
enum CapturePermissions {
    static var hasScreenRecordingAccess: Bool { CGPreflightScreenCaptureAccess() }
    static var microphoneAuthorizationStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    @discardableResult
    static func requestScreenRecordingAccess() -> Bool {
        hasScreenRecordingAccess || CGRequestScreenCaptureAccess()
    }

    static func requestMicrophoneAccess() async -> Bool {
        switch microphoneAuthorizationStatus {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    static func openScreenRecordingSettings() {
        openSettings("Privacy_ScreenCapture")
    }

    static func openMicrophoneSettings() {
        openSettings("Privacy_Microphone")
    }

    private static func openSettings(_ anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// All regions use display-local logical points with a top-left origin.
/// ScreenCaptureKit's filter supplies its own scale, so Retina and mixed-scale
/// displays do not depend on the display that happens to contain the main window.
enum CaptureGeometry {
    static let minimumRegionSize: CGFloat = 4

    static func validatedRegion(_ region: CGRect, displaySize: CGSize) throws -> CGRect {
        let values = [region.origin.x, region.origin.y, region.width, region.height,
                      displaySize.width, displaySize.height]
        guard values.allSatisfy({ $0.isFinite }), displaySize.width > 0, displaySize.height > 0 else {
            throw CaptureError.invalidRegion
        }
        let clipped = region.standardized.intersection(CGRect(origin: .zero, size: displaySize))
        guard !clipped.isNull, clipped.width >= minimumRegionSize, clipped.height >= minimumRegionSize else {
            throw CaptureError.invalidRegion
        }
        return clipped
    }

    static func dragRect(from start: CGPoint, to end: CGPoint, bounds: CGRect) -> CGRect {
        let clamp: (CGPoint) -> CGPoint = { point in
            CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX),
                    y: min(max(point.y, bounds.minY), bounds.maxY))
        }
        let a = clamp(start)
        let b = clamp(end)
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                      width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    static func pixelSize(points: CGSize, scale: CGFloat, recording: Bool) throws -> (width: Int, height: Int) {
        guard points.width.isFinite, points.height.isFinite, scale.isFinite,
              points.width > 0, points.height > 0, scale > 0 else { throw CaptureError.invalidRegion }
        let rawWidth = ceil(points.width * scale)
        let rawHeight = ceil(points.height * scale)
        guard rawWidth.isFinite, rawHeight.isFinite, rawWidth <= 65_536, rawHeight <= 65_536 else {
            throw CaptureError.invalidRegion
        }
        if !recording { return (max(1, Int(rawWidth)), max(1, Int(rawHeight))) }
        // H.264 hardware encoders require even sizes. Fit within the common
        // 4096 × 2160 encoder limit on both Intel and Apple Silicon machines.
        let fit = min(1, min(4096 / rawWidth, 2160 / rawHeight))
        return (max(2, Int(floor(rawWidth * fit / 2)) * 2),
                max(2, Int(floor(rawHeight * fit / 2)) * 2))
    }
}
