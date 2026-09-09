import AppKit
import SwiftUI

@main
struct LumaCaptureApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model: AppModel
    init() {
        if let index = CommandLine.arguments.firstIndex(of: "--self-test") {
            let path = CommandLine.arguments.count > index + 1 ? CommandLine.arguments[index + 1] : NSTemporaryDirectory() + "LumaCapture-self-test"
            do {
                let directory = URL(fileURLWithPath: path, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                var checks = try CaptureSelfCheck.run()
                checks += try EditorSelfCheck.run(outputDirectory: directory)
                try (checks.joined(separator: "\n") + "\n").write(to: directory.appendingPathComponent("self-test.txt"), atomically: true, encoding: .utf8)
                print(checks.joined(separator: "\n")); print("SELF_TEST_PASSED")
                exit(0)
            } catch { fputs("SELF_TEST_FAILED: \(error)\n", stderr); exit(1) }
        }
        _model = StateObject(wrappedValue: AppModel())
    }
    var body: some Scene {
        Window("LumaCapture", id: "dashboard") {
            DashboardView(model: model, capture: model.capture)
                .task { delegate.model = model; model.configureHotkeys(); model.applyAppearance(); delegate.configureInitialPresentation(); await model.refresh() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1060, height: 740)
        .commands {
            CommandGroup(replacing: .newItem) { Button("导入图片…") { model.importImage() }.keyboardShortcut("o") }
            CommandMenu("捕获") {
                Button("区域截图") { model.takeScreenshot(scope: .region) }.disabled(model.isWorking)
                Button(model.capture.isRecording ? "停止录屏" : "开始录屏") {
                    model.capture.isRecording ? model.stopRecording() : model.startRecording()
                }
            }
        }
        MenuBarExtra { CaptureMenu(model: model, capture: model.capture) } label: { StatusLabel(model: model, capture: model.capture) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var configuredInitialPresentation = false
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard UserDefaults.standard.object(forKey: "silentLaunch") == nil || UserDefaults.standard.bool(forKey: "silentLaunch") else { return }
        DispatchQueue.main.async { NSApp.windows.forEach { $0.orderOut(nil) } }
    }
    func configureInitialPresentation() {
        guard !configuredInitialPresentation else { return }
        configuredInitialPresentation = true
        guard model?.silentLaunch == true else { return }
        NSApp.windows.filter { $0.title == "LumaCapture" || $0.identifier?.rawValue == "dashboard" }.forEach { $0.orderOut(nil) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.capture.isRecording || model.busy else { return .terminateNow }
        let alert = NSAlert(); alert.messageText = "捕获仍在进行"
        alert.informativeText = "请先停止录屏或取消倒计时，文件保存完成后再退出。"
        alert.addButton(withTitle: "返回 LumaCapture"); alert.runModal()
        model.showDashboard()
        return .terminateCancel
    }
}

struct StatusLabel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var capture: CaptureService
    var body: some View {
        if let seconds = model.countdown { Text("\(seconds)…") }
        else if capture.isRecording { Label("录制中", systemImage: "record.circle.fill").foregroundStyle(.red) }
        else { Image(systemName: "viewfinder") }
    }
}

struct CaptureMenu: View {
    @ObservedObject var model: AppModel
    @ObservedObject var capture: CaptureService
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        if capture.isRecording {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text("正在录制 · \(elapsedTime(from: capture.recordingStartedAt, now: context.date))")
            }
            Button("停止录屏并保存") { model.stopRecording() }.disabled(model.busy)
        } else {
            Button("区域截图    \(model.screenshotHotkey.displayName)") { model.takeScreenshot(scope: .region) }.disabled(model.busy)
            Button("全屏截图") { model.takeScreenshot(scope: .fullDisplay) }.disabled(model.busy)
            Divider()
            Button("区域录屏") { model.startRecording(scope: .region) }.disabled(model.busy)
            Button("全屏录屏") { model.startRecording(scope: .fullDisplay) }.disabled(model.busy)
        }
        if model.countdown != nil { Button("取消倒计时") { model.cancelPending() } }
        Divider()
        Button("导入图片并编辑…") { model.importImage() }
        Menu("最近素材") {
            if model.records.isEmpty { Text("暂无素材") }
            else {
                ForEach(model.records.prefix(8)) { record in
                    Button(record.url.lastPathComponent) { model.openRecord(record) }
                }
            }
        }
        Button("打开保存目录") { NSWorkspace.shared.open(model.outputDirectory) }
        Divider()
        Button("打开控制台…") { openWindow(id: "dashboard"); model.showDashboard() }
        Button("退出 LumaCapture") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

func elapsedTime(from start: Date?, now: Date = Date()) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(start ?? now)))
    return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
}
