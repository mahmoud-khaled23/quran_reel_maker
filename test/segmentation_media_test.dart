import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:quran_reel_maker/features/video_trimmer/segmentation_service.dart';
import 'package:quran_reel_maker/media_engine/media_engine.dart';

// Fixtures are generated here from mathematical grayscale frames and tones;
// no third-party recording or redistribution permission is required.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('real fractional cuts retain every frame in order with synchronized tones', () async {
    final root = await Directory.systemTemp.createTemp('qrm_segments_');
    final engine = createMediaEngine();
    final service = SegmentationService(engine);
    try {
      final source = File('${root.path}/lecture_recording.mp4');
      await engine.run([
        '-y',
        '-v',
        'error',
        '-filter_threads',
        '1',
        '-f',
        'lavfi',
        '-i',
        'nullsrc=s=64x48:r=10:d=3.7,geq=lum=20+N*5:cb=128:cr=128',
        '-f',
        'lavfi',
        '-i',
        'aevalsrc=0.2*sin(2*PI*(300*t+100*t*t)):s=48000:d=3.7',
        '-c:v',
        await engine.encoder(),
        '-g',
        '300',
        '-bf',
        '0',
        '-pix_fmt',
        'yuv420p',
        '-c:a',
        'aac',
        '-threads',
        '1',
        source.path,
      ]);
      final inspected = await service.inspect(source);
      expect(inspected.info.duration, closeTo(3.7, 0.03));
      final progress = <double>[];
      final result = await service.split(
        inspected,
        1.25,
        root,
        token: CancellationToken(),
        progress: (v, _) => progress.add(v),
      );
      expect(result.copiedVideo, false);
      expect(result.files, hasLength(3));
      expect(progress.last, 1);
      Future<List<double>> frames(File file) async {
        final raw = File('${root.path}/decoded.gray');
        await engine.run([
          '-y',
          '-v',
          'error',
          '-i',
          file.path,
          '-map',
          '0:V:0',
          '-vf',
          'format=gray',
          '-fps_mode',
          'passthrough',
          '-f',
          'rawvideo',
          '-threads',
          '1',
          raw.path,
        ]);
        final bytes = await raw.readAsBytes();
        expect(bytes.length % (64 * 48), 0);
        return [
          for (var i = 0; i < bytes.length; i += 64 * 48)
            bytes.sublist(i, i + 64 * 48).fold<int>(0, (a, b) => a + b) /
                (64 * 48),
        ];
      }

      final original = await frames(source);
      final joined = <double>[];
      final counts = <int>[];
      for (var i = 0; i < result.files.length; i++) {
        final file = result.files[i];
        final decoded = await frames(file);
        counts.add(decoded.length);
        joined.addAll(decoded);
        final info = await engine.inspect(file.path);
        expect(info.width, 64);
        expect(info.height, 48);
        expect(info.hasAudio, true);
        final pcm = File('${root.path}/sound.pcm');
        await engine.run([
          '-y',
          '-v',
          'error',
          '-ss',
          '0.2',
          '-i',
          file.path,
          '-t',
          '0.2',
          '-ac',
          '1',
          '-ar',
          '16000',
          '-f',
          's16le',
          pcm.path,
        ]);
        final bytes = ByteData.sublistView(await pcm.readAsBytes());
        var crossings = 0;
        for (var n = 2; n < bytes.lengthInBytes; n += 2) {
          if (bytes.getInt16(n - 2, Endian.little) <= 0 &&
              bytes.getInt16(n, Endian.little) > 0) {
            crossings++;
          }
        }
        expect(bytes.lengthInBytes, greaterThan(6000));
        final frequency = crossings / (bytes.lengthInBytes / 2 / 16000);
        // The chirp gains 200 Hz/s. A wrong source interval or A/V shift fails.
        expect(
          frequency,
          closeTo(300 + 200 * (result.segments[i].start + 0.3), 15),
        );
      }
      expect(counts, [13, 12, 12]);
      expect(joined, hasLength(37));
      for (var i = 0; i < joined.length; i++) {
        expect(
          joined[i],
          closeTo(original[i], 2),
          reason: 'Source frame $i lost, duplicated or reordered',
        );
      }
      expect(result.segments.first.start, closeTo(0, 0.03));
      expect(result.segments.last.end, closeTo(3.7, 0.03));
      await result.dispose();
      final cancelled = CancellationToken();
      await expectLater(
        service.split(
          inspected,
          1.25,
          root,
          token: cancelled,
          progress: (v, _) {
            if (v > 0) cancelled.cancel();
          },
        ),
        throwsA(isA<ExportCancelled>()),
      );
      expect(await root.list().where((e) => e is Directory).length, 0);
      expect(await source.exists(), true);

      // A matching closed GOP allows remuxing without another encode.
      final compatible = File('${root.path}/keyframes.mp4');
      await engine.run([
        '-y',
        '-v',
        'error',
        '-i',
        source.path,
        '-c:v',
        await engine.encoder(),
        '-g',
        '10',
        '-bf',
        '0',
        '-c:a',
        'copy',
        '-threads',
        '1',
        compatible.path,
      ]);
      final copySource = await service.inspect(compatible);
      final copied = await service.split(
        copySource,
        1,
        root,
        token: CancellationToken(),
        progress: (_, _) {},
      );
      expect(copied.copiedVideo, true);
      expect(copied.files, hasLength(4));
      expect(copied.segments.last.duration, closeTo(0.7, 0.03));
      await copied.dispose();
      final whole = await service.split(
        copySource,
        30,
        root,
        token: CancellationToken(),
        progress: (_, _) {},
      );
      expect(whole.copiedVideo, true);
      expect(await frames(whole.files.single), await frames(compatible));
      await whole.dispose();

      final silent = File('${root.path}/silent.mp4');
      await engine.run([
        '-y',
        '-v',
        'error',
        '-i',
        source.path,
        '-an',
        '-c:v',
        'copy',
        silent.path,
      ]);
      final silentParts = await service.split(
        await service.inspect(silent),
        1.25,
        root,
        token: CancellationToken(),
        progress: (_, _) {},
      );
      expect(silentParts.files, hasLength(3));
      for (final part in silentParts.files) {
        expect((await engine.inspect(part.path)).hasAudio, false);
      }
      await silentParts.dispose();

      final rotated = File('${root.path}/portrait.mp4');
      await engine.run([
        '-y',
        '-v',
        'error',
        '-display_rotation:v:0',
        '90',
        '-i',
        source.path,
        '-c',
        'copy',
        rotated.path,
      ]);
      final portrait = await service.split(
        await service.inspect(rotated),
        1.25,
        root,
        token: CancellationToken(),
        progress: (_, _) {},
      );
      for (final file in portrait.files) {
        final info = await engine.inspect(file.path);
        expect(info.width, 48);
        expect(info.height, 64);
        expect(info.hasAudio, true);
      }
      await portrait.dispose();
      final portraitCopy = await service.split(
        await service.inspect(rotated),
        30,
        root,
        token: CancellationToken(),
        progress: (_, _) {},
      );
      expect(portraitCopy.copiedVideo, true);
      final portraitInfo = await engine.inspect(portraitCopy.files.single.path);
      expect(portraitInfo.width, 48);
      expect(portraitInfo.height, 64);
      await portraitCopy.dispose();
      final blocked = File('${root.path}/blocked')..writeAsStringSync('keep');
      await expectLater(
        service.split(
          inspected,
          1.25,
          Directory('${blocked.path}/out'),
          token: CancellationToken(),
          progress: (_, _) {},
        ),
        throwsA(
          isA<MediaFailure>().having(
            (e) => e.message,
            'storage error',
            contains('free storage'),
          ),
        ),
      );
      expect(await blocked.readAsString(), 'keep');
    } finally {
      await root.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
  test(
    'real 120-second MP4 produces 4/2/2 segments for 30/60/90 presets',
    () async {
      final root = await Directory.systemTemp.createTemp('qrm_presets_');
      final engine = createMediaEngine();
      final service = SegmentationService(engine);
      try {
        final source = File('${root.path}/two_minutes.mp4');
        await engine.run([
          '-y',
          '-v',
          'error',
          '-f',
          'lavfi',
          '-i',
          'testsrc2=s=64x48:r=2:d=120',
          '-f',
          'lavfi',
          '-i',
          'sine=duration=120',
          '-c:v',
          await engine.encoder(),
          '-bf',
          '0',
          '-g',
          '60',
          '-c:a',
          'aac',
          '-threads',
          '1',
          source.path,
        ]);
        final inspected = await service.inspect(source);
        expect(inspected.info.duration, 120);
        for (final preset in [30.0, 60.0, 90.0]) {
          final result = await service.split(
            inspected,
            preset,
            root,
            token: CancellationToken(),
            progress: (_, _) {},
          );
          final expected = preset == 30
              ? [30, 30, 30, 30]
              : preset == 60
              ? [60, 60]
              : [90, 30];
          expect(result.segments.map((s) => s.duration), expected);
          expect(result.files, hasLength(expected.length));
          for (var i = 0; i < result.files.length; i++) {
            final info = await engine.inspect(result.files[i].path);
            expect(info.duration, closeTo(expected[i], 0.03));
            expect(info.hasVideo && info.hasAudio, true);
          }
          await result.dispose();
        }
      } finally {
        await root.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
