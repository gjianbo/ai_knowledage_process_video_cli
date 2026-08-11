import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Non-interactive uploader for automation and CI.
/// Password/token are read from HIVE_PASSWORD/HIVE_TOKEN by default.
Future<void> main(List<String> arguments) async {
  if (arguments.isEmpty ||
      !{'upload', 'batch', 'wait', 'config'}.contains(arguments.first)) {
    _usage();
    exitCode = 64;
    return;
  }
  try {
    final options = _parse(arguments.skip(1));
    if (arguments.first == 'config') {
      await _runConfig(options);
      return;
    }
    final config = await _readConfig();
    final server = (options['server'] ?? config['server'] ?? '').replaceFirst(
      RegExp(r'/+$'),
      '',
    );
    if (server.isEmpty) {
      throw const _CliException('缺少 --server 参数，请先执行 config set。');
    }
    if (!options.containsKey('username') && config['username'] != null) {
      options['username'] = config['username']!;
    }
    final token = await _tokenFor(server, options);
    if (arguments.first == 'wait') {
      final result = await _waitForAsset(
        server: server,
        token: token,
        assetId: _required(options, 'asset'),
        interval: _interval(options),
      );
      stdout.writeln(jsonEncode(result));
      if (result['status'] == 'failed' || result['status'] == 'canceled') {
        exitCode = 1;
      }
      return;
    }
    if (arguments.first == 'upload') {
      final result = await _upload(
        server: server,
        token: token,
        path: _required(options, '_file'),
        category: _required(options, 'category'),
        type: options['type'],
      );
      if (options['wait'] == '1') {
        result['task'] = await _waitForAsset(
          server: server,
          token: token,
          assetId: result['assetId'].toString(),
          interval: _interval(options),
        );
      }
      stdout.writeln(jsonEncode(result));
      final task = result['task'] as Map<String, dynamic>?;
      if (task?['status'] == 'failed' || task?['status'] == 'canceled') {
        exitCode = 1;
      }
      return;
    }
    final rows = await _readBatch(_required(options, '_file'));
    var succeeded = 0;
    final failures = <Map<String, String>>[];
    for (final row in rows) {
      try {
        final result = await _upload(
          server: server,
          token: token,
          path: _required(row, 'file'),
          category: row['category'] ?? _required(options, 'category'),
          type: row['type'],
        );
        if (options['wait'] == '1') {
          result['task'] = await _waitForAsset(
            server: server,
            token: token,
            assetId: result['assetId'].toString(),
            interval: _interval(options),
          );
        }
        succeeded++;
        stdout.writeln(jsonEncode({'status': 'submitted', ...result}));
      } on _CliException catch (error) {
        failures.add({'file': row['file'] ?? '', 'error': error.message});
        stderr.writeln('${row['file'] ?? '(unknown)'}：${error.message}');
      }
    }
    stdout.writeln(
      jsonEncode({
        'total': rows.length,
        'submitted': succeeded,
        'failed': failures.length,
        'failures': failures,
      }),
    );
    if (failures.isNotEmpty) exitCode = 1;
  } on _CliException catch (error) {
    stderr.writeln(error.message);
    _usage();
    exitCode = 64;
  } on SocketException catch (_) {
    stderr.writeln('无法连接服务端。');
    exitCode = 69;
  }
}

Future<void> _runConfig(Map<String, String> options) async {
  final action = options['_file'];
  if (action == 'show') {
    stdout.writeln(jsonEncode(await _readConfig()));
    return;
  }
  if (action != 'set') {
    throw const _CliException('config 仅支持 set 或 show。');
  }
  final server = options['server'];
  final username = options['username'];
  if (server == null && username == null) {
    throw const _CliException('config set 至少需要 --server 或 --username。');
  }
  final config = await _readConfig();
  if (server != null) {
    config['server'] = server.replaceFirst(RegExp(r'/+$'), '');
  }
  if (username != null) {
    config['username'] = username;
  }
  await _configFile().parent.create(recursive: true);
  await _configFile().writeAsString('${jsonEncode(config)}\n');
  stdout.writeln(jsonEncode(config));
}

