import SwiftUI
import AppKit
import Carbon
import LumaCaptureCore

private let mint = Color(nsColor: NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(red: 0.50, green: 0.91, blue: 0.78, alpha: 1)
        : NSColor(red: 0.086, green: 0.467, blue: 1.0, alpha: 1)
})
private let separator = Color(nsColor: .separatorColor)
private let surface = Color(nsColor: NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(red: 0.105, green: 0.12, blue: 0.14, alpha: 1) : .white
})
private let canvas = Color(nsColor: NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(red: 0.065, green: 0.077, blue: 0.09, alpha: 1) : NSColor(red: 0.961, green: 0.961, blue: 0.961, alpha: 1)
})
private let selectedFill = Color(nsColor: NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(red: 0.50, green: 0.91, blue: 0.78, alpha: 0.13) : NSColor(red: 0.902, green: 0.957, blue: 1.0, alpha: 1)
})
private let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版"

private enum WorkspaceMode {
    case screenshot
    case recording
}

struct DashboardView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var capture: CaptureService
    @Environment(\.scenePhase) private var phase
    @State private var workspaceMode: WorkspaceMode = .screenshot
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(alignment: .leading, spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if !model.permissionGranted { permissionCard }
                        if capture.isRecording { recordingCard }
                        if let message = model.message { Label(message, systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(mint).textSelection(.enabled) }
                        if model.selectedTab == "capture" { capturePage }
                        else if model.selectedTab == "library" { libraryPage }
                        else { settingsPage }
                    }.padding(30)
                }
                footer
            }
        }
        .frame(minWidth: 940, minHeight: 650)
        .background(canvas)
        .preferredColorScheme(model.preferredColorScheme)
        .tint(mint)
        .alert("操作未完成", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("知道了") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .onChange(of: phase) { _, value in if value == .active { Task { await model.refresh() } } }
        .onReceive(capture.$errorMessage) { model.recordingFailed($0) }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 30) {
            HStack(spacing: 11) {
                Image(systemName: "viewfinder").font(.system(size: 28, weight: .medium)).foregroundStyle(mint)
                VStack(alignment: .leading, spacing: 3) { Text("Luma").font(.system(size: 23, weight: .bold, design: .rounded)); Text("CAPTURE STUDIO").font(.system(size: 8, weight: .semibold)).tracking(2).foregroundStyle(.secondary) }
            }.padding(.top, 20)
            VStack(spacing: 7) {
                nav("capture", title: "捕获工作台", symbol: "viewfinder")
                nav("library", title: "我的素材", symbol: "square.stack.3d.up")
                nav("settings", title: "偏好设置", symbol: "slider.horizontal.3")
            }
            Spacer()
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: "lock.shield").font(.title2).foregroundStyle(mint)
                Text("只留在你的 Mac").font(.system(size: 13, weight: .semibold))
                Text("本地捕获 · 本地识别\n没有账户，没有上传").font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(5)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(surface, in: RoundedRectangle(cornerRadius: 14))
            HStack { Text("© Daniel · LumaCapture"); Spacer(); Text("v\(appVersion)") }.font(.system(size: 10)).foregroundStyle(.tertiary)
        }.padding(20).frame(width: 208).background(surface)
    }
    private func nav(_ id: String, title: String, symbol: String) -> some View {
        Button { model.selectedTab = id } label: {
            HStack(spacing: 12) { Image(systemName: symbol).frame(width: 20); Text(title); Spacer(); if id == "library" { Text("\(model.records.count)").font(.caption).foregroundStyle(.secondary) } }
                .font(.system(size: 13, weight: .medium)).padding(.horizontal, 14).frame(maxWidth: .infinity, minHeight: 46)
                .background(model.selectedTab == id ? selectedFill : .clear, in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(model.selectedTab == id ? mint : .secondary)
        }.buttonStyle(.plain).frame(maxWidth: .infinity)
    }
    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.selectedTab == "capture" ? "灵感，随手捕获。" : model.selectedTab == "library" ? "你的每一次捕获。" : "按照你的方式工作。")
                    .font(.system(size: 26, weight: .semibold))
                Text(model.selectedTab == "capture" ? "从屏幕到表达，让每一个细节清晰可见。" : model.selectedTab == "library" ? "截图与录屏，保存在你自己的设备上。" : "为每次截图和录屏设置合适的默认选项。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) { Circle().fill(model.permissionGranted ? mint : .orange).frame(width: 6, height: 6); Text(model.permissionGranted ? "准备就绪" : "需要屏幕权限").font(.system(size: 11)) }
                .padding(.horizontal, 12).padding(.vertical, 8).background(surface, in: Capsule())
        }.padding(.horizontal, 30).padding(.top, 32).padding(.bottom, 24)
        .overlay(alignment: .bottom) { Rectangle().fill(separator).frame(height: 1) }
    }
    private var permissionCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "display.trianglebadge.exclamationmark").font(.title2).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 5) { Text("允许 LumaCapture 捕获屏幕").font(.system(size: 13, weight: .semibold)); Text("在系统设置中开启“屏幕与系统音频录制”，然后刷新。图片编辑无需此权限。").font(.system(size: 11)).foregroundStyle(.secondary) }
            Spacer()
            Button("授予权限") { model.requestPermission() }.buttonStyle(.bordered)
            Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }.help("刷新权限")
        }.padding(18).background(.orange.opacity(0.075), in: RoundedRectangle(cornerRadius: 14))
    }
    private var capturePage: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 14) {
                sectionTitle("开始捕获", detail: "CAPTURE")
                HStack(spacing: 12) {
                    workspaceCard(.screenshot, title: "截取画面", subtitle: "默认复制，可选编辑", symbol: "camera.viewfinder", key: model.screenshotHotkey.displayName)
                    workspaceCard(.recording, title: "录制屏幕", subtitle: "画面与声音", symbol: "record.circle", key: model.recordingHotkey.displayName)
                    Button { model.importImage() } label: {
                        workspaceCardContent(title: "导入图片", subtitle: "打开已有图片", symbol: "square.and.arrow.down", key: nil, selected: false)
                    }
                    .buttonStyle(.plain)
                    .contentShape(RoundedRectangle(cornerRadius: 16))
                    .disabled(model.isWorking)
                }
            }
            VStack(alignment: .leading, spacing: 18) {
                sectionTitle("捕获来源", detail: "显示器 / 应用窗口")
                HStack {
                    Picker("来源", selection: $model.selectedTargetID) {
                        if capture.displays.isEmpty && capture.windows.isEmpty { Text("授权后选择来源").tag("") }
                        Section("显示器") { ForEach(capture.displays) { Text($0.name).tag($0.id) } }
                        Section("窗口") { ForEach(capture.windows) { Text($0.name).tag($0.id) } }
                    }.labelsHidden().frame(maxWidth: .infinity).disabled(model.isWorking)
                    Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise").frame(width: 28, height: 28) }.help("刷新显示器和窗口").disabled(model.isWorking)
                }
                HStack {
                    Picker("范围", selection: $model.useRegion) { Text("拖选区域").tag(true); Text("完整画面").tag(false) }.pickerStyle(.segmented).controlSize(.large).frame(width: 280).frame(minHeight: 36).disabled(model.target?.isWindow == true || model.isWorking)
                    Spacer()
                    Toggle("显示光标", isOn: $model.showsCursor).toggleStyle(.checkbox).font(.callout).disabled(model.isWorking)
                }
                Divider().opacity(0.4)
                HStack(spacing: 20) {
                    Toggle("系统声音", isOn: $model.systemAudio).toggleStyle(.checkbox)
                    Toggle("麦克风", isOn: $model.microphone).toggleStyle(.checkbox)
                    Spacer()
                    Picker("帧率", selection: $model.recordingFPS) { Text("30 fps").tag(30); Text("60 fps").tag(60) }.frame(width: 140)
                }.font(.callout).disabled(model.isWorking)
                Button {
                    if workspaceMode == .screenshot { model.takeScreenshot() }
                    else { model.startRecording() }
                } label: {
                    Label(workspaceMode == .screenshot ? "开始截取画面" : "开始录制屏幕",
                          systemImage: workspaceMode == .screenshot ? "camera.fill" : "record.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.isWorking || !model.permissionGranted)
            }.padding(22).background(surface, in: RoundedRectangle(cornerRadius: 18))
            if model.busy && !capture.isRecording {
                HStack { ProgressView().controlSize(.small); Text(model.countdown.map { "\($0) 秒后开始，可从菜单栏取消" } ?? "正在处理捕获…"); Spacer(); if model.countdown != nil { Button("取消") { model.cancelPending() } } }.font(.callout)
            }
            HStack { sectionTitle("最近捕获", detail: "RECENT"); Spacer(); Button("查看全部 →") { model.selectedTab = "library" }.buttonStyle(.plain).font(.caption).foregroundStyle(mint) }
            if model.records.isEmpty { emptyLibrary } else { ForEach(model.records.prefix(3)) { recordRow($0) } }
        }
    }
    private func workspaceCard(_ mode: WorkspaceMode, title: String, subtitle: String, symbol: String, key: String) -> some View {
        Button { workspaceMode = mode } label: {
            workspaceCardContent(title: title, subtitle: subtitle, symbol: symbol, key: key, selected: workspaceMode == mode)
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .disabled(model.isWorking)
    }
    private func workspaceCardContent(title: String, subtitle: String, symbol: String, key: String?, selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: symbol).font(.system(size: 24, weight: .medium))
                Spacer()
                if let key { Text(key).font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(.secondary) }
            }
            Text(title).font(.system(size: 16, weight: .semibold))
            Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .leading)
        .background(selected ? selectedFill : surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(selected ? mint : separator, lineWidth: selected ? 1.5 : 1))
        .foregroundStyle(selected ? mint : .primary)
    }
    private var recordingCard: some View {
        HStack(spacing: 16) {
            Circle().fill(.red).frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 4) {
                Text("正在录制屏幕").font(.headline)
                TimelineView(.periodic(from: .now, by: 1)) { context in Text(elapsedTime(from: capture.recordingStartedAt, now: context.date)).monospacedDigit().foregroundStyle(.secondary) }
            }
            Spacer()
            Button { model.stopRecording() } label: { Label(model.busy ? "正在保存…" : "停止并保存", systemImage: "stop.fill") }.buttonStyle(.borderedProminent).tint(.red).disabled(model.busy)
        }.padding(20).background(.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
    }
    private var libraryPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Picker("类型", selection: $model.filter) { Text("全部").tag("all"); Text("截图").tag("screenshot"); Text("录屏").tag("recording") }.pickerStyle(.segmented).frame(width: 260)
                Spacer()
                TextField("搜索文件名", text: $model.search).textFieldStyle(.roundedBorder).frame(width: 210)
            }
            if model.visibleRecords.isEmpty { emptyLibrary } else { ForEach(model.visibleRecords) { recordRow($0) } }
        }
    }
    private var emptyLibrary: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled").font(.system(size: 32, weight: .ultraLight)).foregroundStyle(mint.opacity(0.7))
            Text(model.search.isEmpty ? "好画面，从第一次捕获开始" : "没有匹配的素材").font(.system(size: 13, weight: .medium))
            Text("截图和录屏会显示在这里，点击即可再次打开。").font(.system(size: 11)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity).padding(30).background(surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
    }
    private func recordRow(_ record: CaptureRecord) -> some View {
        HStack(spacing: 14) {
            RecordThumbnail(record: record).frame(width: 64, height: 44).clipShape(RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 5) {
                Text(record.url.lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text("\(record.kind == .screenshot ? "截图" : "录屏") · \(record.createdAt.formatted(date: .abbreviated, time: .shortened))").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("打开") { model.openRecord(record) }.buttonStyle(.plain).foregroundStyle(mint).font(.caption)
            Button { model.reveal(record.url) } label: { Image(systemName: "folder") }.buttonStyle(.plain).help("在 Finder 中显示")
            Menu { Button("从历史记录移除（保留文件）") { model.forget(record) } } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24)
        }.padding(12).background(surface, in: RoundedRectangle(cornerRadius: 12))
    }
    private var settingsPage: some View {
        VStack(alignment: .leading, spacing: 24) {
            settingGroup("文件与截图") {
                HStack { Text("保存目录"); Spacer(); Text(model.outputDirectory.path).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle); Button("更改…") { model.chooseDirectory() } }
                Picker("截图延迟", selection: $model.captureDelay) { Text("立即").tag(0); Text("3 秒").tag(3); Text("5 秒").tag(5); Text("10 秒").tag(10) }
            }
            settingGroup("录屏") {
                Picker("开始前倒计时", selection: $model.recordingCountdown) { Text("立即").tag(0); Text("3 秒").tag(3); Text("5 秒").tag(5) }
                Picker("自动停止", selection: $model.maximumDuration) { Text("手动停止").tag(0); Text("30 秒").tag(30); Text("1 分钟").tag(60); Text("5 分钟").tag(300); Text("10 分钟").tag(600) }
                Text("输出 H.264 / MP4；为兼容性最高缩放至 4096 × 2160。系统声音和麦克风可在工作台分别开启。").font(.caption).foregroundStyle(.secondary)
            }
            settingGroup("快捷键与权限") {
                Toggle("启用全局快捷键", isOn: $model.hotkeysEnabled).onChange(of: model.hotkeysEnabled) { _, _ in model.configureHotkeys() }
                shortcutRow("区域截图", code: $model.screenshotHotkeyCode, modifiers: $model.screenshotHotkeyModifiers, display: $model.screenshotHotkeyDisplay)
                shortcutRow("开始 / 停止录屏", code: $model.recordingHotkeyCode, modifiers: $model.recordingHotkeyModifiers, display: $model.recordingHotkeyDisplay)
                if let error = model.hotkeyError { Text(error).font(.caption).foregroundStyle(.orange) }
                HStack { Button("屏幕录制权限") { CapturePermissions.openScreenRecordingSettings() }; Button("麦克风权限") { CapturePermissions.openMicrophoneSettings() } }
            }
            settingGroup("启动与外观") {
                Toggle("登录 Mac 时自动启动", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                Toggle("启动时不自动打开工作台", isOn: $model.silentLaunch)
                Picker("界面风格", selection: $model.appearanceMode) {
                    Text("跟随系统").tag("system"); Text("亮色").tag("light"); Text("暗黑").tag("dark")
                }.onChange(of: model.appearanceMode) { _, _ in model.applyAppearance() }
                if let error = model.launchAtLoginError { Text(error).font(.caption).foregroundStyle(.orange) }
            }
            Text("LumaCapture \(appVersion) · © Daniel · macOS 15+ · Apple Silicon / Intel\n原生构建，本地处理。源码采用 MIT 许可证。").font(.caption).foregroundStyle(.secondary).lineSpacing(5)
        }.disabled(model.isWorking)
    }
    private func settingGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 17) { Text(title).font(.system(size: 15, weight: .semibold)); Divider(); content().font(.system(size: 12)) }.padding(22).background(surface, in: RoundedRectangle(cornerRadius: 16))
    }
    private func shortcutRow(_ title: String, code: Binding<Int>, modifiers: Binding<Int>, display: Binding<String>) -> some View {
        HStack {
            Text(title); Spacer()
            ShortcutRecorderField(keyCode: code, modifiers: modifiers, displayName: display) { model.configureHotkeys() }
                .frame(width: 180, height: 32)
        }
    }
    private func sectionTitle(_ title: String, detail: String) -> some View {
        HStack(spacing: 10) { Text(title).font(.system(size: 14, weight: .semibold)); Text(detail).font(.system(size: 9, weight: .medium)).tracking(1).foregroundStyle(.tertiary) }
    }
    private var footer: some View {
        HStack { Image(systemName: "internaldrive"); Text(model.outputDirectory.path).lineLimit(1).truncationMode(.middle); Spacer(); Text("原生 · Universal 2") }.font(.system(size: 10)).foregroundStyle(.tertiary).padding(.horizontal, 30).padding(.vertical, 12)
            .overlay(alignment: .top) { Rectangle().fill(separator).frame(height: 1) }
    }
}

