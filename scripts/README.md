# 打包脚本

在 `cli_app` 目录执行：

```bash
./scripts/build_release.sh --version 1.0.0 --build-number 1
```

支持 Android、macOS、Windows。可使用 `--platform android|macos|windows|all` 和 `--android-format apk|aab` 控制目标；`all` 只构建当前主机支持的平台。产物输出到 `cli_app/dist/<版本号>+<构建号>/`，并生成 `SHA256SUMS` 与 `release.json`。

Windows 也可直接使用 PowerShell 脚本：

```powershell
.\scripts\build_windows.ps1 -Version 1.0.0 -BuildNumber 1
```

脚本只负责构建、归档和生成校验摘要；不会上传产物、创建后台版本记录或打包前端。正式发布前仍需配置 Android keystore、Apple 签名、Windows 代码签名和正式包名。
