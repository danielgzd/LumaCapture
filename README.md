# LumaCapture

LumaCapture 是一款原生 macOS 截图与录屏工具，面向 Apple Silicon 和 Intel Mac。它把区域/窗口/显示器捕获、标注、OCR、置顶贴图、录屏和本地历史记录放进一个简洁的工作台。所有图像与文字识别都在本机完成。

当前版本：0.1.0。最低支持 macOS 15.0，发布包为 Universal 2（`arm64` + `x86_64`）。

## 功能

- 显示器、应用窗口、拖选区域截图，支持多显示器与 Retina
- 截图完成后直接进入编辑器，原始 PNG 在后台压缩和保存
- 画笔、箭头、矩形、椭圆、高亮、文字、不透明隐私遮挡和裁剪
- 撤销/重做、PNG/JPEG 导出、复制到剪贴板
- 使用 Apple Vision 离线识别简体中文与英文
- 将编辑结果显示为跨桌面置顶贴图
- 显示器、应用窗口与区域录屏，输出 H.264 / MP4
- 30/60 fps、光标、系统声音、麦克风、倒计时与自动停止选项
- 菜单栏控制、全局快捷键、本地历史记录、搜索与 Finder 定位
- 默认快捷键：`⌘⇧2` 区域截图，`⌘⇧6` 开始或停止录屏

## 安装

从 GitHub Releases 下载 `LumaCapture-0.1.0-universal.dmg`，把 LumaCapture 拖到“应用程序”。也可下载 ZIP 后解压。

0.1.0 的公开构建使用 ad-hoc 本地签名，没有 Apple 公证。首次启动若 macOS 阻止打开，请先尝试打开一次，再前往“系统设置 → 隐私与安全性”，找到被阻止的 LumaCapture 并选择“仍要打开”。自行配置 Developer ID 后，构建脚本可生成 hardened runtime 签名包。

首次截图或录屏时，在“系统设置 → 隐私与安全性 → 屏幕与系统音频录制”允许 LumaCapture。只有启用麦克风录制时才会请求麦克风权限。系统可能要求退出并重新打开应用。

## 从源码构建

需要 macOS、Xcode 16 或更高版本。脚本不会修改全局 `xcode-select`，也没有第三方依赖。

```bash
git clone https://github.com/danielgzd/LumaCapture.git
cd LumaCapture
scripts/test.sh
scripts/build.sh --self-test
```

产物写入 `dist/`：

- `LumaCapture-0.1.0-universal.zip`
- `LumaCapture-0.1.0-universal.dmg`
- `LumaCapture-0.1.0-universal.sha256`

使用 Developer ID 签名：

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/build.sh
```

Apple 公证需要开发者账户凭据，须在签名之后另行执行 `notarytool`；仓库不会保存证书或凭据。

## 验证

```bash
scripts/test.sh
scripts/test.sh --arch x86_64 --portable
scripts/benchmark-editor.sh
scripts/verify-bundle.sh /path/to/LumaCapture.app
(cd dist && shasum -a 256 -c LumaCapture-0.1.0-universal.sha256)
```

`scripts/test.sh` 验证负坐标显示器坐标、区域裁剪、Retina 像素、视频偶数尺寸、历史记录损坏处理、容量限制、Unicode 路径及文件名碰撞。`scripts/benchmark-editor.sh` 使用合成 4K 图像、80 个标注和 10,000 个涂鸦点记录渲染与导出基准。`scripts/build.sh --self-test` 额外验证编辑渲染、裁剪方向、隐私遮挡像素、PNG/JPEG 回读和应用包结构。真实屏幕与音频捕获仍需由已授予权限的交互会话验证。

## 项目结构

```text
Sources/LumaCapture/App       SwiftUI 工作台、菜单栏、历史和快捷键
Sources/LumaCapture/Capture   ScreenCaptureKit 截图、区域选择与录屏
Sources/LumaCapture/Editor    AppKit/SwiftUI 编辑器、Vision OCR 与贴图
Sources/LumaCaptureCore       可独立测试的坐标、历史和命名逻辑
Tests                         核心行为测试
docs                          需求、任务与验收记录
scripts                       测试、Universal 构建、签名与打包
```

## 设计与隐私

LumaCapture 不包含账户、遥测、广告或网络上传。默认保存目录为 `~/Pictures/LumaCapture`。录屏直接流式写入磁盘，截图和 OCR 数据不会离开本机。隐私遮挡导出为不透明黑色像素，而不是可逆的视觉模糊。

设计调研参考了 [CleanShot X](https://cleanshot.com/)、[Shottr](https://shottr.cc/)、[ShareX](https://github.com/ShareX/ShareX)、[Flameshot](https://github.com/flameshot-org/flameshot) 和 [QuickRecorder](https://github.com/lihaoyun6/QuickRecorder) 的公开功能。实现基于 Apple [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit)；没有复制这些项目的代码、品牌或素材。

首版没有滚动长截图、GIF、录像暂停、摄像头叠加、视频剪辑或云分享。这些功能记录在[需求文档](docs/REQUIREMENTS.md)的后续迭代范围。

## 许可证

[MIT](LICENSE)