private struct ShortcutRecorderField: NSViewRepresentable {
    @Binding var keyCode: Int
    @Binding var modifiers: Int
    @Binding var displayName: String
    let onChange: () -> Void

    func makeNSView(context: Context) -> ShortcutRecorderView {
        let view = ShortcutRecorderView()
        view.onShortcut = { keyCode, modifiers, displayName in
            self.keyCode = keyCode
            self.modifiers = modifiers
            self.displayName = displayName
            self.onChange()
        }
        return view
    }

    func updateNSView(_ view: ShortcutRecorderView, context: Context) {
        view.displayName = displayName
    }
}

private final class ShortcutRecorderView: NSView {
    var onShortcut: ((Int, Int, String) -> Void)?
    var displayName = "" { didSet { needsDisplay = true } }
    private var isRecording = false { didSet { needsDisplay = true } }

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        toolTip = "点击后直接按下新的快捷键"
    }

    required init?(coder: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) {
        isRecording = true
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        guard event.keyCode != 53 else { isRecording = false; return }
        let carbon = carbonModifiers(from: event.modifierFlags)
        let name = shortcutDisplayName(keyCode: Int(event.keyCode), carbonModifiers: carbon, event: event)
        onShortcut?(Int(event.keyCode), carbon, name)
        isRecording = false
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.12) : NSColor.textBackgroundColor).setFill()
        path.fill()
        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = isRecording ? 1.5 : 1
        path.stroke()
        let text = isRecording ? "按下快捷键…" : displayName
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: isRecording ? NSColor.controlAccentColor : NSColor.labelColor
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }
}

