import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'models/api_models.dart';
import 'services/hive_api.dart';
import 'services/session_store.dart';
import 'services/video_package_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const HiveCliApp());
}

class HiveCliApp extends StatelessWidget {
  const HiveCliApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '知桥 Hive',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1C7C70)),
      scaffoldBackgroundColor: const Color(0xFFF6F8F7),
    ),
    home: const UploadHomePage(),
  );
}

enum ResourceType { video, audio, image, document, unsupported }

enum JobStatus {
  waiting,
  packaging,
  uploading,
  processing,
  completed,
  failed,
  cancelled,
}

class UploadItem {
  UploadItem({required this.file, required this.type});
  final PlatformFile file;
  final ResourceType type;
  CategoryOption? category;
  JobStatus status = JobStatus.waiting;
  String? detail;
  String? taskId;
  int progress = 0;
}

class UploadHomePage extends StatefulWidget {
  const UploadHomePage({super.key});

  @override
  State<UploadHomePage> createState() => _UploadHomePageState();
}

class _UploadHomePageState extends State<UploadHomePage> {
  final List<UploadItem> _items = [];
  List<CategoryOption> _categories = [];
  HiveApi? _api;
  LoginSession? _session;
  final ClientConfig _clientConfig = ClientConfig.defaults;
  CategoryOption? _defaultCategory;
  bool _autoUpload = true;
  bool _processing = false;
  final Map<UploadItem, CancellableUpload> _activeUploads = {};
  final VideoPackageService _videoPackageService = const VideoPackageService();
  SessionStore? _sessionStore;
  String _serverUrl = 'http://127.0.0.1:8005/api/v1';
  bool _restoringSession = true;

  bool get _loggedIn => _session != null;

  HiveApi get _requireApi {
    final api = _api;
    if (api == null) {
      throw StateError('登录态异常：API 实例未初始化。');
    }
    return api;
  }

  LoginSession get _requireSession {
    final session = _session;
    if (session == null) {
      throw StateError('登录态异常：会话未初始化。');
    }
    return session;
  }

  @override
  void initState() {
    super.initState();
    try {
      _sessionStore = SessionStore();
      _restoreSession();
    } catch (_) {
      _restoringSession = false;
    }
  }

  Future<void> _restoreSession() async {
    final sessionStore = _sessionStore;
    if (sessionStore == null) {
      if (mounted) setState(() => _restoringSession = false);
      return;
    }
    try {
      final stored = await sessionStore.readSession();
      final autoUpload = await sessionStore.readAutoUpload();
      if (stored == null) {
        if (mounted) {
          setState(() {
            _autoUpload = autoUpload;
            _restoringSession = false;
          });
        }
        return;
      }
      final api = HiveApi(stored.server);
      final profile = await api.profile(stored.token);
      final categories = await api.categoryOptions(stored.token);
      if (!mounted) return;
      setState(() {
        _serverUrl = stored.server;
        _autoUpload = autoUpload;
        _api = api;
        _session = LoginSession(
          id: profile.id,
          username: profile.username,
          displayName: profile.displayName,
          token: stored.token,
          tokenType: 'Bearer',
          expiresAt: '',
        );
        _categories = categories;
        _restoringSession = false;
      });
    } catch (_) {
      try {
        await sessionStore.clearSession();
      } catch (_) {
        // Storage can be unavailable on a first run or a test platform.
      }
      if (mounted) setState(() => _restoringSession = false);
    }
  }

