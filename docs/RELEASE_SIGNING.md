# 发布签名与系统权限

macOS 的屏幕录制、麦克风等 TCC 权限不只按应用名称或 Bundle ID 保存，还会校验应用的代码签名指定要求（designated requirement）。LumaCapture 的 Bundle ID 固定为 `io.github.danielgzd.LumaCapture`。

旧版发布包使用 ad-hoc 签名。ad-hoc 应用的指定要求包含构建产物的 CDHash，而 CDHash 每次编译都会变化，因此覆盖安装会被系统视为不同的应用身份，已有权限不会沿用。

正式发布必须始终使用同一个 Apple Developer Program 团队签发的 `Developer ID Application` 证书。GitHub 仓库需要配置以下 Actions secrets：

- `MACOS_CERTIFICATE`：Developer ID Application `.p12` 文件的 Base64 内容。
- `MACOS_CERTIFICATE_PASSWORD`：导出 `.p12` 时设置的密码。
- `KEYCHAIN_PASSWORD`：Actions 临时钥匙串密码，可使用随机强密码。
- `MACOS_SIGN_IDENTITY`：完整证书名称，例如 `Developer ID Application: Name (TEAMID)`。
- `APPLE_TEAM_ID`：Apple Developer Team ID。

生成 `MACOS_CERTIFICATE` 时可在本机执行：

```bash
base64 -i DeveloperIDApplication.p12 | pbcopy
```

私钥、证书文件和密码不得提交到仓库。Release 工作流会在 secrets 完整时把证书导入临时钥匙串，并校验 Team ID；secrets 缺失时会退回 ad-hoc 测试包。普通本地开发也可使用默认 ad-hoc 签名。

自动小版本发布会在这些 secrets 完整时使用 Developer ID 签名；如果缺少 secrets，Release 会退回 ad-hoc 签名测试包。ad-hoc 包没有稳定签名身份，覆盖安装后 macOS 可能需要重新授予屏幕录制或麦克风权限。Release 构建会把 GitHub Actions 的 run number 写入 `CFBundleVersion`，补丁版本仍由 tag 控制。

从 v0.1.4 及更早的 ad-hoc 版本首次升级到 Developer ID 正式签名版本时，签名身份发生变化，macOS 通常会要求用户重新授予屏幕录制和麦克风权限。这次迁移无法通过覆盖安装规避。完成一次重新授权后，只要 Bundle ID、Developer ID 团队和指定要求保持稳定，后续覆盖更新即可沿用权限。
