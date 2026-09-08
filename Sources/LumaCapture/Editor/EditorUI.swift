import AppKit
import SwiftUI

@MainActor
final class EditorCoordinator: NSObject, NSWindowDelegate {
    private var windows: [ObjectIdentifier: NSWindowController] = [:]

    func open(image: CGImage, sourceURL: URL?, onExport: @escaping (URL) -> Void) {
        let document = EditorDocument(image: image, sourceURL: sourceURL, onExport: onExport)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "LumaCapture · 图像编辑器"
        window.minSize = NSSize(width: 980, height: 600)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: EditorRootView(document: document,
            onSave: { [weak window] jpeg in document.save(jpeg: jpeg, window: window) },
            onPin: { [weak self] in self?.pin(image: document.preview) }))
        let controller = NSWindowController(window: window)
        windows[ObjectIdentifier(window)] = controller
        window.center()
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func pin(image: CGImage) {
        let factor = min(1, min(640 / CGFloat(image.width), 480 / CGFloat(image.height)))
        let size = NSSize(width: max(120, CGFloat(image.width) * factor), height: max(80, CGFloat(image.height) * factor))
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "LumaCapture · 置顶贴图"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.minSize = NSSize(width: 120, height: 100)
        panel.backgroundColor = .black
        let imageView = NSImageView(frame: NSRect(origin: .zero, size: size))
        imageView.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.setAccessibilityLabel("置顶截图，可拖动标题栏或缩放窗口；关闭按钮可移除贴图。")
        panel.contentView = imageView
        let controller = NSWindowController(window: panel)
        windows[ObjectIdentifier(panel)] = controller
        panel.center()
        controller.showWindow(nil)
        panel.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        windows.removeValue(forKey: ObjectIdentifier(window))
    }
}

