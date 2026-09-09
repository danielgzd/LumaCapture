LumaCapture 是适用于 macOS 15 及以上的本地截图与录屏工具。下载文件为 Universal 2，包含 Apple Silicon（arm64）和 Intel（x86_64）架构。

本次版本增强了捕获工作台和编辑器：支持可配置全局快捷键、开机自启、默认静默启动、桌面或自选保存目录、亮色/暗黑主题；新增真实马赛克、圆角矩形、文字属性、自定义颜色、本地二维码识别、图片与 Base64 转换、自定义贴图以及画面旋转和输出缩放。

应用作为纯菜单栏工具运行，不显示 Dock 图标；区域/全屏截图、区域/全屏录制、导入图片及最近素材均可从菜单栏直接使用。

- ZIP：解压后将 LumaCapture.app 拖入“应用程序”。
- DMG：打开后将 LumaCapture 拖入 Applications。
- SHA-256：下载校验文件后，在下载目录运行 `shasum -a 256 -c LumaCapture-版本号-universal.sha256`。

CI 产物使用 ad-hoc 签名，未使用 Developer ID，也未经过 Apple 公证。macOS 可能会阻止首次打开；请先核对来源与校验值，再按 README 的系统设置流程操作。首次使用截图、录屏和麦克风时，需要授予相应系统权限。

功能范围、安装方式、测试结果及已知限制见仓库 README 和 docs/ACCEPTANCE.md。自动构建与合成媒体测试不代表所有屏幕、音频设备及 Intel 实机场景均已验证。