private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> Int {
    var result = 0
    if flags.contains(.command) { result |= cmdKey }
    if flags.contains(.shift) { result |= shiftKey }
    if flags.contains(.option) { result |= optionKey }
    if flags.contains(.control) { result |= controlKey }
    return result
}

private func shortcutDisplayName(keyCode: Int, carbonModifiers: Int, event: NSEvent) -> String {
    let keyNames: [Int: String] = [
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫", kVK_Escape: "Esc",
        kVK_ForwardDelete: "⌦", kVK_Home: "Home", kVK_End: "End", kVK_PageUp: "Page Up",
        kVK_PageDown: "Page Down", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12"
    ]
    let key = keyNames[keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? "\(keyCode)"
    return "\(carbonModifiers & controlKey != 0 ? "⌃" : "")\(carbonModifiers & optionKey != 0 ? "⌥" : "")\(carbonModifiers & shiftKey != 0 ? "⇧" : "")\(carbonModifiers & cmdKey != 0 ? "⌘" : "")\(key)"
}

private struct RecordThumbnail: View {
    let record: CaptureRecord
    @State private var thumbnail: NSImage?
    var body: some View {
        ZStack {
            Color(nsColor: .controlBackgroundColor)
            if let thumbnail { Image(nsImage: thumbnail).resizable().scaledToFill() }
            else { Image(systemName: record.kind == .screenshot ? "photo" : "play.rectangle").foregroundStyle(.secondary) }
        }.task(id: record.url) {
            guard record.kind == .screenshot else { return }
            let url = record.url
            thumbnail = await Task.detached {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 160] as CFDictionary) else { return nil as NSImage? }
                return NSImage(cgImage: image, size: .zero)
            }.value
        }
    }
}