private struct EditorRootView: View {
    @ObservedObject var document: EditorDocument
    let onSave: (Bool) -> Void
    let onPin: () -> Void
    private let palette: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .white, .black]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 25, weight: .medium))
                    .foregroundStyle(.mint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("让重点一目了然").font(.headline)
                    Text(document.sourceURL?.lastPathComponent ?? "未命名截图")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 12)
                Button(action: document.recognizeText) {
                    Label(document.isRecognizing ? "识别中…" : "提取文字", systemImage: "text.viewfinder")
                }
                .disabled(document.isRecognizing)
                .help("使用本机 Vision 识别中文和英文")
                Button(action: onPin) { Label("贴图", systemImage: "pin") }
                    .help("将当前编辑结果显示在置顶参考窗")
                Menu {
                    Button("另存为 PNG…") { onSave(false) }.keyboardShortcut("s", modifiers: .command)
                    Button("另存为 JPEG…") { onSave(true) }.keyboardShortcut("s", modifiers: [.command, .shift])
                } label: { Label("另存为", systemImage: "square.and.arrow.down") }
                    .fixedSize()
                Button(action: document.copyImage) { Label("复制图像", systemImage: "doc.on.doc") }
                    .buttonStyle(.borderedProminent)
                    .tint(.mint)
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .help("复制当前编辑结果（⌘⇧C；画布中也可使用 ⌘C）")
            }
            .controlSize(.large)
            .padding(.horizontal, 20).padding(.vertical, 16)

            Divider()

            HStack(spacing: 8) {
                ForEach(EditorTool.allCases) { tool in
                    Button { document.tool = tool } label: {
                        VStack(spacing: 4) {
                            Image(systemName: tool.symbol).font(.system(size: 16, weight: .medium)).frame(height: 20)
                            Text(tool.title).font(.system(size: 10, weight: .medium))
                        }
                        .frame(width: 42, height: 46)
                        .foregroundStyle(document.tool == tool ? Color.black : Color.primary)
                        .background(document.tool == tool ? Color.mint : Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .help(tool == .redact ? "拖动添加不透明黑色遮挡" : tool == .crop ? "拖选区域，松开应用裁剪；可撤销" : tool.title)
                    .accessibilityLabel(tool.title)
                    .accessibilityAddTraits(document.tool == tool ? .isSelected : [])
                }
                Divider().frame(height: 34).padding(.horizontal, 6)
                HStack(spacing: 7) {
                    ForEach(Array(palette.enumerated()), id: \.offset) { _, color in
                        Button { document.color = color } label: {
                            Circle().fill(Color(nsColor: color))
                                .frame(width: 19, height: 19)
                                .overlay(Circle().stroke(Color.white.opacity(0.35), lineWidth: 1))
                                .padding(3)
                                .overlay(Circle().stroke(document.color.isEqual(color) ? Color.mint : Color.clear, lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(colorName(color))
                    }
                }
                .opacity(document.tool == .redact || document.tool == .crop ? 0.4 : 1)
                .disabled(document.tool == .redact || document.tool == .crop)
                Spacer(minLength: 8)
                Button(action: document.undo) { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!document.history.canUndo).help("撤销（⌘Z）")
                    .keyboardShortcut("z", modifiers: .command)
                    .accessibilityLabel("撤销")
                Button(action: document.redo) { Image(systemName: "arrow.uturn.forward") }
                    .disabled(!document.history.canRedo).help("重做（⌘⇧Z）")
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .accessibilityLabel("重做")
            }
            .padding(.horizontal, 20).padding(.vertical, 10)

            HStack(spacing: 12) {
                if document.tool == .text {
                    TextField("要添加的文字", text: $document.text)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 360)
                    Text("字号").foregroundStyle(.secondary)
                    Slider(value: $document.fontSize, in: 14...100, step: 2).frame(width: 105)
                    Text("\(Int(document.fontSize)) px").monospacedDigit().frame(width: 48, alignment: .leading)
                    Text("点击图像放置").foregroundStyle(.secondary)
                } else if [.pen, .arrow, .rectangle, .ellipse].contains(document.tool) {
                    Text("线宽").foregroundStyle(.secondary)
                    Slider(value: $document.strokeWidth, in: 2...32, step: 1).frame(width: 130)
                    Text("\(Int(document.strokeWidth)) px").monospacedDigit().frame(width: 42, alignment: .leading)
                    Text("在图像上拖动绘制 · Esc 取消").foregroundStyle(.secondary)
                } else {
                    Text(document.tool == .redact ? "拖动覆盖敏感信息，导出后遮挡区域为不透明黑色。" :
                         document.tool == .crop ? "拖选保留区域，松开应用；撤销可恢复。" : "拖动矩形区域添加半透明高亮。")
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Picker("缩放", selection: $document.zoom) {
                    Text("适应窗口").tag(0.0)
                    Text("50%").tag(0.5)
                    Text("100%").tag(1.0)
                    Text("200%").tag(2.0)
                }.frame(width: 158)
            }
            .font(.caption).padding(.horizontal, 20).padding(.bottom, 12).frame(height: 36)

            EditorCanvas(document: document)

            HStack(spacing: 12) {
                Image(systemName: "info.circle").foregroundStyle(.mint)
                Text(document.status).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text("\(document.preview.width) × \(document.preview.height) px")
                    .monospacedDigit().foregroundStyle(.secondary)
                Text("本地处理").foregroundStyle(.secondary)
            }
            .font(.caption).padding(.horizontal, 20).padding(.vertical, 11)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.dark)
        .tint(.mint)
        .sheet(isPresented: $document.showsOCR) { ocrSheet }
        .alert("操作未完成", isPresented: Binding(get: { document.errorMessage != nil }, set: { if !$0 { document.errorMessage = nil } })) {
            Button("知道了") { document.errorMessage = nil }
        } message: { Text(document.errorMessage ?? "") }
    }

    private var ocrSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "text.viewfinder").font(.title2).foregroundStyle(.mint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("提取文字").font(.title2.bold())
                    Text("中文 / English · 识别内容只在本机处理").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if document.ocrText.isEmpty {
                ContentUnavailableView("未识别到文字", systemImage: "text.magnifyingglass",
                                       description: Text("请尝试包含更清晰、更大文字的截图。"))
                    .frame(maxWidth: .infinity, minHeight: 240)
            } else {
                TextEditor(text: $document.ocrText)
                    .font(.system(size: 14)).scrollContentBackground(.hidden)
                    .padding(10).background(Color.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
                    .frame(minHeight: 280)
            }
            HStack {
                Text("可编辑识别结果后复制。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("关闭") { document.showsOCR = false }.keyboardShortcut(.cancelAction)
                Button("复制文字") {
                    NSPasteboard.general.clearContents()
                    if NSPasteboard.general.setString(document.ocrText, forType: .string) { document.status = "已复制识别文字。" }
                }
                .buttonStyle(.borderedProminent).disabled(document.ocrText.isEmpty)
            }
        }
        .padding(24).frame(width: 620).preferredColorScheme(.dark)
    }

    private func colorName(_ color: NSColor) -> String {
        if color.isEqual(NSColor.systemRed) { return "红色" }
        if color.isEqual(NSColor.systemOrange) { return "橙色" }
        if color.isEqual(NSColor.systemYellow) { return "黄色" }
        if color.isEqual(NSColor.systemGreen) { return "绿色" }
        if color.isEqual(NSColor.systemBlue) { return "蓝色" }
        if color.isEqual(NSColor.white) { return "白色" }
        return "黑色"
    }
}
