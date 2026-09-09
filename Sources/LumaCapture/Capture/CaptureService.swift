import AppKit
import AVFoundation
import Combine
import CoreMedia
import CoreVideo
import ScreenCaptureKit

@MainActor
final class CaptureService: NSObject, ObservableObject {
    @Published private(set) var displays: [CaptureTarget] = []
    @Published private(set) var windows: [CaptureTarget] = []
    @Published private(set) var isRecording = false
    @Published private(set) var recordingStartedAt: Date?
    @Published var errorMessage: String?

    private var session: RecordingSession?
    private var isPreparingRecording = false
    private var isFinalizingRecording = false
    private var cachedContent: SCShareableContent?
    private var cachedContentTime: TimeInterval = 0
    private var cachedScreenLayout: [ScreenLayout] = []
    private var contentRequest: (id: UUID, task: Task<SCShareableContent, Error>)?

    func refreshTargets() async {
        guard CapturePermissions.hasScreenRecordingAccess else {
            cachedContent = nil
            displays = []
            windows = []
            errorMessage = CaptureError.screenPermissionRequired.localizedDescription
            return
        }
        do {
            let content = try await shareableContent()
            updateTargets(from: content)
            errorMessage = nil
        } catch {
            cachedContent = nil
            displays = []
            windows = []
            errorMessage = usefulMessage(for: error)
        }
    }

    func capture(target: CaptureTarget, region: CGRect?, showsCursor: Bool) async throws -> CGImage {
        do {
            try ensureScreenPermission()
            let content = try await shareableContent(for: target)
            updateTargets(from: content)
            let prepared = try makeCapture(target: target, region: region, content: content, recording: false)
            prepared.configuration.showsCursor = showsCursor
            try Task.checkCancellation()
            let image = try await SCScreenshotManager.captureImage(contentFilter: prepared.filter,
                                                                  configuration: prepared.configuration)
            try Task.checkCancellation()
            errorMessage = nil
            return image
        } catch {
            if !(error is CancellationError) { errorMessage = usefulMessage(for: error) }
            throw error
        }
    }

    func startRecording(target: CaptureTarget, region: CGRect?, options: RecordingOptions,
                        outputURL: URL) async throws {
        guard !isPreparingRecording, !isFinalizingRecording, session == nil else {
            throw CaptureError.recordingAlreadyActive
        }
        isPreparingRecording = true
        defer { isPreparingRecording = false }
        do {
            try ensureScreenPermission()
            guard [30, 60].contains(options.framesPerSecond) else { throw CaptureError.invalidFrameRate }
            guard outputURL.isFileURL, outputURL.pathExtension.lowercased() == "mp4" else {
                throw CaptureError.invalidOutputURL
            }
            guard !FileManager.default.fileExists(atPath: outputURL.path) else { throw CaptureError.outputAlreadyExists }
            if options.capturesMicrophone {
                guard await CapturePermissions.requestMicrophoneAccess() else { throw CaptureError.microphonePermissionRequired }
                guard AVCaptureDevice.default(for: .audio) != nil else { throw CaptureError.microphoneUnavailable }
            }
            try Task.checkCancellation()
            let content = try await shareableContent(for: target)
            updateTargets(from: content)
            let prepared = try makeCapture(target: target, region: region, content: content, recording: true)
            let configuration = prepared.configuration
            configuration.showsCursor = options.showsCursor
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.framesPerSecond))
            configuration.capturesAudio = options.capturesSystemAudio
            configuration.captureMicrophone = options.capturesMicrophone
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = 48_000
            configuration.channelCount = 2

