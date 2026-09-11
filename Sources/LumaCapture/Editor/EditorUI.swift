import AppKit
import SwiftUI

private let editorAccent = Color(nsColor: NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(red: 0.50, green: 0.91, blue: 0.78, alpha: 1)
        : NSColor(red: 0.05, green: 0.43, blue: 0.34, alpha: 1)
})
private let selectedToolForeground = Color(nsColor: NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .black : .white
})

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
            onPin: { [weak self] in
                document.preparePin { [weak self] image in self?.pin(image: image) }
            }))
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
                    .foregroundStyle(editorAccent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("让重点一目了然").font(.headline)
                    Text(document.sourceURL?.lastPathComponent ?? "未命名截图")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 12)
                Button(action: document.recognizeText) {
                    Label(document.isRecognizing ? "识别中…" : "提取文字", systemImage: "text.viewfinder")
                }
                .disabled(document.isRecognizing || document.isExporting)
                .help("使用本机 Vision 识别中文和英文")
                Button(action: document.recognizeQR) { Label("二维码", systemImage: "qrcode.viewfinder") }
                    .disabled(document.isRecognizing || document.isExporting)
                Menu {
                    Button("文字转二维码") { document.qrInputText = ""; document.showsQRGenerator = true }
                    Button("图片转 Base64") { document.encodeBase64() }
                    Button("Base64 转图片") { document.base64Text = ""; document.base64ModeIsDecode = true; document.showsBase64 = true }
                } label: { Label("转换", systemImage: "arrow.left.arrow.right") }
                Button(action: onPin) { Label("贴图", systemImage: "pin") }
                    .disabled(document.isRecognizing || document.isExporting)
                    .help("将当前编辑结果显示在置顶参考窗")
                Menu {
                    Button("另存为 PNG…") { onSave(false) }.keyboardShortcut("s", modifiers: .command)
                    Button("另存为 JPEG…") { onSave(true) }.keyboardShortcut("s", modifiers: [.command, .shift])
                } label: { Label("另存为", systemImage: "square.and.arrow.down") }
                    .fixedSize()
                    .disabled(document.isRecognizing || document.isExporting)
                Button(action: document.copyImage) { Label("复制图像", systemImage: "doc.on.doc") }
                    .buttonStyle(.borderedProminent)
                    .tint(editorAccent)
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(document.isRecognizing || document.isExporting)
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
                        .foregroundStyle(document.tool == tool ? selectedToolForeground : Color.primary)
                        .background(document.tool == tool ? editorAccent : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor), lineWidth: document.tool == tool ? 0 : 1))
                    }
                    .buttonStyle(.plain)
                    .help(tool == .redact ? "拖动添加不可逆马赛克" : tool == .crop ? "拖选区域，松开应用裁剪；可撤销" : tool.title)
                    .accessibilityLabel(tool.title)
                    .accessibilityAddTraits(document.tool == tool ? .isSelected : [])
                }
                Divider().frame(height: 34).padding(.horizontal, 6)
                HStack(spacing: 7) {
                    ForEach(Array(palette.enumerated()), id: \.offset) { _, color in
                        Button { document.color = color } label: {
                            Circle().fill(Color(nsColor: color))
                                .frame(width: 19, height: 19)
                                .overlay(Circle().stroke(Color(nsColor: .separatorColor), lineWidth: 1))
                                .padding(3)
                                .overlay(Circle().stroke(document.color.isEqual(color) ? editorAccent : Color.clear, lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(colorName(color))
                    }
                    ColorPicker("自定义", selection: Binding(
                        get: { Color(nsColor: document.color) },
                        set: { document.color = NSColor($0) }
                    )).labelsHidden().help("选择自定义颜色")
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
                if document.tool == nil {
                    Text("未选择编辑工具").foregroundStyle(.secondary)
                } else if document.tool == .text {
                    Text("字号").foregroundStyle(.secondary)
                    Slider(value: $document.fontSize, in: 14...100, step: 2).frame(width: 105)
                    Text("\(Int(document.fontSize)) px").monospacedDigit().frame(width: 48, alignment: .leading)
                    Toggle("粗体", isOn: $document.isBold).toggleStyle(.checkbox)
                    Text("点击图像后输入文字").foregroundStyle(.secondary)
                } else if document.tool == .rectangle {
                    Text("线宽").foregroundStyle(.secondary)
                    Slider(value: $document.strokeWidth, in: 2...32, step: 1).frame(width: 100)
                    Text("圆角").foregroundStyle(.secondary)
                    Slider(value: $document.rectangleCornerRadius, in: 0...80, step: 2).frame(width: 110)
                    Text("\(Int(document.rectangleCornerRadius)) px").monospacedDigit()
                } else if document.tool == .image {
                    Button("导入贴图…") { document.importSticker(window: NSApp.keyWindow) }
                    Text("大小").foregroundStyle(.secondary)
                    Slider(value: Binding(get: { document.stickerScale }, set: document.setStickerScale),
                           in: 0.25...2, step: 0.05).frame(width: 100)
                    Text("旋转").foregroundStyle(.secondary)
                    Slider(value: Binding(get: { document.stickerRotation }, set: document.setStickerRotation),
                           in: -180...180, step: 1).frame(width: 100)
                } else if [.pen, .arrow, .rectangle, .ellipse].contains(document.tool) {
                    Text("线宽").foregroundStyle(.secondary)
                    Slider(value: $document.strokeWidth, in: 2...32, step: 1).frame(width: 130)
                    Text("\(Int(document.strokeWidth)) px").monospacedDigit().frame(width: 42, alignment: .leading)
                    Text("在图像上拖动绘制 · Esc 取消").foregroundStyle(.secondary)
                } else {
                    Text(document.tool == .redact ? "拖动覆盖敏感信息，导出后区域会写入不可逆马赛克像素。" :
                         document.tool == .crop ? "拖选保留区域，松开应用；撤销可恢复。" : "拖动矩形区域添加半透明高亮。")
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button { document.rotateClockwise() } label: { Label("旋转 90°", systemImage: "rotate.right") }
                Menu("图像大小") {
                    ForEach([0.5, 0.75, 1.0, 1.5, 2.0], id: \.self) { value in
                        Button("\(Int(value * 100))%") { document.setImageScale(value) }
                    }
                }
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
                Image(systemName: "info.circle").foregroundStyle(editorAccent)
                Text(document.status).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text("\(Int(document.outputSize.width)) × \(Int(document.outputSize.height)) px")
                    .monospacedDigit().foregroundStyle(.secondary)
                Text("本地处理").foregroundStyle(.secondary)
            }
            .font(.caption).padding(.horizontal, 20).padding(.vertical, 11)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(editorAccent)
        .sheet(isPresented: $document.showsOCR) { ocrSheet }
        .sheet(isPresented: $document.showsQR) { qrSheet }
        .sheet(isPresented: $document.showsQRGenerator) { qrGeneratorSheet }
        .sheet(isPresented: $document.showsBase64) { base64Sheet }
        .alert("操作未完成", isPresented: Binding(get: { document.errorMessage != nil }, set: { if !$0 { document.errorMessage = nil } })) {
            Button("知道了") { document.errorMessage = nil }
        } message: { Text(document.errorMessage ?? "") }
    }

    private var qrSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("二维码识别").font(.title2.bold())
            if document.qrResults.isEmpty { ContentUnavailableView("未识别到二维码", systemImage: "qrcode") }
            else { List(document.qrResults, id: \.self) { Text($0).textSelection(.enabled) } }
            HStack { Spacer(); Button("关闭") { document.showsQR = false }; Button("全部复制") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(document.qrResults.joined(separator: "\n"), forType: .string) }.disabled(document.qrResults.isEmpty) }
        }.padding(24).frame(width: 600, height: 380)
    }

    private var qrGeneratorSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("文字转二维码").font(.title2.bold())
            TextEditor(text: $document.qrInputText)
                .font(.system(size: 14))
                .frame(minHeight: 120)
                .border(.secondary.opacity(0.25))
            HStack(spacing: 16) {
                if let image = document.qrPreviewImage(), !document.qrInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Image(nsImage: image).interpolation(.none).resizable().scaledToFit()
                        .frame(width: 128, height: 128)
                        .background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor))
                        .frame(width: 128, height: 128)
                        .overlay(Image(systemName: "qrcode").font(.largeTitle).foregroundStyle(.secondary))
                }
                Text("输入任意文字、链接或编号后，可复制二维码，或作为贴图添加到当前图片。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            HStack {
                Spacer()
                Button("关闭") { document.showsQRGenerator = false }
                Button("复制二维码") { document.copyGeneratedQRCode() }
                    .disabled(document.qrInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("添加到图片") { document.addGeneratedQRCodeToCanvas() }
                    .buttonStyle(.borderedProminent)
                    .disabled(document.qrInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 560)
    }

    private var base64Sheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(document.base64ModeIsDecode ? "Base64 转图片" : "图片转 Base64").font(.title2.bold())
            TextEditor(text: $document.base64Text).font(.system(.caption, design: .monospaced)).frame(minHeight: 280).border(.secondary.opacity(0.25))
            HStack { Spacer(); Button("关闭") { document.showsBase64 = false }; if document.base64ModeIsDecode { Button("保存图片…") { document.decodeBase64(window: NSApp.keyWindow) }.buttonStyle(.borderedProminent) } else { Button("复制") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(document.base64Text, forType: .string) }.buttonStyle(.borderedProminent) } }
        }.padding(24).frame(width: 680, height: 430)
    }

    private var ocrSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "text.viewfinder").font(.title2).foregroundStyle(editorAccent)
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
                    .padding(10).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor)))
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
        .padding(24).frame(width: 620)
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