File _configFile() {
  final home = Platform.environment['HOME'];
  if (home == null || home.isEmpty) {
    throw const _CliException('无法确定用户目录，无法保存 CLI 配置。');
  }
  return File('$home/.config/hive-cli/config.json');
}

Future<Map<String, String>> _readConfig() async {
  final file = _configFile();
  if (!await file.exists()) return <String, String>{};
  try {
    final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    return data.map((key, value) => MapEntry(key, value.toString()));
  } on FormatException {
    throw const _CliException('CLI 配置文件不是有效 JSON。');
  }
}

Future<String> _tokenFor(String server, Map<String, String> options) async {
  final token = options['token'] ?? Platform.environment['HIVE_TOKEN'];
  if (token != null && token.isNotEmpty) return token;
  final username = _required(options, 'username');
  final password = Platform.environment['HIVE_PASSWORD'];
  if (password == null || password.isEmpty) {
    throw const _CliException('请设置 HIVE_PASSWORD，或通过 HIVE_TOKEN 提供短期令牌。');
  }
  final response = await http
      .post(
        Uri.parse('$server/auth/login'),
        headers: {'Content-Type': 'application/json; charset=utf-8'},
        body: jsonEncode({'username': username, 'password': password}),
      )
      .timeout(const Duration(seconds: 30));
  final data =
      _unwrap(response.statusCode, response.body) as Map<String, dynamic>;
  final accessToken = data['accessToken']?.toString();
  if (accessToken == null || accessToken.isEmpty) {
    throw const _CliException('登录响应缺少 accessToken。');
  }
  return accessToken;
}

Future<Map<String, dynamic>> _waitForAsset({
  required String server,
  required String token,
  required String assetId,
  required Duration interval,
}) async {
  for (var attempt = 0; attempt < 360; attempt++) {
    final uri = Uri.parse(
      '$server/tasks',
    ).replace(queryParameters: {'targetId': assetId, 'pageSize': '1'});
    final response = await http
        .get(uri, headers: {'Authorization': 'Bearer $token'})
        .timeout(const Duration(seconds: 30));
    final page =
        _unwrap(response.statusCode, response.body) as Map<String, dynamic>;
    final rows = page['data'] as List<dynamic>? ?? const [];
    if (rows.isNotEmpty) {
      final task = Map<String, dynamic>.from(rows.first as Map);
      final status = task['status']?.toString() ?? 'pending';
      if ({'completed', 'succeeded', 'failed', 'canceled'}.contains(status)) {
        return task;
      }
    }
    await Future<void>.delayed(interval);
  }
  throw const _CliException('等待 Worker 超时（30 分钟）。');
}

Duration _interval(Map<String, String> options) {
  final seconds = int.tryParse(options['interval'] ?? '5');
  if (seconds == null || seconds < 1 || seconds > 60) {
    throw const _CliException('--interval 必须是 1 到 60 秒。');
  }
  return Duration(seconds: seconds);
}

Future<Map<String, dynamic>> _upload({
  required String server,
  required String token,
  required String path,
  required String category,
  String? type,
}) async {
  final file = File(path);
  if (!await file.exists() || await file.length() == 0) {
    throw _CliException('文件不存在或为空：$path');
  }
  final request =
      http.MultipartRequest('POST', Uri.parse('$server/assets/upload'))
        ..headers['Authorization'] = 'Bearer $token'
        ..fields['categoryId'] = category
        ..fields['assetType'] = type ?? _inferType(path)
        ..files.add(await http.MultipartFile.fromPath('file', file.path));
  final response = await request.send().timeout(const Duration(minutes: 5));
  final data =
      _unwrap(response.statusCode, await response.stream.bytesToString())
          as Map<String, dynamic>;
  return {
    'file': path,
    'assetId': data['id'],
    'taskId': data['taskId'] ?? data['id'],
    'taskType': data['taskType'],
  };
}

