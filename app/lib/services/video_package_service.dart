import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:archive/archive_io.dart';
import 'package:ffmpeg_kit_flutter_new_full/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_full/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new_full/return_code.dart';
import 'package:path/path.dart' as path;

class VideoPackageService {
  const VideoPackageService();

  Future<VideoPackageResult> create({
    required String sourcePath,
    required String outputPath,
    required String title,
    int frameIntervalSeconds = 30,
    void Function(VideoPackageStage stage)? onStage,
  }) async {
    if (frameIntervalSeconds <= 0) {
      throw ArgumentError.value(frameIntervalSeconds, 'frameIntervalSeconds');
    }
    final source = File(sourcePath);
    if (!await source.exists()) {
      throw const VideoPackageException('找不到所选的视频文件。');
    }
    if (!outputPath.toLowerCase().endsWith('.hivepkg')) {
      throw const VideoPackageException('导出文件必须以 .hivepkg 结尾。');
    }
    final probe = await FFprobeKit.getMediaInformation(source.path);
    final information = probe.getMediaInformation();
    if (information == null) {
      throw const VideoPackageException('无法读取视频媒体信息。');
    }
    final video = information
        .getStreams()
        .where((stream) => stream.getType() == 'video')
        .firstOrNull;
    if (video == null) {
      throw const VideoPackageException('所选文件不包含视频轨道。');
    }
    final duration = double.tryParse(information.getDuration() ?? '');
    if (duration == null || duration <= 0) {
      throw const VideoPackageException('无法确定视频时长。');
    }
    final workspace = await Directory.systemTemp.createTemp('hive-cli-video-');
    try {
      final framesDir = Directory(path.join(workspace.path, 'frames'));
      final audioDir = Directory(path.join(workspace.path, 'audio'));
      await framesDir.create(recursive: true);
      await audioDir.create(recursive: true);
      final audioPath = path.join(audioDir.path, 'audio.m4a');
      onStage?.call(VideoPackageStage.extractingAudio);
      await _execute(
        '-y -i ${_quote(source.path)} -map 0:a:0 -vn -c:a aac -b:a 128k ${_quote(audioPath)}',
      );
      onStage?.call(VideoPackageStage.extractingFrames);
      await _execute(
        '-y -i ${_quote(source.path)} -vf fps=1/$frameIntervalSeconds -q:v 2 ${_quote(path.join(framesDir.path, 'raw_%06d.jpg'))}',
      );
      final frames = await _renameFrames(
        framesDir,
        duration: duration,
        interval: frameIntervalSeconds,
        width: video.getWidth() ?? 0,
        height: video.getHeight() ?? 0,
      );
      final manifest = VideoPackageManifest(
        title: title.trim().isEmpty
            ? path.basenameWithoutExtension(source.path)
            : title.trim(),
        durationSeconds: duration.round(),
        width: video.getWidth() ?? 0,
        height: video.getHeight() ?? 0,
        fps: _parseFrameRate(video.getAverageFrameRate()),
        codec: video.getCodec() ?? '',
        audioCodec: 'aac',
        frames: frames,
      );
      await File(path.join(workspace.path, 'manifest.json')).writeAsString(
        const JsonEncoder.withIndent('  ').convert(manifest.toJson()),
        flush: true,
      );
      onStage?.call(VideoPackageStage.packaging);
      await Directory(path.dirname(outputPath)).create(recursive: true);
      await ZipFileEncoder().zipDirectory(workspace, filename: outputPath);
      onStage?.call(VideoPackageStage.completed);
      return VideoPackageResult(
        outputPath: outputPath,
        manifest: manifest,
        sizeBytes: await File(outputPath).length(),
      );
    } finally {
      if (await workspace.exists()) await workspace.delete(recursive: true);
    }
  }

  Future<List<VideoFrame>> _renameFrames(
    Directory directory, {
    required double duration,
    required int interval,
    required int width,
    required int height,
  }) async {
    final files =
        (await directory
              .list()
              .where(
                (entity) =>
                    entity is File &&
                    path.extension(entity.path).toLowerCase() == '.jpg',
              )
              .cast<File>()
              .toList())
          ..sort((a, b) => a.path.compareTo(b.path));
    final frames = <VideoFrame>[];
    for (var index = 0; index < files.length; index++) {
      final offset = min(index * interval, duration.floor());
      final target = File(
        path.join(directory.path, 'f_${offset.toString().padLeft(6, '0')}.jpg'),
      );
      await files[index].rename(target.path);
      frames.add(
        VideoFrame(
          file: 'frames/${path.basename(target.path)}',
          offsetSeconds: offset,
          width: width,
          height: height,
        ),
      );
    }
    return frames;
  }

  Future<void> _execute(String command) async {
    final session = await FFmpegKit.execute(command);
    if (ReturnCode.isSuccess(await session.getReturnCode())) return;
    final logs = (await session.getAllLogsAsString() ?? '').trim();
    throw VideoPackageException(
      logs.isEmpty ? 'ffmpeg 处理失败。' : 'ffmpeg 处理失败：$logs',
    );
  }

  double _parseFrameRate(String? value) {
    if (value == null || value.isEmpty) return 0;
    final parts = value.split('/');
    if (parts.length == 2) {
      final numerator = double.tryParse(parts[0]);
      final denominator = double.tryParse(parts[1]);
      if (numerator != null && denominator != null && denominator != 0) {
        return numerator / denominator;
      }
    }
    return double.tryParse(value) ?? 0;
  }

  String _quote(String value) => "'${value.replaceAll("'", r"'\\''")}'";
}

enum VideoPackageStage {
  extractingAudio,
  extractingFrames,
  packaging,
  completed,
}

class VideoPackageResult {
  const VideoPackageResult({
    required this.outputPath,
    required this.manifest,
    required this.sizeBytes,
  });
  final String outputPath;
  final VideoPackageManifest manifest;
  final int sizeBytes;
}

class VideoPackageManifest {
  const VideoPackageManifest({
    required this.title,
    required this.durationSeconds,
    required this.width,
    required this.height,
    required this.fps,
    required this.codec,
    required this.audioCodec,
    required this.frames,
  });
  final String title;
  final int durationSeconds, width, height;
  final double fps;
  final String codec, audioCodec;
  final List<VideoFrame> frames;

  Map<String, Object> toJson() => {
    'version': 1,
    'video': {
      'title': title,
      'duration_seconds': durationSeconds,
      'width': width,
      'height': height,
      'fps': fps,
      'codec': codec,
    },
    'audio': {
      'file': 'audio/audio.m4a',
      'codec': audioCodec,
      'duration_seconds': durationSeconds,
    },
    'frames': frames.map((frame) => frame.toJson()).toList(),
  };
}

class VideoFrame {
  const VideoFrame({
    required this.file,
    required this.offsetSeconds,
    required this.width,
    required this.height,
  });
  final String file;
  final int offsetSeconds, width, height;
  Map<String, Object> toJson() => {
    'file': file,
    'offset_seconds': offsetSeconds,
    'width': width,
    'height': height,
  };
}

class VideoPackageException implements Exception {
  const VideoPackageException(this.message);
  final String message;
  @override
  String toString() => message;
}
