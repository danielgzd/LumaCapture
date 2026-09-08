LumaCapture 是适用于 macOS 15 及以上的本地截图与录屏工具。下载文件为 Universal 2，包含 Apple Silicon（arm64）和 Intel（x86_64）架构。

- ZIP：解压后将 LumaCapture.app 拖入“应用程序”。
- DMG：打开后将 LumaCapture 拖入 Applications。
- SHA-256：下载校验文件后，在下载目录运行 `shasum -a 256 -c LumaCapture-版本号-universal.sha256`。

CI 产物使用 ad-hoc 签名，未使用 Developer ID，也未经过 Apple 公证。macOS 可能会阻止首次打开；请先核对来源与校验值，再按 README 的系统设置流程操作。首次使用截图、录屏和麦克风时，需要授予相应系统权限。

功能范围、安装方式、测试结果及已知限制见仓库 README 和 docs/ACCEPTANCE.md。自动构建与合成媒体测试不代表所有屏幕、音频设备及 Intel 实机场景均已验证。