  Future<void> _pickFiles() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withData: false,
    );
    if (result == null) return;
    _addFiles(result.files);
  }

  Future<void> _dropFiles(DropDoneDetails details) async {
    final files = <PlatformFile>[];
    for (final file in details.files) {
      final path = file.path;
      if (path.isEmpty) continue;
      files.add(
        PlatformFile(name: file.name, size: await file.length(), path: path),
      );
    }
    _addFiles(files);
  }

  void _addFiles(List<PlatformFile> files) {
    var rejected = 0;
    var added = 0;
    setState(() {
      for (final file in files) {
        final type = _resourceType(file.name);
        if (_fileRejection(file, type) != null) {
          rejected++;
        } else {
          added++;
          _items.add(
            UploadItem(file: file, type: type)..category = _defaultCategory,
          );
        }
      }
    });
    if (rejected > 0) {
      _showMessage('已忽略 $rejected 个格式不支持、为空或超出大小限制的文件。');
    }
    if (added > 0 &&
        _loggedIn &&
        _autoUpload &&
        _defaultCategory != null &&
        !_processing) {
      unawaited(_processAll());
    }
  }

  String? _fileRejection(PlatformFile file, ResourceType type) {
    if (file.size <= 0) return '文件为空';
    if (type == ResourceType.unsupported) return '不支持的文件格式';
    if (type == ResourceType.video) return null;
    final limit = switch (type) {
      ResourceType.document => _clientConfig.documentUpload,
      ResourceType.image => _clientConfig.imageUpload,
      ResourceType.audio => _clientConfig.audioUpload,
      _ => throw StateError('unknown resource type'),
    };
    final extension = file.name.split('.').last.toLowerCase();
    if (!limit.allowExts.contains(extension)) {
      return '服务端不支持 .$extension';
    }
    if (file.size > limit.maxSizeMB * 1024 * 1024) {
      return '文件超过 ${limit.maxSizeMB}MB 限制';
    }
    return null;
  }

  Future<void> _login(String server, String username, String password) async {
    final api = HiveApi(server);
    final session = await api.login(username: username, password: password);
    final categories = await api.categoryOptions(session.token);
    await _sessionStore?.saveSession(
      server: server.trim(),
      token: session.token,
    );
    if (!mounted) return;
    setState(() {
      _api = api;
      _serverUrl = server.trim();
      _session = session;
      _categories = categories;
      _defaultCategory = null;
    });
  }

  Future<void> _processAll() async {
    if (_processing || _items.isEmpty) return;
    if (!_loggedIn) {
      if (_items.any((item) => item.type != ResourceType.video)) {
        _showMessage('未登录时仅支持视频本地打包；音频、图片和文档需要登录后上传。');
        return;
      }
      setState(() => _processing = true);
      for (final item in _items.where(
        (item) => item.status == JobStatus.waiting,
      )) {
        await _exportVideoPackage(item);
      }
      if (mounted) setState(() => _processing = false);
      return;
    }
    if (_items.any((item) => item.category == null)) {
      _showMessage('请为每项资料选择目标分类。');
      return;
    }
    setState(() => _processing = true);
    for (final item in _items.where(
      (item) => item.status == JobStatus.waiting,
    )) {
      await _uploadItem(item);
    }
    if (mounted) {
      setState(() => _processing = false);
      _showMessage('队列处理完成。');
    }
  }

  Future<void> _uploadItem(UploadItem item) async {
    if (item.type == ResourceType.video) {
      await _uploadVideoPackage(item);
      return;
    }
    await _uploadPlatformFile(item, item.file, _assetKind(item.type));
  }

  Future<void> _uploadVideoPackage(UploadItem item) async {
    final sourcePath = item.file.path;
    if (sourcePath == null) {
      _markFailed(item, '当前平台未返回可处理的视频路径。');
      return;
    }
    final workspace = await Directory.systemTemp.createTemp(
      'hive-cli-video-upload-',
    );
    try {
      final outputPath = '${workspace.path}/video.hivepkg';
      setState(() {
        item.status = JobStatus.packaging;
        item.detail = '正在读取视频信息…';
      });
      final package = await _videoPackageService.create(
        sourcePath: sourcePath,
        outputPath: outputPath,
        title: item.file.name.split('.').first,
        onStage: (stage) {
          if (mounted) setState(() => item.detail = _videoStageLabel(stage));
        },
      );
      if (mounted) {
        setState(() {
          item.detail = '视频包 ${_formatSize(package.sizeBytes)} 已生成，正在开始上传…';
        });
      }
      await _uploadPlatformFile(
        item,
        PlatformFile(
          name: '${item.file.name.split('.').first}.hivepkg',
          size: package.sizeBytes,
          path: package.outputPath,
        ),
        'video_package',
      );
    } on VideoPackageException catch (error) {
      if (mounted) _markFailed(item, error.message);
    } catch (_) {
      if (mounted) {
        _markFailed(item, '视频打包或上传中断；服务端暂不支持断点续传，请恢复网络后重新上传。');
      }
    } finally {
      if (await workspace.exists()) await workspace.delete(recursive: true);
    }
  }

  Future<void> _uploadPlatformFile(
    UploadItem item,
    PlatformFile file,
    String assetKind,
  ) async {
    setState(() {
      item.status = JobStatus.uploading;
      item.progress = 0;
      item.detail = '正在提交至知桥（0%）…';
    });
    final operation = _requireApi.upload(
      file: file,
      assetKind: assetKind,
      category: item.category!,
      token: _requireSession.token,
      onProgress: (progress) {
        if (mounted && item.status == JobStatus.uploading) {
          setState(() {
            item.progress = progress;
            item.detail = '正在提交至知桥（$progress%）…';
          });
        }
      },
    );
    _activeUploads[item] = operation;
    try {
      final result = await operation.result;
      if (!mounted) return;
      setState(() {
        item.status = JobStatus.processing;
        item.progress = 100;
        item.detail = result.duplicate
            ? '重复文件，已复用任务 ${result.taskId}'
            : '已提交资源 ${result.taskId}，等待 Worker 处理…';
      });
      item.taskId = result.taskId;
      unawaited(_pollProcessingTask(item, result.assetId));
    } on http.RequestAbortedException {
      if (mounted) {
        setState(() {
          item.status = JobStatus.cancelled;
          item.detail = '上传已取消';
        });
      }
    } on HiveApiException catch (error) {
      if (mounted) _markFailed(item, error.message);
    } catch (_) {
      if (mounted) _markFailed(item, '网络异常或文件读取失败，请检查网络后重试。');
    } finally {
      _activeUploads.remove(item);
    }
  }

  Future<void> _cancelUpload(UploadItem item) async {
    if (item.status == JobStatus.uploading) {
      _activeUploads[item]?.cancel();
      setState(() => item.detail = '正在取消上传…');
      return;
    }
    if (item.status != JobStatus.processing || item.taskId == null) return;
    setState(() => item.detail = '正在请求取消后台任务…');
    try {
      await _requireApi.cancelTask(item.taskId!, _requireSession.token);
      if (!mounted) return;
      setState(() {
        item.status = JobStatus.cancelled;
        item.detail = '后台任务已取消。';
      });
    } on HiveApiException catch (error) {
      if (mounted) setState(() => item.detail = '取消失败：${error.message}');
    }
  }

  Future<void> _pollProcessingTask(UploadItem item, String assetId) async {
    for (var attempt = 0; attempt < 360; attempt++) {
      await Future<void>.delayed(const Duration(seconds: 5));
      if (!mounted || item.status != JobStatus.processing) return;
      try {
        final task = await _requireApi.taskForAsset(assetId, _requireSession.token);
        if (task == null) continue;
        if (!mounted || item.status != JobStatus.processing) return;
        final progress = task.progressTotal > 0
            ? (task.progressDone * 100 ~/ task.progressTotal).clamp(0, 100)
            : null;
        if (task.status == 'completed' ||
            task.status == 'succeeded' ||
            task.status == 'success') {
          setState(() {
            item.status = JobStatus.completed;
            item.progress = 100;
            item.detail = 'Worker 已完成处理。';
          });
          return;
        }
        if (task.status == 'failed' || task.status == 'canceled') {
          setState(() {
            item.status = task.status == 'canceled'
                ? JobStatus.cancelled
                : JobStatus.failed;
            item.detail = task.errorMessage.isEmpty
                ? 'Worker 处理失败。'
                : task.errorMessage;
          });
          return;
        }
        setState(() {
          item.progress = progress ?? item.progress;
          item.detail = progress == null
              ? 'Worker 状态：${task.status}'
              : 'Worker 状态：${task.status}（$progress%）';
        });
      } on HiveApiException {
        // A transient task-query failure must not make a submitted resource fail.
      }
    }
    if (mounted && item.status == JobStatus.processing) {
      setState(() => item.detail = '资源仍在后台处理，可稍后刷新任务状态。');
    }
  }

  Future<void> _exportVideoPackage(UploadItem item) async {
    final sourcePath = item.file.path;
    if (sourcePath == null) {
      _markFailed(item, '当前平台未返回可处理的视频路径。');
      return;
    }
    final target = await FilePicker.platform.saveFile(
      dialogTitle: '导出知桥视频包',
      fileName: '${item.file.name.split('.').first}.hivepkg',
      type: FileType.custom,
      allowedExtensions: const ['hivepkg'],
    );
    if (target == null) return;
    final outputPath = target.toLowerCase().endsWith('.hivepkg')
        ? target
        : '$target.hivepkg';
    setState(() {
      item.status = JobStatus.packaging;
      item.detail = '正在读取视频信息…';
    });
    try {
      final result = await _videoPackageService.create(
        sourcePath: sourcePath,
        outputPath: outputPath,
        title: item.file.name.split('.').first,
        onStage: (stage) {
          if (!mounted) return;
          setState(() => item.detail = _videoStageLabel(stage));
        },
      );
      if (!mounted) return;
      setState(() {
        item.status = JobStatus.completed;
        item.progress = 100;
        item.detail =
            '已导出 ${result.manifest.frames.length} 帧：${result.outputPath}';
      });
    } on VideoPackageException catch (error) {
      if (mounted) _markFailed(item, error.message);
    } catch (_) {
      if (mounted) _markFailed(item, '视频打包失败，请检查视频文件和可用存储空间。');
    }
  }

  void _markFailed(UploadItem item, String message) => setState(() {
    item.status = JobStatus.failed;
    item.detail = message;
  });

  void _showLogin() {
    final server = TextEditingController(text: _serverUrl);
    final username = TextEditingController();
    final password = TextEditingController();
    var submitting = false;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('登录知桥'),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: server,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(labelText: '服务器地址'),
                ),
                TextField(
                  controller: username,
                  decoration: const InputDecoration(labelText: '用户名'),
                ),
                TextField(
                  controller: password,
                  obscureText: true,
                  onSubmitted: (_) => _submitLogin(
                    dialogContext,
                    setDialogState,
                    server,
                    username,
                    password,
                    () => submitting,
                    (value) => submitting = value,
                  ),
                  decoration: const InputDecoration(labelText: '密码'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: submitting ? null : () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: submitting
                  ? null
                  : () => _submitLogin(
                      dialogContext,
                      setDialogState,
                      server,
                      username,
                      password,
                      () => submitting,
                      (value) => submitting = value,
                    ),
              child: Text(submitting ? '登录中…' : '登录'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _submitLogin(
    BuildContext dialogContext,
    StateSetter setDialogState,
    TextEditingController server,
    TextEditingController username,
    TextEditingController password,
    bool Function() getSubmitting,
    ValueChanged<bool> setSubmitting,
  ) async {
    if (getSubmitting() ||
        username.text.trim().isEmpty ||
        password.text.isEmpty) {
      return;
    }
    setDialogState(() => setSubmitting(true));
    try {
      await _login(server.text, username.text.trim(), password.text);
      if (!mounted || !dialogContext.mounted) return;
      Navigator.pop(dialogContext);
      _showMessage(
        _categories.isEmpty
            ? '已登录，但没有可用分类。'
            : '已登录，已加载 ${_categories.length} 个分类。',
      );
    } on FormatException catch (error) {
      setDialogState(() => setSubmitting(false));
      _showMessage(error.message);
    } on HiveApiException catch (error) {
      setDialogState(() => setSubmitting(false));
      _showMessage(error.message);
    } catch (_) {
      setDialogState(() => setSubmitting(false));
      _showMessage('无法连接服务器，请检查地址和网络。');
    }
  }

  void _showMessage(String message) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(message)));

  Future<void> _logout() async {
    await _sessionStore?.clearSession();
    if (!mounted) return;
    setState(() {
      _session = null;
      _api = null;
      _categories = [];
      _defaultCategory = null;
    });
  }

  void _setAutoUpload(bool value) {
    setState(() => _autoUpload = value);
    _sessionStore?.saveAutoUpload(value);
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final desktop = constraints.maxWidth >= 720;
      final content = _QueueContent(
        items: _items,
        categories: _categories,
        defaultCategory: _defaultCategory,
        processing: _processing,
        loggedIn: _loggedIn,
        autoUpload: _autoUpload,
        onPick: _pickFiles,
        onDrop: _dropFiles,
        onProcess: _processAll,
        onRemove: (item) => setState(() => _items.remove(item)),
        onRetry: _uploadItem,
        onCancel: (item) => unawaited(_cancelUpload(item)),
        onCategoryChanged: (item, value) =>
            setState(() => item.category = value),
        onDefaultChanged: (value) => setState(() {
          _defaultCategory = value;
          for (final item in _items.where((item) => item.category == null)) {
            item.category = value;
          }
        }),
        onAutoUploadChanged: _setAutoUpload,
      );
      if (_restoringSession) {
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }
      return Scaffold(
        appBar: AppBar(
          title: Text(desktop ? '知桥 Hive — 跨平台资料上传客户端' : '知桥 Hive'),
          actions: [
            TextButton.icon(
              onPressed: _loggedIn ? _logout : _showLogin,
              icon: Icon(_loggedIn ? Icons.logout : Icons.person_outline),
              label: Text(_loggedIn ? '退出 ${_requireSession.displayName}' : '登录'),
            ),
            const SizedBox(width: 8),
          ],
        ),
        body: desktop
            ? Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1120),
                  child: content,
                ),
              )
            : content,
      );
    },
  );
}

