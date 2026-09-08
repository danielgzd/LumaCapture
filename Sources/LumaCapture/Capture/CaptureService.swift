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

    func refreshTargets() async {
        guard CapturePermissions.hasScreenRecordingAccess else {
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
            displays = []
            windows = []
            errorMessage = usefulMessage(for: error)
        }
    }

    func capture(target: CaptureTarget, region: CGRect?, showsCursor: Bool) async throws -> CGImage {
        do {
            try ensureScreenPermission()
            let content = try await shareableContent()
            updateTargets(from: content)
            let prepared = try makeCapture(target: target, region: region, content: content, recording: false)
            prepared.configuration.showsCursor = showsCursor
            try Task.checkCancellation()
            let image = try await SCScreenshotManager.captureImage(contentFilter: prepared.filter,
                                                                  configuration: prepared.configuration)
            errorMessage = nil
            return image
        } catch {
            if !(error is CancellationError) { errorMessage = usefulMessage(for: error) }
            throw error
        }
    }

    func startRecording(target: CaptureTarget, region: CGRect?, options: RecordingOptions,
                        outputURL: URL) async throws {
        guard !isPreparingRecording, session == nil else { throw CaptureError.recordingAlreadyActive }
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
            let content = try await shareableContent()
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
                    try await stream.startCapture()
                    try Task.checkCancellation()
                    try await waitForStart(pending)
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
        do {
            // Stop capture also stops the recording output. Its completion only
            // stops the stream; recordingOutputDidFinishRecording confirms that
            // the MP4 container has finished writing to disk.
            try await active.stream.stopCapture()
            let url = try await waitForFinish(active)
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

    private func shareableContent() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    private func ensureScreenPermission() throws {
        guard CapturePermissions.requestScreenRecordingAccess() else { throw CaptureError.screenPermissionRequired }
    }

    private func updateTargets(from content: SCShareableContent) {
        displays = content.displays.sorted {
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
            let windowID = target.windowID ?? UInt32(target.id.replacingOccurrences(of: "window:", with: ""))
            guard let window = content.windows.first(where: { $0.windowID == windowID && $0.isOnScreen }) else {
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
            // `SCDisplay.width/height` describe backing pixels on Retina displays,
            // while the filter pairs its point-sized contentRect with pointPixelScale.
            sourceSize = filter.contentRect.size
            if let region {
                let clipped = try CaptureGeometry.validatedRegion(region, displaySize: sourceSize)
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

    private func waitForStart(_ pending: RecordingSession) async throws {
        if let result = pending.startResult { return try result.get() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pending.startContinuation = continuation
            pending.startTimeout = Task { @MainActor [weak self, weak pending] in
                do { try await Task.sleep(nanoseconds: 20_000_000_000) } catch { return }
                guard let self, let pending, pending.startResult == nil else { return }
                self.fail(pending, with: CaptureError.recordingStartTimedOut, stopStream: true)
            }
        }
    }

    private func waitForFinish(_ active: RecordingSession) async throws -> URL {
        if let result = active.finishResult { return try result.get() }
        return try await withCheckedThrowingContinuation { continuation in
            active.finishContinuation = continuation
            active.finishTimeout = Task { @MainActor [weak self, weak active] in
                do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
                guard let self, let active, active.finishResult == nil else { return }
                self.fail(active, with: CaptureError.recordingFinishTimedOut, stopStream: true)
            }
        }
    }

    fileprivate func recordingDidStart(_ output: SCRecordingOutput) {
        guard let active = session, active.output === output, active.startResult == nil else { return }
        active.didStart = true
        active.resolveStart(.success(()))
        isRecording = true
        recordingStartedAt = Date()
    }

    fileprivate func recordingDidFinish(_ output: SCRecordingOutput) {
        guard let active = session, active.output === output else { return }
        if !active.didStart {
            fail(active, with: CaptureError.emptyRecording, stopStream: true)
            return
        }
        active.resolveFinish(.success(active.url))
        clear(active)
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
            if !(error is CancellationError) { errorMessage = usefulMessage(for: error) }
            clear(active)
        }
        if stopStream, !active.cleanupRequested {
            active.cleanupRequested = true
            Task { @MainActor in
                do { try await active.stream.stopCapture() }
                catch { /* Preserve the original failure; stopping a failed stream can also fail. */ }
            }
        }
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
private final class RecordingDelegateProxy: NSObject, SCRecordingOutputDelegate, SCStreamDelegate {
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
