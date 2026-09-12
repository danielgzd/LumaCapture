# 获取 LumaCapture 闪退日志

如果 LumaCapture 闪退，请先记录发生时间和操作步骤，再发送最新的 `LumaCapture-*.ips` 文件。

## Finder

1. 打开 Finder，按 `Shift + Command + G`。
2. 输入 `~/Library/Logs/DiagnosticReports` 并回车。
3. 按修改日期排序，找到最新的 `LumaCapture-日期-时间.ips`。

也可以打开“控制台”应用，在左侧选择“崩溃报告”，搜索 `LumaCapture`。

## 终端

查看最新的崩溃报告：

```bash
ls -t "$HOME/Library/Logs/DiagnosticReports"/LumaCapture-*.ips | head
```

打开日志目录：

```bash
open "$HOME/Library/Logs/DiagnosticReports"
```

导出最近十分钟的运行日志：

```bash
log show --predicate 'process == "LumaCapture"' --last 10m --style compact > "$HOME/Desktop/LumaCapture-runtime.log"
```

确认当前安装版本：

```bash
defaults read /Applications/LumaCapture.app/Contents/Info CFBundleShortVersionString
defaults read /Applications/LumaCapture.app/Contents/Info CFBundleVersion
```

请一并提供应用版本、macOS 版本、Mac 芯片型号，以及能稳定复现闪退的步骤。日志可能包含本机路径或进程信息，公开发布前请先检查内容。
