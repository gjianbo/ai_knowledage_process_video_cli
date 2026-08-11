import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;

import '../models/api_models.dart';

class HiveApi {
  HiveApi(String server) : _baseUri = Uri.parse(_normalizeServer(server));

  final Uri _baseUri;

  static String _normalizeServer(String value) {
    final normalized = value.trim().replaceFirst(RegExp(r'/+$'), '');
    if (normalized.isEmpty || !normalized.startsWith(RegExp(r'https?://'))) {
      throw const FormatException('服务器地址必须以 http:// 或 https:// 开头');
    }
    return normalized;
  }

  Future<LoginSession> login({
    required String username,
    required String password,
  }) async {
    final data = await _jsonRequest(
      'POST',
      '/auth/login',
      body: {'username': username, 'password': password},
    );
    return LoginSession.fromApiJson(data as Map<String, dynamic>);
  }

  Future<List<CategoryOption>> categoryOptions(String token) async {
    final data = await _jsonRequest('GET', '/categories', token: token);
    final list = (data as List<dynamic>? ?? const [])
        .cast<Map<String, dynamic>>();
    return list.map(CategoryOption.fromJson).toList();
  }

  Future<AuthProfile> profile(String token) async {
    final data = await _jsonRequest('GET', '/auth/profile', token: token);
    return AuthProfile.fromJson(data as Map<String, dynamic>);
  }

  Future<ProcessingTask?> taskForAsset(String assetId, String token) async {
    final data =
        await _jsonRequest(
              'GET',
              '/tasks',
              token: token,
              queryParameters: {'targetId': assetId, 'pageSize': '1'},
            )
            as Map<String, dynamic>;
    final tasks = (data['data'] as List<dynamic>? ?? const [])
        .cast<Map<String, dynamic>>();
    return tasks.isEmpty ? null : ProcessingTask.fromJson(tasks.first);
  }

  Future<void> cancelTask(String taskId, String token) async {
    await _jsonRequest('POST', '/tasks/$taskId/cancel', token: token);
  }

  CancellableUpload upload({
    required PlatformFile file,
    required String assetKind,
    required CategoryOption category,
    required String token,
    required ProgressCallback onProgress,
  }) {
    final abort = Completer<void>();
    return CancellableUpload(
      _sendUpload(
        file: file,
        assetKind: assetKind,
        category: category,
        token: token,
        abortTrigger: abort.future,
        onProgress: onProgress,
      ),
      () {
        if (!abort.isCompleted) abort.complete();
      },
    );
  }

  Future<UploadResult> _sendUpload({
    required PlatformFile file,
    required String assetKind,
    required CategoryOption category,
    required String token,
    required Future<void> abortTrigger,
    required ProgressCallback onProgress,
  }) async {
    final endpoint = switch (assetKind) {
      'document' || 'image' || 'audio' || 'video_package' => '/assets/upload',
      _ => throw ArgumentError.value(assetKind, 'assetKind', '不支持的资源类型'),
    };
    final request = _ProgressMultipartRequest(
      'POST',
      _uri(endpoint),
      abortTrigger: abortTrigger,
      onProgress: onProgress,
    );
    request.headers['Authorization'] = 'Bearer $token';
    request.fields['categoryId'] = category.id;
    request.fields['assetType'] = assetKind;
    if (file.bytes != null) {
      request.files.add(
        http.MultipartFile.fromBytes('file', file.bytes!, filename: file.name),
      );
    } else if (file.path != null) {
      request.files.add(
        await http.MultipartFile.fromPath(
          'file',
          file.path!,
          filename: file.name,
        ),
      );
    } else {
      throw StateError('无法读取文件 ${file.name}');
    }
    final response = await request.send().timeout(const Duration(minutes: 5));
    final text = await response.stream.bytesToString();
    final data = _unwrap(response.statusCode, text);
    return UploadResult.fromJson(data as Map<String, dynamic>);
  }

  Future<dynamic> _jsonRequest(
    String method,
    String path, {
    Map<String, dynamic>? body,
    String? token,
    Map<String, String>? queryParameters,
  }) async {
    final request = http.Request(
      method,
      _uri(path, queryParameters: queryParameters),
    );
    request.headers['Accept'] = 'application/json';
    if (token != null) request.headers['Authorization'] = 'Bearer $token';
    if (body != null) {
      request.headers['Content-Type'] = 'application/json; charset=utf-8';
      request.body = jsonEncode(body);
    }
    final response = await request.send().timeout(const Duration(seconds: 30));
    return _unwrap(response.statusCode, await response.stream.bytesToString());
  }

  Uri _uri(String path, {Map<String, String>? queryParameters}) => _baseUri
      .replace(path: '${_baseUri.path}$path', queryParameters: queryParameters);

  dynamic _unwrap(int statusCode, String text) {
    Map<String, dynamic> payload;
    try {
      payload = jsonDecode(text) as Map<String, dynamic>;
    } on FormatException {
      throw HiveApiException('服务返回了无法解析的响应（HTTP $statusCode）');
    }
    final error = payload['message'] ?? payload['msg'];
    if (statusCode < 200 ||
        statusCode >= 300 ||
        (payload['code'] is num && payload['code'] != 0)) {
      throw HiveApiException((error as String?) ?? '请求失败（HTTP $statusCode）');
    }
    if (!payload.containsKey('data')) {
      throw const HiveApiException('服务响应缺少 data。');
    }
    return payload['data'];
  }
}

class CancellableUpload {
  const CancellableUpload(this.result, this.cancel);
  final Future<UploadResult> result;
  final void Function() cancel;
}

typedef ProgressCallback = void Function(int value);

class _ProgressMultipartRequest extends http.MultipartRequest
    with http.Abortable {
  _ProgressMultipartRequest(
    super.method,
    super.url, {
    required this.abortTrigger,
    required this.onProgress,
  });

  @override
  final Future<void>? abortTrigger;
  final ProgressCallback onProgress;

  @override
  http.ByteStream finalize() {
    final totalBytes = contentLength;
    var sentBytes = 0;
    final stream = super.finalize().transform(
      StreamTransformer<List<int>, List<int>>.fromHandlers(
        handleData: (data, sink) {
          sentBytes += data.length;
          onProgress((sentBytes * 100 / totalBytes).clamp(0, 100).round());
          sink.add(data);
        },
      ),
    );
    // Keep the body stream single-subscription. The client consumes it directly.
    return http.ByteStream(stream);
  }
}

class HiveApiException implements Exception {
  const HiveApiException(this.message);
  final String message;
  @override
  String toString() => message;
}