Future<List<Map<String, String>>> _readBatch(String path) async {
  final file = File(path);
  if (!await file.exists()) {
    throw _CliException('批量清单不存在：$path');
  }
  final lines = (await file.readAsLines())
      .where((line) => line.trim().isNotEmpty)
      .toList();
  if (lines.length < 2) {
    throw const _CliException('批量 CSV 至少需要表头和一行数据。');
  }
  final headers = _splitCsv(lines.first);
  if (!headers.contains('file')) {
    throw const _CliException('批量 CSV 必须含有 file 列。');
  }
  return lines.skip(1).map((line) {
    final values = _splitCsv(line);
    if (values.length != headers.length) {
      throw _CliException('CSV 列数不匹配：$line');
    }
    return Map<String, String>.fromIterables(headers, values);
  }).toList();
}

List<String> _splitCsv(String line) {
  final values = <String>[];
  final buffer = StringBuffer();
  var quoted = false;
  for (var index = 0; index < line.length; index++) {
    final char = line[index];
    if (char == '"') {
      if (quoted && index + 1 < line.length && line[index + 1] == '"') {
        buffer.write(char);
        index++;
      } else {
        quoted = !quoted;
      }
    } else if (char == ',' && !quoted) {
      values.add(buffer.toString().trim());
      buffer.clear();
    } else {
      buffer.write(char);
    }
  }
  if (quoted) throw _CliException('CSV 引号未闭合：$line');
  values.add(buffer.toString().trim());
  return values;
}

dynamic _unwrap(int status, String body) {
  try {
    final payload = jsonDecode(body) as Map<String, dynamic>;
    if (status < 200 ||
        status >= 300 ||
        (payload['code'] is num && payload['code'] != 0)) {
      throw _CliException(
        (payload['message'] ?? payload['msg'] ?? '请求失败（HTTP $status）')
            .toString(),
      );
    }
    if (!payload.containsKey('data')) throw const _CliException('服务响应缺少 data。');
    return payload['data'];
  } on FormatException {
    throw _CliException('服务返回了无法解析的响应（HTTP $status）。');
  }
}

Map<String, String> _parse(Iterable<String> values) {
  final result = <String, String>{};
  final args = values.iterator;
  while (args.moveNext()) {
    final value = args.current;
    if (value.startsWith('--')) {
      if (!args.moveNext()) throw const _CliException('参数缺少值。');
      result[value.substring(2)] = args.current;
    } else if (!result.containsKey('_file')) {
      result['_file'] = value;
    } else {
      throw _CliException('只支持一个文件或 CSV 清单。');
    }
  }
  return result;
}

String _required(Map<String, String> values, String key) {
  final value = values[key];
  if (value == null || value.isEmpty) throw _CliException('缺少 --$key 参数。');
  return value;
}

String _inferType(String path) {
  final extension = path.split('.').last.toLowerCase();
  if (extension == 'hivepkg') return 'video_package';
  if (const {'png', 'jpg', 'jpeg', 'webp'}.contains(extension)) return 'image';
  if (const {'mp3', 'wav', 'm4a', 'flac'}.contains(extension)) return 'audio';
  return 'document';
}

void _usage() => stdout.writeln(
  '''用法：
  HIVE_PASSWORD=*** dart run bin/hive_cli.dart upload --server <api-v1-url> --username <name> --category <uuid> [--type <type>] [--wait 1] [--interval 5] <file>
  HIVE_TOKEN=*** dart run bin/hive_cli.dart batch --server <api-v1-url> [--category <default-uuid>] [--wait 1] [--interval 5] tasks.csv
  HIVE_TOKEN=*** dart run bin/hive_cli.dart wait --server <api-v1-url> --asset <asset-id> [--interval 5]
  dart run bin/hive_cli.dart config set --server <api-v1-url> [--username <name>]
  dart run bin/hive_cli.dart config show

batch CSV 表头：file,category,type；category 和 type 可省略，category 省略时必须传 --category。''',
);

class _CliException implements Exception {
  const _CliException(this.message);
  final String message;
}