            let recordingConfiguration = SCRecordingOutputConfiguration()
            guard recordingConfiguration.availableVideoCodecTypes.contains(.h264),
                  recordingConfiguration.availableOutputFileTypes.contains(.mp4) else {
                throw CaptureError.unsupportedRecordingFormat
            }
            recordingConfiguration.outputURL = outputURL
            recordingConfiguration.videoCodecType = .h264
            recordingConfiguration.outputFileType = .mp4
            try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Task.checkCancellation()
            let proxy = RecordingDelegateProxy(owner: self)
            let output = SCRecordingOutput(configuration: recordingConfiguration, delegate: proxy)
            let stream = SCStream(filter: prepared.filter, configuration: configuration, delegate: proxy)
            let pending = RecordingSession(url: outputURL, stream: stream, output: output, proxy: proxy)
            session = pending
            errorMessage = nil
            do {
                try stream.addRecordingOutput(output)
                try await withTaskCancellationHandler {
                    try Task.checkCancellation()
                    // Register the timeout before asking the WindowServer to
                    // start. Awaiting startCapture() first would leave a hung
                    // system completion outside the 20-second deadline.
                    try await waitForStart(pending) {
                        stream.startCapture { [weak self, weak pending] error in
                            Task { @MainActor in
                                guard let self, let pending else { return }
                                if let error { self.fail(pending, with: error, stopStream: true) }
                                else {
                                    pending.streamStarted = true
                                    self.publishRecordingStarted(pending)
                                }
                            }
                        }
                    }
                } onCancel: { [weak self, weak pending] in
                    Task { @MainActor in
                        guard let self, let pending else { return }
                        self.fail(pending, with: CancellationError(), stopStream: true)
                    }
                }
            } catch {
                fail(pending, with: error, stopStream: true)
                throw error
            }
        } catch {
            if !(error is CancellationError) { errorMessage = usefulMessage(for: error) }
            throw error
        }
    }

    func stopRecording() async throws -> URL {
        guard let active = session else { throw CaptureError.notRecording }
        guard active.didStart else { throw CaptureError.recordingStillStarting }
        guard !active.isStopping else { throw CaptureError.recordingAlreadyActive }
        active.isStopping = true
        isFinalizingRecording = true
        defer { isFinalizingRecording = false }
        do {
            // Stop capture also stops the recording output. Its completion only
            // stops the stream; recordingOutputDidFinishRecording confirms that
            // the MP4 container has finished writing to disk.
            let url = try await waitForFinish(active) {
                active.stream.stopCapture { [weak self, weak active] error in
                    Task { @MainActor in
                        guard let self, let active, let error, active.finishResult == nil else { return }
                        self.fail(active, with: error, stopStream: false)
                    }
                }
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let bytes = attributes[.size] as? NSNumber, bytes.int64Value > 0 else {
                throw CaptureError.emptyRecording
            }
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let duration = try await asset.load(.duration)
            guard !tracks.isEmpty, duration.isNumeric, duration.seconds > 0 else {
                throw CaptureError.emptyRecording
            }
            errorMessage = nil
            return url
        } catch {
            fail(active, with: error, stopStream: false)
            errorMessage = usefulMessage(for: error)
            throw error
        }
    }

    private func shareableContent(for target: CaptureTarget? = nil) async throws -> SCShareableContent {
        // A refresh immediately followed by a capture should not enumerate every
        // open window twice. Display geometry is stable across region selection;
        // window cache hits additionally verify current bounds and visibility.
        if let target, let cachedContent, canReuse(cachedContent, for: target) { return cachedContent }
        if let request = contentRequest { return try await request.task.value }
        let requestID = UUID()
        let task = Task { try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
        contentRequest = (requestID, task)
        defer {
            if contentRequest?.id == requestID { contentRequest = nil }
        }
        let content = try await task.value
        cachedContent = content
        cachedContentTime = ProcessInfo.processInfo.systemUptime
        cachedScreenLayout = currentScreenLayout()
        return content
    }

    private func canReuse(_ content: SCShareableContent, for target: CaptureTarget) -> Bool {
        let age = ProcessInfo.processInfo.systemUptime - cachedContentTime
        guard age >= 0, cachedScreenLayout == currentScreenLayout() else { return false }
        if !target.isWindow {
            return age < 30 && content.displays.contains { $0.displayID == target.displayID }
        }
        guard age < 2,
              let window = content.windows.first(where: { $0.windowID == target.resolvedWindowID }),
              let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, window.windowID) as? [[String: Any]],
              let current = info.first,
              current[kCGWindowIsOnscreen as String] as? Bool == true,
              let bounds = current[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: bounds) else { return false }
        return frame == window.frame
    }

    private struct ScreenLayout: Equatable {
        let displayID: CGDirectDisplayID?
        let frame: CGRect
        let scale: CGFloat
    }

    private func currentScreenLayout() -> [ScreenLayout] {
        NSScreen.screens.map { ScreenLayout(displayID: $0.captureDisplayID, frame: $0.frame, scale: $0.backingScaleFactor) }
    }

    private func ensureScreenPermission() throws {
        guard CapturePermissions.requestScreenRecordingAccess() else { throw CaptureError.screenPermissionRequired }
    }

    private func updateTargets(from content: SCShareableContent) {
        displays = content.displays.sorted {
            if $0.displayID == $1.displayID { return false }
            if $0.displayID == CGMainDisplayID() { return true }
            if $1.displayID == CGMainDisplayID() { return false }
            return $0.displayID < $1.displayID
        }.enumerated().map { index, display in
            let screen = NSScreen.screens.first { $0.captureDisplayID == display.displayID }
            let label = screen?.localizedName ?? "显示器 \(index + 1)"
            return CaptureTarget(id: "display:\(display.displayID)",
                                 name: "\(label) · \(display.width) × \(display.height)",
                                 isWindow: false, displayID: display.displayID)
        }
        windows = content.windows.filter {
            $0.isOnScreen && $0.windowLayer == 0 && $0.frame.width > 1 && $0.frame.height > 1 &&
            $0.owningApplication != nil && $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier
        }.map { window in
            let app = window.owningApplication?.applicationName ?? "应用"
            let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            return CaptureTarget(id: "window:\(window.windowID)",
                                 name: "\(app) — \((title?.isEmpty == false ? title : nil) ?? "未命名窗口")",
                                 isWindow: true, windowID: window.windowID)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func makeCapture(target: CaptureTarget, region: CGRect?, content: SCShareableContent,
                             recording: Bool) throws -> (filter: SCContentFilter, configuration: SCStreamConfiguration) {
        let filter: SCContentFilter
        var sourceSize: CGSize
        let configuration = SCStreamConfiguration()
        if target.isWindow {
            guard let window = content.windows.first(where: { $0.windowID == target.resolvedWindowID && $0.isOnScreen }) else {
                throw CaptureError.targetUnavailable
            }
            guard region == nil else { throw CaptureError.invalidRegion }
            filter = SCContentFilter(desktopIndependentWindow: window)
            sourceSize = filter.contentRect.size
            configuration.ignoreShadowsSingleWindow = true
            configuration.ignoreGlobalClipSingleWindow = true
        } else {
            guard let displayID = target.displayID,
                  let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw CaptureError.targetUnavailable
            }
            // The recorder's controls and selection overlays must not enter a
            // display capture, including when the console is on another screen.
            let excluded = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
            // ScreenCaptureKit source rectangles are expressed in logical points.
            // Always use the filter's contentRect / pointPixelScale pair instead
            // of inferring a point size from SCDisplay's nominal dimensions.
            sourceSize = filter.contentRect.size
            if let region {
                let clipped = try CaptureGeometry.pixelAlignedRegion(region, displaySize: sourceSize,
                                                                      scale: CGFloat(filter.pointPixelScale))
                configuration.sourceRect = clipped
                sourceSize = clipped.size
            }
        }
        let pixelSize = try CaptureGeometry.pixelSize(points: sourceSize,
                                                     scale: CGFloat(filter.pointPixelScale), recording: recording)
        configuration.width = pixelSize.width
        configuration.height = pixelSize.height
        configuration.queueDepth = 3
        configuration.captureResolution = .best
        configuration.captureDynamicRange = .SDR
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.shouldBeOpaque = recording
        return (filter, configuration)
    }

    private func waitForStart(_ pending: RecordingSession, begin: () -> Void) async throws {
        if let result = pending.startResult { return try result.get() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pending.startContinuation = continuation
            pending.startTimeout = Task { @MainActor [weak self, weak pending] in
                do { try await Task.sleep(nanoseconds: 20_000_000_000) } catch { return }
                guard let self, let pending, pending.startResult == nil else { return }
                self.fail(pending, with: CaptureError.recordingStartTimedOut, stopStream: true)
            }
            begin()
        }
    }

    private func waitForFinish(_ active: RecordingSession, begin: () -> Void) async throws -> URL {
        if let result = active.finishResult { return try result.get() }
        return try await withCheckedThrowingContinuation { continuation in
            active.finishContinuation = continuation
            active.finishTimeout = Task { @MainActor [weak self, weak active] in
                do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
                guard let self, let active, active.finishResult == nil else { return }
                self.fail(active, with: CaptureError.recordingFinishTimedOut, stopStream: true)
            }
            begin()
        }
    }

    fileprivate func recordingDidStart(_ output: SCRecordingOutput) {
        guard let active = session, active.output === output, active.startResult == nil else { return }
        active.didStart = true
        active.startedAt = Date()
        publishRecordingStarted(active)
    }

    private func publishRecordingStarted(_ active: RecordingSession) {
        guard session === active, active.didStart, active.streamStarted, active.startResult == nil else { return }
        active.resolveStart(.success(()))
        isRecording = true
        recordingStartedAt = active.startedAt
    }

    fileprivate func recordingDidFinish(_ output: SCRecordingOutput) {
        guard let active = session, active.output === output else { return }
        if !active.didStart {
            fail(active, with: CaptureError.emptyRecording, stopStream: true)
            return
        }
        guard active.startResult != nil else {
            fail(active, with: CaptureError.emptyRecording, stopStream: true)
            return
        }
        active.resolveFinish(.success(active.url))
        clear(active)
        if !active.isStopping {
            errorMessage = "录屏已由系统结束，文件位于：\(active.url.path)。请检查播放后再使用。"
            requestCleanup(active)
        }
    }

    fileprivate func recordingDidFail(_ output: SCRecordingOutput, error: Error) {
        guard let active = session, active.output === output else { return }
        fail(active, with: error, stopStream: true)
    }

    fileprivate func streamDidFail(_ stream: SCStream, error: Error) {
        guard let active = session, active.stream === stream else { return }
        fail(active, with: error, stopStream: true)
    }

    private func fail(_ active: RecordingSession, with error: Error, stopStream: Bool) {
        active.resolveStart(.failure(error))
        active.resolveFinish(.failure(error))
        if session === active {
            clear(active)
            if !(error is CancellationError) { errorMessage = usefulMessage(for: error) }
        }
        if stopStream { requestCleanup(active) }
    }

    private func requestCleanup(_ active: RecordingSession) {
        guard !active.cleanupRequested else { return }
        active.cleanupRequested = true
        // Keep the delegate alive until the stop callback without retaining a
        // suspended Task or the entire session when the system has already failed.
        active.stream.stopCapture { [proxy = active.proxy] _ in _ = proxy }
    }

    private func clear(_ active: RecordingSession) {
        guard session === active else { return }
        session = nil
        isRecording = false
        recordingStartedAt = nil
    }

    private func usefulMessage(for error: Error) -> String {
        if error is CaptureError { return error.localizedDescription }
        if !CapturePermissions.hasScreenRecordingAccess {
            return CaptureError.screenPermissionRequired.localizedDescription
        }
        return "捕获失败：\(error.localizedDescription) 请检查所选目标、保存位置及可用磁盘空间，然后重试。"
    }
}

@MainActor
private final class RecordingSession {
    let url: URL
    let stream: SCStream
    let output: SCRecordingOutput
    let proxy: RecordingDelegateProxy
    var didStart = false
    var streamStarted = false
    var startedAt: Date?
    var isStopping = false
    var cleanupRequested = false
    var startResult: Result<Void, Error>?
    var finishResult: Result<URL, Error>?
    var startContinuation: CheckedContinuation<Void, Error>?
    var finishContinuation: CheckedContinuation<URL, Error>?
    var startTimeout: Task<Void, Never>?
    var finishTimeout: Task<Void, Never>?

    init(url: URL, stream: SCStream, output: SCRecordingOutput, proxy: RecordingDelegateProxy) {
        self.url = url
        self.stream = stream
        self.output = output
        self.proxy = proxy
    }

    func resolveStart(_ result: Result<Void, Error>) {
        guard startResult == nil else { return }
        startResult = result
        startTimeout?.cancel()
        startTimeout = nil
        let continuation = startContinuation
        startContinuation = nil
        continuation?.resume(with: result)
    }

    func resolveFinish(_ result: Result<URL, Error>) {
        guard finishResult == nil else { return }
        finishResult = result
        finishTimeout?.cancel()
        finishTimeout = nil
        let continuation = finishContinuation
        finishContinuation = nil
        continuation?.resume(with: result)
    }
}

/// ScreenCaptureKit invokes delegates off the main thread. This proxy routes
/// every state transition through the same actor used by the UI and continuations.
private final class RecordingDelegateProxy: NSObject, @unchecked Sendable, SCRecordingOutputDelegate, SCStreamDelegate {
    weak var owner: CaptureService?
    init(owner: CaptureService) { self.owner = owner }

    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor [weak owner] in owner?.recordingDidStart(recordingOutput) }
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor [weak owner] in owner?.recordingDidFinish(recordingOutput) }
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor [weak owner] in owner?.recordingDidFail(recordingOutput, error: error) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak owner] in owner?.streamDidFail(stream, error: error) }
    }
}

extension NSScreen {
    var captureDisplayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
