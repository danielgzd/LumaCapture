# LumaCapture

LumaCapture 是一款原生 macOS 截图与录屏工具，面向 Apple Silicon 和 Intel Mac。它把区域/窗口/显示器捕获、标注、OCR、置顶贴图、录屏和本地历史记录放进一个简洁的工作台。所有图像与文字识别都在本机完成。

最低支持 macOS 15.0，发布包为 Universal 2（`arm64` + `x86_64`）；最新版本见 GitHub Releases。

## 功能

- 显示器、应用窗口、拖选区域截图，支持多显示器与 Retina
- 区域截图默认复制到剪贴板，也可在选择区域后进入编辑器
- 编辑器默认不激活工具；支持画笔、箭头、圆角矩形、椭圆、高亮、富文本、不可逆马赛克和裁剪
- 自定义颜色、图片贴图、贴图大小与角度、画面旋转和输出缩放
- 撤销/重做、PNG/JPEG 导出、复制到剪贴板
- 使用 Apple Vision 离线识别简体中文与英文
- 使用本机 Vision 识别二维码，并支持图片与 Base64 双向转换
- 将编辑结果显示为跨桌面置顶贴图
- 显示器、应用窗口与区域录屏，输出 H.264 / MP4
- 30/60 fps、光标、系统声音、麦克风、倒计时与自动停止选项
- 纯菜单栏运行，不显示 Dock 图标；菜单直接提供区域/全屏截图与录屏、导入和最近素材
- 默认静默启动、可配置开机自启、亮色/暗黑主题、本地历史记录、搜索与 Finder 定位
- 全局快捷键可修改，截图与录屏保存目录可选择，新用户默认保存到桌面
- 默认快捷键：`⌘⇧2` 区域截图，`⌘⇧6` 开始或停止录屏

## 安装

从 GitHub Releases 下载最新的 `LumaCapture-版本号-universal.dmg`，把 LumaCapture 拖到“应用程序”。也可下载 ZIP 后解压。

Release 在配置 Developer ID Application secrets 时会使用稳定签名；没有配置时会退回 ad-hoc 测试包。ad-hoc 包可能在覆盖安装后重新请求屏幕录制或麦克风权限。覆盖安装时请把新版拖到同一个“应用程序”位置替换旧版；本地自签名和解除隔离说明见 [本地签名与安装提示](docs/LOCAL_SIGNING.md)。

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

- `LumaCapture-版本号-universal.zip`
- `LumaCapture-版本号-universal.dmg`
- `LumaCapture-版本号-universal.sha256`

使用 Developer ID 或本地代码签名证书签名：

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" REQUIRE_STABLE_SIGNATURE=1 EXPECTED_TEAM_ID="TEAMID" scripts/build.sh
```

GitHub Actions Release 构建可配置签名 secrets，步骤见 [发布签名与系统权限](docs/RELEASE_SIGNING.md)。Apple 公证需要开发者账户凭据，须在签名之后另行执行 `notarytool`；仓库不会保存证书或凭据。

## 自动版本发布

合并或推送影响源代码、测试、资源、构建脚本或 Actions 配置的变更到 `main` 后，CI 会先完成测试，再把最新版本的补丁号加一，例如 `0.1.0 → 0.1.1`，创建 Git 标签并触发 Universal 2 Release 构建。Release 构建会在 Developer ID secrets 完整时使用稳定签名，否则退回 ad-hoc 测试包。文档单独修改不会产生新版本。

需要发布大版本或指定版本时，在 GitHub Actions 中手动运行 **CI**，在 `release_version` 输入完整版本号，例如 `1.0.0`。版本号必须符合 `主版本.次版本.补丁版本`，且不能与已有标签重复。

## 验证

```bash
scripts/test.sh
scripts/test.sh --arch x86_64 --portable
scripts/benchmark-editor.sh
scripts/verify-bundle.sh /path/to/LumaCapture.app
(cd dist && shasum -a 256 -c LumaCapture-版本号-universal.sha256)
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

LumaCapture 不包含账户、遥测、广告或网络上传。新用户默认保存目录为桌面，可在偏好设置中修改。录屏直接流式写入磁盘，截图、OCR、二维码和 Base64 数据不会离开本机。马赛克在导出时写入像素结果。

设计调研参考了 [CleanShot X](https://cleanshot.com/)、[Shottr](https://shottr.cc/)、[ShareX](https://github.com/ShareX/ShareX)、[Flameshot](https://github.com/flameshot-org/flameshot) 和 [QuickRecorder](https://github.com/lihaoyun6/QuickRecorder) 的公开功能。实现基于 Apple [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit)；没有复制这些项目的代码、品牌或素材。

首版没有滚动长截图、GIF、录像暂停、摄像头叠加、视频剪辑或云分享。这些功能记录在[需求文档](docs/REQUIREMENTS.md)的后续迭代范围。

## 许可证

[MIT](LICENSE)
