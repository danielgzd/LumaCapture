# 实施任务与分工

先冻结 REQUIREMENTS.md，再按以下边界并行实施。主 agent 负责最终集成和验收。

| 任务 | 负责人 | 文件边界 | 交付/验收 |
| --- | --- | --- | --- |
| T01 需求与架构 | 主 agent | docs/REQUIREMENTS.md、docs/TASKS.md、Package.swift | 首版范围、接口与验收基线 |
| T02 捕获与录屏 | capture agent | Sources/LumaCapture/Capture/ | ScreenCaptureKit 截图、选区、录屏、权限 |
| T03 标注与 OCR | editor agent | Sources/LumaCapture/Editor/ | 编辑器、导出、OCR、贴图、渲染自检 |
| T04 构建与测试基础 | release agent | scripts/、Resources/、.github/、Tests/ | Universal 打包、自动测试、CI、图标 |
| T05 控制台与数据 | 主 agent | Sources/LumaCapture/App/、Sources/LumaCaptureCore/ | 主界面、历史、设置、快捷键、状态联动 |
| T06 集成验收 | 主 agent + 各模块复审 | docs/ACCEPTANCE.md | 修复编译及功能问题，记录真实结果 |
| T07 GitHub 发布 | 主 agent | README.md、LICENSE、仓库与 Release | 提交代码，上传 ZIP/DMG/校验值 |

## 模块接口

所有 App 文件属于 LumaCapture executable target，macOS 15，Swift language mode 5。Foundation/CoreGraphics 纯逻辑放入 LumaCaptureCore library，供 XCTest 测试。

捕获模块：`@MainActor final class CaptureService: ObservableObject`；暴露 `displays: [CaptureTarget]`、`windows: [CaptureTarget]`、`isRecording: Bool`、`recordingStartedAt: Date?`、`errorMessage: String?`；`refreshTargets() async`、`capture(target: CaptureTarget, region: CGRect?, showsCursor: Bool) async throws -> CGImage`、`startRecording(target: CaptureTarget, region: CGRect?, options: RecordingOptions, outputURL: URL) async throws`、`stopRecording() async throws -> URL`。`CaptureTarget: Identifiable, Hashable` 包含 `id: String`、`name: String`、`isWindow: Bool`。`RecordingOptions` 包含 `framesPerSecond: Int`、`showsCursor: Bool`、`capturesSystemAudio: Bool`、`capturesMicrophone: Bool`。`RegionSelector.select(displayID: CGDirectDisplayID) async -> CGRect?` 返回显示器左上角为原点的逻辑点坐标。CaptureTarget 额外提供 `displayID: CGDirectDisplayID?`。服务显式处理录制回调完成后才返回已完成 URL。

编辑模块：`@MainActor final class EditorCoordinator`，提供 `open(image: CGImage, sourceURL: URL?, onExport: @escaping (URL) -> Void)`；持有窗口生命期。`EditorSelfCheck.run(outputDirectory: URL) throws -> [String]` 运行合成图像的渲染/OCR/导出检查（可依实现补充异步）。编辑器独立包含所有工具与保存/复制/贴图入口。

主程序保留 `--self-test` 命令行模式，用来运行核心、编辑器和媒体无权限自检，并将结果写入指定临时目录；实际捕获验收必须独立记录。

## 验收阶段

1. 编译所有模块，运行纯逻辑单元测试及合成图像/媒体集成检查。
2. 创建 Universal app，检查两种架构、最低系统、资源、签名、包完整性。
3. 启动 app，检查 UI、菜单栏、设置、编辑器；权限允许后实际截图、录屏、导出并探测媒体内容。
4. 明确区分已通过、环境限制与未来功能；更新需求状态和验收报告。
5. 扫描提交内容，提交代码，创建 GitHub 仓库和 release 并验证远程结果。
