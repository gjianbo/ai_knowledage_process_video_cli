import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:app/services/hive_api.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final username = Platform.environment['HIVE_TEST_USERNAME'];
  final password = Platform.environment['HIVE_TEST_PASSWORD'];
  final baseUrl =
      Platform.environment['HIVE_TEST_BASE_URL'] ??
      'http://127.0.0.1:8005/api/v1';
  final canRun = username != null && password != null;
  final runWriteTests = Platform.environment['HIVE_RUN_WRITE_TESTS'] == '1';

  test(
    'v1 backend login, profile and categories',
    () async {
      final api = HiveApi(baseUrl);
      final session = await api.login(username: username!, password: password!);
      expect(session.token, isNotEmpty);
      expect(session.username, username);

      final profile = await api.profile(session.token);
      expect(profile.id, isNotEmpty);
      expect(profile.username, username);

      final categories = await api.categoryOptions(session.token);
      expect(categories, isA<List>());
    },
    skip: canRun
        ? false
        : 'Set HIVE_TEST_USERNAME and HIVE_TEST_PASSWORD to run against a local backend.',
  );

  test(
    'v1 backend accepts a document upload',
    () async {
      final api = HiveApi(baseUrl);
      final session = await api.login(username: username!, password: password!);
      final categories = await api.categoryOptions(session.token);
      expect(categories, isNotEmpty, reason: '上传验收需要至少一个可用分类。');

      final directory = await Directory.systemTemp.createTemp(
        'hive-cli-upload-test-',
      );
      final file = File('${directory.path}/hive-cli-integration-test.md');
      await file.writeAsString(
        '# hive-cli integration test\n\nCreated for v1 upload verification.\n',
      );
      try {
        final result = await api
            .upload(
              file: PlatformFile(
                name: 'hive-cli-integration-test.md',
                size: await file.length(),
                path: file.path,
              ),
              assetKind: 'document',
              category: categories.first,
              token: session.token,
              onProgress: (_) {},
            )
            .result;
        expect(result.taskId, isNotEmpty);
        expect(
          await api.taskForAsset(result.assetId, session.token),
          isNotNull,
        );
      } finally {
        await directory.delete(recursive: true);
      }
    },
    skip: canRun && runWriteTests
        ? false
        : 'Set HIVE_RUN_WRITE_TESTS=1 with test credentials to create a v1 upload test asset.',
  );

  test(
    'v1 backend accepts a valid video package upload',
    () async {
      final api = HiveApi(baseUrl);
      final session = await api.login(username: username!, password: password!);
      final categories = await api.categoryOptions(session.token);
      expect(categories, isNotEmpty, reason: '上传验收需要至少一个可用分类。');

      final directory = await Directory.systemTemp.createTemp(
        'hive-cli-package-test-',
      );
      final file = File('${directory.path}/hive-cli-integration-test.hivepkg');
      final manifest = jsonEncode({
        'version': 1,
        'video': {'title': 'integration test', 'duration_seconds': 1},
        'audio': {'file': 'audio/audio.m4a', 'duration_seconds': 1},
        'frames': [
          {'file': 'frames/f_000000.jpg', 'offset_seconds': 0},
        ],
      });
      final archive = Archive()
        ..addFile(
          ArchiveFile('manifest.json', manifest.length, utf8.encode(manifest)),
        )
        ..addFile(
          ArchiveFile('audio/audio.m4a', 12, [
            0,
            0,
            0,
            0,
            0x66,
            0x74,
            0x79,
            0x70,
            0,
            0,
            0,
            0,
          ]),
        )
        ..addFile(ArchiveFile('frames/f_000000.jpg', 3, [0xff, 0xd8, 0xff]));
      await file.writeAsBytes(ZipEncoder().encodeBytes(archive));
      try {
        final result = await api
            .upload(
              file: PlatformFile(
                name: 'hive-cli-integration-test.hivepkg',
                size: await file.length(),
                path: file.path,
              ),
              assetKind: 'video_package',
              category: categories.first,
              token: session.token,
              onProgress: (_) {},
            )
            .result;
        expect(result.taskId, isNotEmpty);
        expect(
          await api.taskForAsset(result.assetId, session.token),
          isNotNull,
        );
      } finally {
        await directory.delete(recursive: true);
      }
    },
    skip: canRun && runWriteTests
        ? false
        : 'Set HIVE_RUN_WRITE_TESTS=1 with test credentials to create a v1 video package test asset.',
  );
}