class _QueueContent extends StatelessWidget {
  const _QueueContent({
    required this.items,
    required this.categories,
    required this.defaultCategory,
    required this.processing,
    required this.loggedIn,
    required this.autoUpload,
    required this.onPick,
    required this.onDrop,
    required this.onProcess,
    required this.onRemove,
    required this.onRetry,
    required this.onCancel,
    required this.onCategoryChanged,
    required this.onDefaultChanged,
    required this.onAutoUploadChanged,
  });
  final List<UploadItem> items;
  final List<CategoryOption> categories;
  final CategoryOption? defaultCategory;
  final bool processing, loggedIn, autoUpload;
  final VoidCallback onPick, onProcess;
  final Future<void> Function(DropDoneDetails details) onDrop;
  final ValueChanged<UploadItem> onRemove, onRetry;
  final ValueChanged<UploadItem> onCancel;
  final void Function(UploadItem, CategoryOption?) onCategoryChanged;
  final ValueChanged<CategoryOption?> onDefaultChanged;
  final ValueChanged<bool> onAutoUploadChanged;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(20),
    child: Column(
      children: [
        _PickArea(onTap: onPick, onDrop: onDrop),
        const SizedBox(height: 16),
        if (loggedIn) ...[
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<CategoryOption>(
                  initialValue: defaultCategory,
                  decoration: const InputDecoration(
                    labelText: '默认目标分类',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('逐项选择分类')),
                    ...categories.map(
                      (item) => DropdownMenuItem(
                        value: item,
                        child: Text(item.label),
                      ),
                    ),
                  ],
                  onChanged: onDefaultChanged,
                ),
              ),
              const SizedBox(width: 12),
              Column(
                children: [
                  const Text('加入队列自动上传'),
                  Switch(value: autoUpload, onChanged: onAutoUploadChanged),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
        ],
        _BatchSummary(items: items),
        const SizedBox(height: 12),
        Expanded(
          child: _ItemList(
            items: items,
            categories: categories,
            loggedIn: loggedIn,
            onRemove: onRemove,
            onRetry: onRetry,
            onCancel: onCancel,
            onCategoryChanged: onCategoryChanged,
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Text('共 ${items.length} 个文件'),
            const Spacer(),
            FilledButton.icon(
              onPressed: items.isEmpty || processing ? null : onProcess,
              icon: Icon(processing ? Icons.hourglass_top : Icons.play_arrow),
              label: Text(
                processing
                    ? '处理中…'
                    : loggedIn
                    ? '全部上传'
                    : '本地打包视频',
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          loggedIn
              ? '已登录：文档、图片、音频和视频包会提交至知桥并同步后台状态。'
              : '未登录：仅支持视频本地导出 .hivepkg。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    ),
  );
}

class _PickArea extends StatelessWidget {
  const _PickArea({required this.onTap, required this.onDrop});
  final VoidCallback onTap;
  final Future<void> Function(DropDoneDetails details) onDrop;
  @override
  Widget build(BuildContext context) => DropTarget(
    onDragDone: (details) => unawaited(onDrop(details)),
    child: Semantics(
      button: true,
      label: '选择或拖放文件',
      hint: '按回车选择文件，也可将文件拖放到这里',
      child: InkWell(
        onTap: onTap,
        onLongPress: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Ink(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 26),
          decoration: BoxDecoration(
            color: Theme.of(
              context,
            ).colorScheme.primaryContainer.withValues(alpha: .35),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: Theme.of(
                context,
              ).colorScheme.primary.withValues(alpha: .35),
            ),
          ),
          child: Column(
            children: [
              Icon(
                Icons.upload_file,
                size: 34,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 8),
              const Text(
                '选择或拖放文件',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              const Text(
                '视频 MP4/MOV/AVI · 音频 MP3/WAV/M4A/FLAC · 图片 PNG/JPG/WEBP · 文档 PDF/DOC/DOCX/TXT/MD',
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _ItemList extends StatelessWidget {
  const _ItemList({
    required this.items,
    required this.categories,
    required this.loggedIn,
    required this.onRemove,
    required this.onRetry,
    required this.onCancel,
    required this.onCategoryChanged,
  });
  final List<UploadItem> items;
  final List<CategoryOption> categories;
  final bool loggedIn;
  final ValueChanged<UploadItem> onRemove, onRetry;
  final ValueChanged<UploadItem> onCancel;
  final void Function(UploadItem, CategoryOption?) onCategoryChanged;
  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const Center(child: Text('点击“选择文件”添加待入库资源'));
    return ListView.separated(
      itemCount: items.length,
      separatorBuilder: (context, index) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final item = items[index];
        return ListTile(
          isThreeLine: item.detail != null,
          leading: CircleAvatar(
            backgroundColor: _typeColor(item.type).withValues(alpha: .15),
            child: Icon(_typeIcon(item.type), color: _typeColor(item.type)),
          ),
          title: Text(
            item.file.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            '${_typeLabel(item.type)} · ${_formatSize(item.file.size)} · ${_statusText(item.status)}${item.detail == null ? '' : '\n${item.detail}'}',
          ),
          trailing: SizedBox(
            width: loggedIn ? 172 : 48,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (loggedIn)
                  Expanded(
                    child: DropdownButton<CategoryOption>(
                      isExpanded: true,
                      hint: const Text('分类'),
                      value: item.category,
                      items: categories
                          .map(
                            (category) => DropdownMenuItem(
                              value: category,
                              child: Text(category.name),
                            ),
                          )
                          .toList(),
                      onChanged: item.status == JobStatus.waiting
                          ? (value) => onCategoryChanged(item, value)
                          : null,
                    ),
                  ),
                if (item.status == JobStatus.uploading ||
                    item.status == JobStatus.processing)
                  IconButton(
                    onPressed: () => onCancel(item),
                    tooltip: item.status == JobStatus.processing
                        ? '取消任务'
                        : '取消上传',
                    icon: const Icon(Icons.cancel_outlined),
                  )
                else if (item.status == JobStatus.failed ||
                    item.status == JobStatus.cancelled)
                  IconButton(
                    onPressed: loggedIn ? () => onRetry(item) : null,
                    tooltip: '重试',
                    icon: const Icon(Icons.refresh),
                  )
                else
                  IconButton(
                    onPressed: item.status == JobStatus.waiting
                        ? () => onRemove(item)
                        : null,
                    tooltip: '移除',
                    icon: const Icon(Icons.close),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _BatchSummary extends StatelessWidget {
  const _BatchSummary({required this.items});
  final List<UploadItem> items;

  int _count(JobStatus status) =>
      items.where((item) => item.status == status).length;

  @override
  Widget build(BuildContext context) {
    final pending =
        _count(JobStatus.waiting) +
        _count(JobStatus.packaging) +
        _count(JobStatus.uploading) +
        _count(JobStatus.processing);
    return Align(
      alignment: Alignment.centerLeft,
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        children: [
          _summaryChip('待处理 $pending', Colors.blueGrey),
          _summaryChip('完成 ${_count(JobStatus.completed)}', Colors.green),
          _summaryChip('失败 ${_count(JobStatus.failed)}', Colors.red),
          _summaryChip('取消 ${_count(JobStatus.cancelled)}', Colors.orange),
        ],
      ),
    );
  }

  Widget _summaryChip(String label, Color color) => Chip(
    avatar: Icon(Icons.circle, size: 10, color: color),
    label: Text(label),
    visualDensity: VisualDensity.compact,
  );
}

ResourceType _resourceType(String name) {
  final extension = name.split('.').last.toLowerCase();
  if (['mp4', 'mov', 'avi'].contains(extension)) return ResourceType.video;
  if (['mp3', 'wav', 'm4a', 'flac'].contains(extension)) {
    return ResourceType.audio;
  }
  if (['png', 'jpg', 'jpeg', 'webp'].contains(extension)) {
    return ResourceType.image;
  }
  if (['pdf', 'doc', 'docx', 'txt', 'md'].contains(extension)) {
    return ResourceType.document;
  }
  return ResourceType.unsupported;
}

String _assetKind(ResourceType type) => switch (type) {
  ResourceType.audio => 'audio',
  ResourceType.image => 'image',
  ResourceType.document => 'document',
  _ => throw ArgumentError('视频和不支持的文件不能直接上传'),
};
String _typeLabel(ResourceType type) => switch (type) {
  ResourceType.video => '视频',
  ResourceType.audio => '音频',
  ResourceType.image => '图片',
  ResourceType.document => '文档',
  ResourceType.unsupported => '不支持',
};
IconData _typeIcon(ResourceType type) => switch (type) {
  ResourceType.video => Icons.video_file,
  ResourceType.audio => Icons.audio_file,
  ResourceType.image => Icons.image,
  ResourceType.document => Icons.description,
  ResourceType.unsupported => Icons.help_outline,
};
Color _typeColor(ResourceType type) => switch (type) {
  ResourceType.video => Colors.purple,
  ResourceType.audio => Colors.orange,
  ResourceType.image => Colors.blue,
  ResourceType.document => Colors.teal,
  ResourceType.unsupported => Colors.grey,
};
String _statusText(JobStatus status) => switch (status) {
  JobStatus.waiting => '待处理',
  JobStatus.packaging => '正在打包',
  JobStatus.uploading => '正在上传',
  JobStatus.processing => '后台处理中',
  JobStatus.completed => '已提交',
  JobStatus.failed => '失败',
  JobStatus.cancelled => '已取消',
};
String _videoStageLabel(VideoPackageStage stage) => switch (stage) {
  VideoPackageStage.extractingAudio => '正在提取音频…',
  VideoPackageStage.extractingFrames => '正在按 30 秒间隔抽帧…',
  VideoPackageStage.packaging => '正在生成 .hivepkg…',
  VideoPackageStage.completed => '视频包已生成。',
};
String _formatSize(int bytes) => bytes < 1024 * 1024
    ? '${(bytes / 1024).toStringAsFixed(1)} KB'
    : '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
