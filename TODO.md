# hive-cli 开发待办

> 范围：Flutter 跨平台资料上传客户端（Android / Windows / macOS）。依据 `docs/ai_knowledge_design.md` 第 8 章与 `cli_app/docs/index.html` 原型。更新时间：2026-08-11。

## 首个可演示版本

- [x] 建立自适应 GUI：桌面队列与窄屏界面共用同一业务状态。
- [x] 支持多文件选择、格式识别、逐项移除、逐项/默认分类和队列状态。
- [x] 支持登录状态与未登录仅处理视频的界面规则。
- [x] 建立串行处理的交互状态（打包 → 上传 → 完成）；当前为本地演示流程。
- [x] 已对接本地管理后端 `http://127.0.0.1:8005/api/v1`：登录、资料上传、任务查询与任务取消。
- [x] 已对接 v1 `POST /assets/upload`，展示实时上传进度、服务端错误、逐项取消与重试。
- [-] 已接入 ffmpeg 代码：视频抽音频、按 30 秒间隔抽帧、生成符合规范的 `.hivepkg`；静态验证已通过，待 macOS/Android 原生构建和真机处理样本验证。
- [x] 已实现 `.hivepkg` 本地导出和 v1 `video_package` 上传；服务端在入库前校验 ZIP 路径、manifest、音频 M4A 头、帧图片头、帧引用/时间顺序与重复项。

## P1：稳定可用

- [-] GUI 的 `auth`、`resource`、`package`、`queue` 领域层待继续抽离；CLI 先冻结，后续可能以 Go 重写，不再要求与 GUI 共享处理核心。
- [-] 已持久化服务器地址和自动上传偏好；JWT 放系统安全存储，启动时通过 v1 `/auth/profile` 验证并恢复会话。待 macOS/Android 真机验证 Keychain/Keystore。
- [x] 已展示上传失败原因、上传取消/重试，轮询 v1 Worker 状态，并支持上传者取消自己的待处理任务；不上传原始大视频，断点续传不在当前范围。
- [-] 已在选择文件时用客户端限制校验文档/图片/音频格式和大小，并拒绝空文件；v1 当前没有 `frontend/config` 接口，视频可解码性在 FFmpeg 真机处理验证阶段确认。
- [-] 已完成拖放添加、任务进度和批量结果汇总；拖放区已具备语义提示，完整无障碍键盘操作待补。

## 已明确不做

- [x] 原始大视频上传与断点续传：视频仅在客户端本地转换为包含音频与帧的 `.hivepkg`，服务端不保存原始视频文件。
- [~] access-key 上传权限和 MCP CLI 模式：当前 GUI 仅使用 Bearer 登录模式；CLI 已冻结，后续按 Go 重写方案另行评估。

## P2：CLI 与发布

- [~] CLI 当前实现冻结；后续评估以 Go 重写并采用登录/JWT 会话方案。
- [~] CLI access-key、视频 process 与配置持久化暂不继续开发。
- [-] 已配置 Android 网络权限、macOS 网络/Keychain 权限与 FFmpeg 依赖；发布签名未配置（当前包名仍为 `com.example.app`，需要正式包名、Android keystore 和 Apple Team/证书）。
- [-] 已覆盖 manifest、登录/分类读取、文档和视频包上传的可选集成测试；类型识别、队列状态、拖放、取消、重试、CLI CSV 与等待模式仍需单元/集成覆盖。
- [x] 增加可选的 v1 后端集成测试：环境变量提供测试账号时验证登录、profile 与分类读取；未提供凭据时自动跳过。
- [x] 增加显式开关的 v1 文档上传验收：仅 `HIVE_RUN_WRITE_TESTS=1` 时创建一条可识别的测试资料。
- [ ] 编写安装、权限、网络故障和隐私说明，并在真机与桌面端做验收。

## 接口确认项

- [-] 已确认 v1 `POST /assets/upload`、返回 `id` / `taskId`、`GET /tasks?targetId=` 查询和 `POST /tasks/{id}/cancel`；分片协议待实现。
- [x] 已确认 GUI 登录模式使用 v1 `POST /assets/upload`，并以 `assetType=video_package` 上传 `.hivepkg`；access_key/MCP CLI 模式仍待实现。
- [ ] 确认分类接口的树形字段和普通用户可见范围；当前客户端按扁平分类列表展示。
