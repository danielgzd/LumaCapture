# 本地签名与安装提示

LumaCapture 的 GitHub Release 在没有 Developer ID secrets 时会退回 ad-hoc 签名。ad-hoc 包可以用于测试，但每次构建的代码身份会变化，覆盖安装后 macOS 可能要求重新授予屏幕录制或麦克风权限。

## 单 App 解除隔离

如果你确认安装包来自可信来源，但 macOS 仍提示“无法验证开发者”，可以只对 LumaCapture 清除下载隔离属性：

```bash
xattr -rd com.apple.quarantine /Applications/LumaCapture.app
```

这只影响 Gatekeeper 的下载隔离提示，不等同于稳定代码签名，也不能保证 TCC 权限继承。不要为了安装单个应用去全局关闭 Gatekeeper。

## 自签名本地证书

没有 Apple Developer Program 账号时，可以在自己的 Mac 上创建自签名代码签名证书，用同一个证书反复签名本机测试包。这样对同一台 Mac 上的覆盖安装更稳定，但其他用户的 Mac 仍会视为未认证开发者。

1. 打开“钥匙串访问”。
2. 选择“证书助理” -> “创建证书”。
3. 名称例如 `LumaCapture Local Signing`，证书类型选择“代码签名”。
4. 构建时使用这个证书：

```bash
SIGN_IDENTITY="LumaCapture Local Signing" scripts/build.sh --version 0.1.0
```

也可以对已有 app 重新签名：

```bash
codesign --force --deep --sign "LumaCapture Local Signing" /Applications/LumaCapture.app
```

若要让 GitHub Actions 发布包也继承权限，仍建议使用 Developer ID Application 证书并配置 `docs/RELEASE_SIGNING.md` 中的 secrets。
