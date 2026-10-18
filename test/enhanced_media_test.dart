import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quran_reel_maker/features/export/export_service.dart';
import 'package:quran_reel_maker/features/quran_text/quran_repository.dart';
import 'package:quran_reel_maker/media_engine/media_engine.dart';
import 'package:quran_reel_maker/models/reel_project.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'actual MP4 loops only trimmed video, reveals words, and uses style and quality',
    (tester) async {
      await tester.runAsync(() async {
        final root = await Directory.systemTemp.createTemp('qrm_enhanced_');
        try {
          final media = Directory('${root.path}/media')..createSync();
          final engine = createMediaEngine();
          final quran = await QuranRepository.load();
          await (FontLoader(
            'AmiriQuran',
          )..addFont(rootBundle.load('assets/fonts/AmiriQuran.ttf'))).load();
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
            'sine=duration=5',
            '${media.path}/a.wav',
          ]);
          await engine.run([
            '-y',
            '-v',
            'error',
            '-f',
            'lavfi',
            '-i',
            'color=red:s=640x360:r=30:d=1',
            '-f',
            'lavfi',
            '-i',
            'color=green:s=640x360:r=30:d=1',
            '-f',
            'lavfi',
            '-i',
            'color=blue:s=640x360:r=30:d=1',
            '-filter_complex',
            '[0:v][1:v][2:v]concat=n=3:v=1:a=0[v]',
            '-map',
            '[v]',
            '-c:v',
            await engine.encoder(),
            '-threads',
            '1',
            '${media.path}/bg.mp4',
          ]);
          const project = ReelProject(
            id: 'enhanced',
            title: 'Surah Al Rahman',
            audio: 'media/a.wav',
            audioDuration: 5,
            trimStart: 1,
            trimEnd: 5,
            background: 'media/bg.mp4',
            videoBackground: true,
            videoDuration: 3,
            videoTrimStart: 1,
            videoTrimEnd: 2,
            backgroundWidth: 640,
            backgroundHeight: 360,
            originalAspect: true,
            exportResolution: 240,
            overlayX: 0,
            overlayY: 0,
            fontColor: 0xFFFFD77A,
            textBackground: false,
            reviewed: true,
            cues: [
              AyahCue(
                surah: 1,
                ayah: 2,
                start: 1,
                end: 4,
                lastWord: 2,
                words: [
                  WordCue(index: 0, start: 1, end: 1.5),
                  WordCue(index: 1, start: 2, end: 2.5),
                  WordCue(index: 2, start: 3, end: 4),
                ],
              ),
            ],
          );
          final output = Directory('${root.path}/exports');
          final file = await ExportService(engine, quran).export(
            project,
            root,
            output,
            token: CancellationToken(),
            progress: (_) {},
          );
          expect(file.path, endsWith('/Surah Al Rahman.mp4'));
          final info = await engine.inspect(file.path);
          expect(info.width, 426);
          expect(info.height, 240);
          expect(info.duration, closeTo(4, 0.1));
          Future<List<int>> frame(double at) async {
            final path = '${root.path}/frame-$at.rgb';
            await engine.run([
              '-y',
              '-v',
              'error',
              '-ss',
              '$at',
              '-i',
              file.path,
              '-frames:v',
              '1',
              '-pix_fmt',
              'rgb24',
              '-f',
              'rawvideo',
              '-threads',
              '1',
              path,
            ]);
            return File(path).readAsBytes();
          }

          int gold(List<int> data) {
            var count = 0;
            for (var y = 0; y < 140; y++) {
              for (var x = 0; x < info.width; x++) {
                final i = (y * info.width + x) * 3;
                if (data[i] > 175 && data[i + 1] > 140 && data[i + 2] < 170) {
                  count++;
                }
              }
            }
            return count;
          }

          final first = await frame(0.25),
              second = await frame(1.25),
              third = await frame(2.25),
              blank = await frame(3.5);
          expect(gold(first), greaterThan(10));
          expect(gold(second), greaterThan(gold(first)));
          expect(gold(third), greaterThan(gold(second)));
          expect(gold(blank), 0);
          // Corner pixels must remain green across several repeats; red/blue source
          // regions lie outside the selected segment and must never be exported.
          for (final data in [first, second, third, blank]) {
            expect(data[1], greaterThan(90));
            expect(data[0], lessThan(20));
            expect(data[2], lessThan(20));
          }
          final blocked = File('${root.path}/blocked')
            ..writeAsStringSync('keep');
          await expectLater(
            ExportService(engine, quran).export(
              project,
              root,
              Directory('${blocked.path}/exports'),
              token: CancellationToken(),
              progress: (_) {},
            ),
            throwsA(
              isA<MediaFailure>().having(
                (e) => e.message,
                'diagnostic',
                contains('free storage and write permissions'),
              ),
            ),
          );
          expect(await blocked.readAsString(), 'keep');
          const evidence = String.fromEnvironment('MEDIA_EVIDENCE');
          if (evidence.isNotEmpty) {
            await Directory(evidence).create(recursive: true);
            await file.copy('$evidence/progressive-trimmed-video.mp4');
            await engine.run([
              '-y',
              '-v',
              'error',
              '-ss',
              '2.25',
              '-i',
              file.path,
              '-frames:v',
              '1',
              '-threads',
              '1',
              '$evidence/progressive-frame.png',
            ]);
          }
        } finally {
          await root.delete(recursive: true);
        }
      });
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
