# 发布签名与真机验收清单

当前工程仍使用 Flutter 示例包名 `com.example.app`，未包含任何发布证书或私钥，因此不能安全地产出可发布安装包。

## 发布前需要提供

- 正式 Android applicationId、Android keystore 路径/别名，以及以 CI Secret 注入的密码。
- Apple Developer Team、正式 Bundle ID 和 provisioning profile（iOS/macOS）。
- Windows 代码签名证书（如需发布 Windows 安装包）。
- 三个平台各一台真实设备/测试机，以及可访问的 HTTPS 测试服务端。

## 真机验收顺序

1. 使用签名包登录，确认凭据仅保存在 Keychain/Keystore，退出后被清除。
2. 拖放文档、图片、音频和 2 分钟以上视频；确认视频仅在本地生成 `.hivepkg`（音频与帧），服务端不接收或保存原始视频。
3. 在服务端确认完整包被受理，Worker 最终状态与客户端一致；故意上传损坏包应在上传接口收到 400。
4. 在上传中止网络后验证取消；在 Worker 待处理时验证“取消任务”只影响当前用户上传的资源。
5. 使用 `bin/hive_cli.dart` 上传同一类资料，验证 JSON 中的 `assetId`、`taskId` 可用于审计。
6. 验证离线、令牌过期、服务端 4xx/5xx、空间不足与超大文件的可读错误提示。
