import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import ServiceManagement
import LumaCaptureCore

@MainActor
final class AppModel: ObservableObject {
    let capture = CaptureService()
    let editor = EditorCoordinator()
    @Published var records: [CaptureRecord] = []
    @Published var selectedTargetID = ""
    @Published var useRegion = true
    @Published var busy = false
    @Published var countdown: Int?
    @Published var message: String?
    @Published var error: String?
    @Published var permissionGranted = false
    @Published var search = ""
    @Published var filter = "all"
    @Published var selectedTab = "capture"
    @Published var outputDirectory: URL
    @Published var hotkeyError: String?
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var launchAtLoginError: String?
    @AppStorage("showsCursor") var showsCursor = true
    @AppStorage("copyAfterCapture") var copyAfterCapture = true
    @AppStorage("captureDelay") var captureDelay = 0
    @AppStorage("recordingCountdown") var recordingCountdown = 3
    @AppStorage("recordingFPS") var recordingFPS = 30
    @AppStorage("systemAudio") var systemAudio = true
    @AppStorage("microphone") var microphone = false
    @AppStorage("maximumDuration") var maximumDuration = 0
    @AppStorage("hotkeysEnabled") var hotkeysEnabled = true
    @AppStorage("screenshotHotkeyKey") var screenshotHotkeyKey = "2"
    @AppStorage("recordingHotkeyKey") var recordingHotkeyKey = "6"
    @AppStorage("hotkeyUsesCommand") var hotkeyUsesCommand = true
    @AppStorage("hotkeyUsesShift") var hotkeyUsesShift = true
    @AppStorage("hotkeyUsesOption") var hotkeyUsesOption = false
    @AppStorage("hotkeyUsesControl") var hotkeyUsesControl = false
    @AppStorage("silentLaunch") var silentLaunch = true
    @AppStorage("appearanceMode") var appearanceMode = "system"
    private let repository: HistoryRepository
    private var timerTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private var hiddenWindows: [NSWindow] = []
    private var hotkeys: GlobalHotkeys?

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        repository = HistoryRepository(fileURL: base.appendingPathComponent("LumaCapture/history.json"))
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        let saved = UserDefaults.standard.string(forKey: "outputDirectory")
        outputDirectory = saved.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? desktop
        do { records = try repository.load() } catch { self.error = "历史记录读取失败，现有文件不受影响：\(error.localizedDescription)" }
        permissionGranted = CapturePermissions.hasScreenRecordingAccess
    }

    var target: CaptureTarget? {
        if selectedTargetID.isEmpty { return capture.displays.first }
        return (capture.displays + capture.windows).first { $0.id == selectedTargetID }
    }
    var visibleRecords: [CaptureRecord] {
        records.filter { (filter == "all" || $0.kind.rawValue == filter) && (search.isEmpty || $0.url.lastPathComponent.localizedCaseInsensitiveContains(search)) }
    }
    var isWorking: Bool { busy || capture.isRecording }

    func refresh() async {
        permissionGranted = CapturePermissions.hasScreenRecordingAccess
        guard permissionGranted else { return }
        await capture.refreshTargets()
        if selectedTargetID.isEmpty {
            selectedTargetID = capture.displays.first?.id ?? ""
        } else if target == nil {
            selectedTargetID = capture.displays.first?.id ?? ""
            message = "原捕获来源已不可用，已切换到第一个显示器。"
        }
        if let issue = capture.errorMessage { error = issue }
    }

    func requestPermission() {
        permissionGranted = CapturePermissions.requestScreenRecordingAccess()
        if !permissionGranted { CapturePermissions.openScreenRecordingSettings() }
        Task { await refresh() }
    }

    func configureHotkeys() {
        hotkeys = nil; hotkeyError = nil
        guard hotkeysEnabled else { return }
        let instance = GlobalHotkeys()
        instance.onScreenshot = { [weak self] in self?.takeScreenshot(forceRegion: true) }
        instance.onRecording = { [weak self] in
            guard let self else { return }
            if self.capture.isRecording { self.stopRecording() } else { self.startRecording() }
        }
        do { try instance.register(screenshot: screenshotHotkey, recording: recordingHotkey); hotkeys = instance } catch { hotkeyError = error.localizedDescription }
    }

    var screenshotHotkey: HotkeyConfiguration { hotkey(key: screenshotHotkeyKey) }
    var recordingHotkey: HotkeyConfiguration { hotkey(key: recordingHotkeyKey) }
    var preferredColorScheme: ColorScheme? { appearanceMode == "light" ? .light : appearanceMode == "dark" ? .dark : nil }

    func applyAppearance() {
        NSApp.appearance = appearanceMode == "light" ? NSAppearance(named: .aqua) : appearanceMode == "dark" ? NSAppearance(named: .darkAqua) : nil
    }

    func normalizeAndConfigureHotkeys() {
        screenshotHotkeyKey = normalizedHotkeyKey(screenshotHotkeyKey, fallback: "2")
        recordingHotkeyKey = normalizedHotkeyKey(recordingHotkeyKey, fallback: "6")
        configureHotkeys()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginError = nil
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch { launchAtLoginError = "无法更新开机自启：\(error.localizedDescription)" }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func hotkey(key: String) -> HotkeyConfiguration {
        HotkeyConfiguration(key: key, command: hotkeyUsesCommand, shift: hotkeyUsesShift, option: hotkeyUsesOption, control: hotkeyUsesControl)
    }

    private func normalizedHotkeyKey(_ value: String, fallback: String) -> String {
        let candidate = String(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().prefix(1))
        return candidate.range(of: "^[a-z0-9]$", options: .regularExpression) == nil ? fallback : candidate
    }

    func takeScreenshot(forceRegion: Bool = false) {
        guard !isWorking else { return }
        busy = true; message = nil
        operationTask = Task { [weak self] in
            guard let self else { return }
            defer { self.restoreWindows(); self.busy = false; self.countdown = nil; self.operationTask = nil }
            do {
                try self.requirePermission()
                await self.refresh()
                guard let target = self.target else { throw AppFailure("没有可捕获的显示器，请刷新来源。") }
                self.hideWindows()
                try await self.waitCountdown(self.captureDelay)
                try await Task.sleep(nanoseconds: 200_000_000)
                var region: CGRect?
                if (self.useRegion || forceRegion) && !target.isWindow {
                    guard let displayID = target.displayID else { throw AppFailure("无法读取显示器信息。") }
                    guard let chosen = await RegionSelector.select(displayID: displayID, confirmationTitle: "截取此区域") else { return }
                    region = chosen
                }
                try Task.checkCancellation()
                let image = try await self.capture.capture(target: target, region: region, showsCursor: self.showsCursor)
                let output = try self.newOutput(kind: .screenshot, extension: "png")
                // Present the editor as soon as ScreenCaptureKit returns. Encoding
                // a multi-megapixel PNG happens off the main actor so a Retina
                // screenshot never makes the interface wait on disk compression.
                self.restoreWindows()
                self.editor.open(image: image, sourceURL: output) { [weak self] url in
                    self?.addRecord(url, kind: .screenshot)
                }
                self.message = "截图已打开，正在后台保存原图…"
                if self.copyAfterCapture {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([NSImage(cgImage: image, size: .zero)])
                }
                try await Task.detached(priority: .utility) {
                    try Self.writePNG(image, to: output)
                }.value
                self.addRecord(output, kind: .screenshot)
                self.message = "截图已保存，\(image.width) × \(image.height) 像素"
            } catch is CancellationError { self.message = "已取消" }
            catch { self.error = error.localizedDescription }
        }
    }

    func startRecording() {
        guard !isWorking else { return }
        busy = true; message = nil
        operationTask = Task { [weak self] in
            guard let self else { return }
            defer { self.busy = false; self.countdown = nil; self.operationTask = nil }
            do {
                try self.requirePermission()
                await self.refresh()
                guard let target = self.target else { throw AppFailure("没有可录制的来源，请刷新来源。") }
                self.hideWindows()
                var region: CGRect?
                if self.useRegion && !target.isWindow {
                    guard let displayID = target.displayID else { throw AppFailure("无法读取显示器信息。") }
                    guard let chosen = await RegionSelector.select(displayID: displayID, confirmationTitle: "录制此区域") else { self.restoreWindows(); return }
                    region = chosen
                }
                try await self.waitCountdown(self.recordingCountdown)
                try Task.checkCancellation()
                let output = try self.newOutput(kind: .recording, extension: "mp4")
                let options = RecordingOptions(framesPerSecond: self.recordingFPS == 60 ? 60 : 30, showsCursor: self.showsCursor, capturesSystemAudio: self.systemAudio, capturesMicrophone: self.microphone)
                try await self.capture.startRecording(target: target, region: region, options: options, outputURL: output)
                self.message = "正在录制 · 点击菜单栏红色按钮停止"
                if self.maximumDuration > 0 {
                    let duration = self.maximumDuration
                    self.timerTask = Task { [weak self] in
                        do { try await Task.sleep(nanoseconds: UInt64(duration) * 1_000_000_000) } catch { return }
                        self?.stopRecording()
                    }
                }
            } catch is CancellationError { self.restoreWindows(); self.message = "已取消" }
            catch { self.restoreWindows(); self.error = error.localizedDescription }
        }
    }

    func stopRecording() {
        guard capture.isRecording, !busy else { return }
        busy = true; timerTask?.cancel(); timerTask = nil
        Task {
            defer { busy = false; restoreWindows() }
            do {
                let url = try await capture.stopRecording()
                addRecord(url, kind: .recording)
                message = "录屏已保存：\(url.lastPathComponent)"
                selectedTab = "library"
            } catch { self.error = error.localizedDescription }
        }
    }

    func cancelPending() { operationTask?.cancel() }
    func recordingFailed(_ value: String?) {
        guard let value else { return }
        error = value
        if !capture.isRecording { timerTask?.cancel(); restoreWindows() }
    }

    func showDashboard() {
        NSApp.setActivationPolicy(.regular)
        restoreWindows()
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "dashboard" || $0.title == "LumaCapture" }) {
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func chooseDirectory() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "选择保存目录"; panel.directoryURL = outputDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        outputDirectory = url
        UserDefaults.standard.set(url.path, forKey: "outputDirectory")
    }

    func openRecord(_ record: CaptureRecord) {
        guard FileManager.default.fileExists(atPath: record.url.path) else { error = "文件已被移动或删除：\(record.url.lastPathComponent)"; return }
        if record.kind == .screenshot, let source = CGImageSourceCreateWithURL(record.url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            editor.open(image: image, sourceURL: record.url) { [weak self] url in self?.addRecord(url, kind: .screenshot) }
        } else { NSWorkspace.shared.open(record.url) }
    }
    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    func forget(_ record: CaptureRecord) {
        let updated = records.filter { $0.id != record.id }
        do { try repository.save(updated); records = updated } catch { self.error = "历史记录保存失败：\(error.localizedDescription)" }
    }
    func importImage() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { error = "无法打开这张图像。"; return }
        editor.open(image: image, sourceURL: url) { [weak self] url in self?.addRecord(url, kind: .screenshot) }
    }

    private func addRecord(_ url: URL, kind: CaptureKind) {
        var updated = records.filter { $0.url != url }
        updated.insert(CaptureRecord(url: url, kind: kind), at: 0)
        updated = Array(updated.prefix(500))
        do { try repository.save(updated); records = updated } catch { self.error = "文件已保存，但历史记录写入失败：\(error.localizedDescription)" }
    }
    private func newOutput(kind: CaptureKind, extension ext: String) throws -> URL {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        return CaptureFileNaming.makeURL(directory: outputDirectory, kind: kind, extension: ext)
    }
    private func requirePermission() throws {
        permissionGranted = CapturePermissions.hasScreenRecordingAccess
        guard permissionGranted else { throw AppFailure("请先在控制台授予屏幕录制权限；开启后点击刷新，必要时退出并重新启动应用。") }
    }
    private func hideWindows() {
        hiddenWindows = NSApp.windows.filter { $0.isVisible && $0.level == .normal }
        hiddenWindows.forEach { $0.orderOut(nil) }
    }
    private func restoreWindows() {
        hiddenWindows.forEach { $0.orderFront(nil) }; hiddenWindows.removeAll()
    }
    private func waitCountdown(_ seconds: Int) async throws {
        guard seconds > 0 else { return }
        for value in stride(from: min(seconds, 10), through: 1, by: -1) {
            countdown = value
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        countdown = nil
    }
    nonisolated static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw AppFailure("无法创建截图文件，请检查保存目录。") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw AppFailure("截图保存失败，请检查磁盘空间及目录权限。") }
    }
}

struct AppFailure: LocalizedError {
    let detail: String
    init(_ detail: String) { self.detail = detail }
    var errorDescription: String? { detail }
}
