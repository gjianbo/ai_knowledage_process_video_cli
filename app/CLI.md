# hive-cli 命令行上传

适合批处理和 CI。密码或令牌默认只从环境变量读取，不写入命令历史或配置文件。

```bash
cd /Users/jianboguo/Work/ai_prodjct/ai_knowledge/cli_app/app
HIVE_PASSWORD='你的密码' dart run bin/hive_cli.dart upload \
  --server http://127.0.0.1:8005/api/v1 \
  --username your-user \
  --category your-category-uuid \
  ./资料.pdf
```

可选 `--type document|image|audio|video_package` 覆盖自动类型识别。视频须先由桌面客户端打包为 `.hivepkg`，再用 `--type video_package`（或按扩展名自动识别）上传。成功时标准输出 JSON，包含 `assetId` 和 `taskId`，便于脚本继续查询或取消任务。

## 批量上传

准备 UTF-8 CSV，例如：

```csv
file,category,type
/data/报告.pdf,分类 UUID,document
/data/视频.hivepkg,分类 UUID,video_package
```

然后运行：

```bash
HIVE_TOKEN='短期令牌' dart run bin/hive_cli.dart batch \
  --server http://127.0.0.1:8005/api/v1 tasks.csv
```

也可以不提供每行 `category`，改为传一个统一的 `--category`。每条成功记录和最终汇总均输出 JSON；任一行失败时进程以状态码 `1` 结束。

传入 `--wait 1 --interval 5` 可在上传后每 5 秒查询 Worker 状态；也可单独执行 `wait --asset <asset-id>`。间隔可设为 1 到 60 秒。

## 本地配置

可保存非敏感的服务器地址和用户名，之后上传命令可省略相同参数：

```bash
dart run bin/hive_cli.dart config set --server http://127.0.0.1:8005/api/v1 --username your-user
dart run bin/hive_cli.dart config show
```

配置位于 `~/.config/hive-cli/config.json`，仅包含 `server`、`username`；密码和令牌始终只从环境变量或本次命令的 `--token` 读取。
