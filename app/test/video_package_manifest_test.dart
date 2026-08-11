import 'package:app/services/video_package_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'creates the video package manifest required by the server pipeline',
    () {
      const manifest = VideoPackageManifest(
        title: '周例会',
        durationSeconds: 65,
        width: 1920,
        height: 1080,
        fps: 30,
        codec: 'h264',
        audioCodec: 'aac',
        frames: [
          VideoFrame(
            file: 'frames/f_000030.jpg',
            offsetSeconds: 30,
            width: 1920,
            height: 1080,
          ),
        ],
      );

      expect(manifest.toJson(), {
        'version': 1,
        'video': {
          'title': '周例会',
          'duration_seconds': 65,
          'width': 1920,
          'height': 1080,
          'fps': 30.0,
          'codec': 'h264',
        },
        'audio': {
          'file': 'audio/audio.m4a',
          'codec': 'aac',
          'duration_seconds': 65,
        },
        'frames': [
          {
            'file': 'frames/f_000030.jpg',
            'offset_seconds': 30,
            'width': 1920,
            'height': 1080,
          },
        ],
      });
    },
  );
}
