import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quran_reel_maker/features/export/export_service.dart';
import 'package:quran_reel_maker/features/quran_text/quran_repository.dart';
import 'package:quran_reel_maker/media_engine/media_engine.dart';
import 'package:quran_reel_maker/models/reel_project.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('real FFmpeg export: trim, Arabic, gaps, loop, audio, cleanup', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final root = await Directory.systemTemp.createTemp('qrm_media_');
      try {
        final media = Directory('${root.path}/media');
        await media.create();
        final engine = createMediaEngine();
        final quran = await QuranRepository.load();
        final font = FontLoader('AmiriQuran')
          ..addFont(rootBundle.load('assets/fonts/AmiriQuran.ttf'));
        await font.load();
        await (FontLoader(
          'NotoSans',
        )..addFont(rootBundle.load('assets/fonts/NotoSans.ttf'))).load();
        await engine.run([
          '-y',
          '-v',
          'error',
          '-f',
          'lavfi',
          '-i',
          'sine=frequency=440:duration=1',
          '-f',
          'lavfi',
          '-i',
          'sine=frequency=880:duration=3',
          '-filter_complex',
          '[0:a][1:a]concat=n=2:v=0:a=1[a]',
          '-map',
          '[a]',
          '${media.path}/audio.wav',
        ]);
        await engine.run([
          '-y',
          '-v',
          'error',
          '-f',
          'lavfi',
          '-i',
          'color=c=0x234939:s=640x480',
          '-frames:v',
          '1',
          '-threads',
          '1',
          '${media.path}/bg.png',
        ]);
        await engine.waveform(
          '${media.path}/audio.wav',
          '${media.path}/waveform.png',
        );
        expect(
          await File('${media.path}/waveform.png').length(),
          greaterThan(100),
        );
        final project = ReelProject(
          id: 'media',
          audio: 'media/audio.wav',
          audioDuration: 4,
          trimStart: 1,
          trimEnd: 3.5,
          background: 'media/bg.png',
          reviewed: true,
          cues: const [
            AyahCue(surah: 1, ayah: 1, start: 0.5, end: 1.5),
            AyahCue(surah: 1, ayah: 2, start: 2, end: 3.5),
          ],
        );
        final output = Directory('${root.path}/exports');
        final values = <double>[];
        final file = await ExportService(engine, quran).export(
          project,
          root,
          output,
          token: CancellationToken(),
          progress: values.add,
        );
        final metadata = jsonDecode(
          await engine.run([
            '-v',
            'error',
            '-show_streams',
            '-show_format',
            '-of',
            'json',
            file.path,
          ], probe: true),
        ) as Map;
        final streams = (metadata['streams'] as List).cast<Map>();
        final video = streams.firstWhere((s) => s['codec_type'] == 'video');
        expect(video['codec_name'], 'h264');
        expect(video['width'], 1080);
        expect(video['height'], 1920);
        expect(video['r_frame_rate'], '30/1');
        expect(video['pix_fmt'], 'yuv420p');
        expect(streams.any((s) => s['codec_name'] == 'aac'), isTrue);
        expect(
          double.parse(metadata['format']['duration'] as String),
          closeTo(2.5, 0.1),
        );
        expect(values.last, 1);
        final bytes = await file.readAsBytes();
        // Fast-start places moov before the encoded media data.
        final atoms = latin1.decode(bytes);
        expect(atoms.indexOf('moov'), lessThan(atoms.indexOf('mdat')));
        Future<int> brightPixels(double at) async {
          final path = '${root.path}/frame_$at.gray';
          await engine.run([
            '-y',
            '-v',
            'error',
            '-ss',
            '$at',
            '-i',
            file.path,
            '-vf',
            'crop=900:600:90:800,format=gray',
            '-frames:v',
            '1',
            '-f',
            'rawvideo',
            '-threads',
            '1',
            path,
          ]);
          return (await File(path).readAsBytes()).where((b) => b > 220).length;
        }

        expect(await brightPixels(0.2), greaterThan(500));
        expect(
          await brightPixels(0.75),
          lessThan(30),
        ); // Explicit gap must be blank.
        expect(await brightPixels(1.3), greaterThan(500));
        final pcm = '${root.path}/sound.pcm';
        await engine.run([
          '-y',
          '-v',
          'error',
          '-i',
          file.path,
          '-t',
          '0.2',
          '-ac',
          '1',
          '-ar',
          '8000',
          '-f',
          's16le',
          pcm,
        ]);
        final samples = ByteData.sublistView(await File(pcm).readAsBytes());
        var crossings = 0;
        for (var i = 2; i < samples.lengthInBytes; i += 2) {
          if (samples.getInt16(i - 2, Endian.little) <= 0 &&
              samples.getInt16(i, Endian.little) > 0) {
            crossings++;
          }
        }
        expect(
          crossings / (samples.lengthInBytes / 2 / 8000),
          closeTo(880, 25),
        );
        // Video shorter than audio must loop; contain mode must also export.
        final encoder = await engine.encoder();
        await engine.run([
          '-y',
          '-v',
          'error',
          '-loop',
          '1',
          '-i',
          '${media.path}/bg.png',
          '-t',
          '0.3',
          '-c:v',
          encoder,
          '-pix_fmt',
          'yuv420p',
          '-threads',
          '1',
          '${media.path}/bg.mp4',
        ]);
        final looped = await ExportService(engine, quran).export(
          project.copyWith(
            background: 'media/bg.mp4',
            videoBackground: true,
            fit: BackgroundFit.contain,
            cues: [],
          ),
          root,
          output,
          token: CancellationToken(),
          progress: (_) {},
        );
        expect((await engine.inspect(looped.path)).duration, closeTo(2.5, 0.1));
        expect(
          metadata['format']['tags']['copyright'],
          contains('CHANGING IT IS NOT ALLOWED'),
        );
        final cancelled = CancellationToken();
        await expectLater(
          ExportService(engine, quran).export(
            project,
            root,
            output,
            token: cancelled,
            progress: (_) => cancelled.cancel(),
          ),
          throwsA(isA<ExportCancelled>()),
        );
        expect(
          await output.list().where((entity) => entity is Directory).length,
          0,
        );
        // Retain a deterministic evidence artifact only when explicitly requested.
        const evidence = String.fromEnvironment('MEDIA_EVIDENCE');
        if (evidence.isNotEmpty) {
          await Directory(evidence).create(recursive: true);
          await file.copy('$evidence/arabic-trim-test.mp4');
          await File('${file.path}.txt')
              .copy('$evidence/arabic-trim-test.mp4.txt');
          await engine.run([
            '-y',
            '-v',
            'error',
            '-ss',
            '0.2',
            '-i',
            file.path,
            '-frames:v',
            '1',
            '-threads',
            '1',
            '$evidence/export-frame.png',
          ]);
        }
      } finally {
        await root.delete(recursive: true);
      }
    });
  }, timeout: const Timeout(Duration(minutes: 4)));
  test('real FFmpeg cancellation stops a running session', () async {
    final engine = createMediaEngine();
    final token = CancellationToken();
    final timer = Future<void>.delayed(
      const Duration(milliseconds: 800),
      token.cancel,
    );
    await expectLater(
      engine.run([
        '-v',
        'error',
        '-re',
        '-f',
        'lavfi',
        '-i',
        'sine=duration=30',
        '-f',
        'null',
        '-',
      ], token: token),
      throwsA(isA<ExportCancelled>()),
    );
    await timer;
  }, timeout: const Timeout(Duration(seconds: 15)));
}
