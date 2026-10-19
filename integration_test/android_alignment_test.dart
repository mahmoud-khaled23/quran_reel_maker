import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:quran_reel_maker/features/quran_text/quran_repository.dart';
import 'package:quran_reel_maker/features/synchronization/alignment_engine.dart';
import 'package:quran_reel_maker/features/synchronization/android_alignment_engine.dart';
import 'package:quran_reel_maker/media_engine/media_engine.dart';
import 'package:quran_reel_maker/models/reel_project.dart';

/// Requires scripts/alignment/prepare-device.sh once; never downloads in this test.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'real Android CPU alignment, repeat job, responsiveness and cancellation',
    (tester) async {
      expect(
        Platform.isAndroid,
        isTrue,
        reason: 'This is an Android device test, not a desktop substitute.',
      );
      final root = await getApplicationSupportDirectory();
      final fixture = File('${root.path}/alignment-test.ogg');
      expect(
        await fixture.exists(),
        isTrue,
        reason: 'Run scripts/alignment/prepare-device.sh after installing the debug APK.',
      );
      final engine = AndroidAlignmentEngine(
        media: createMediaEngine(),
        quran: await QuranRepository.load(),
        model: AlignmentModelStore(
          Directory(
            '${root.path}/alignment-models/${ProcessAlignmentEngine.model}',
          ),
        ),
      );
      expect(
        await engine.model.isInstalled(),
        isTrue,
        reason: 'Install the verified model before running offline.',
      );
      final request = AlignmentRequest(
        audioPath: fixture.path,
        trimStart: 14,
        trimEnd: 27,
        surah: 1,
        firstAyah: 2,
        lastAyah: 3,
      );
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: CircularProgressIndicator())),
      );
      final report = <Map<String, dynamic>>[];
      final file = File('${root.path}/alignment-device-report.json');
      Future<void> saveReport() => file.writeAsString(
        jsonEncode({
          'platform': Platform.operatingSystemVersion,
          'accuracyGroundTruth': false,
          'runs': report,
        }),
      );
      Future<List<AyahCue>?> runCase(
        String name,
        AlignmentRequest selection, {
        bool rejects = false,
      }) async {
        final watch = Stopwatch()..start();
        var heartbeatAt = 0, maxHeartbeatGapMs = 0;
        final heartbeat = Timer.periodic(const Duration(milliseconds: 50), (_) {
          final now = watch.elapsedMilliseconds;
          final gap = now - heartbeatAt;
          if (gap > maxHeartbeatGapMs) maxHeartbeatGapMs = gap;
          heartbeatAt = now;
        });
        var done = false;
        var pumps = 0;
        List<AyahCue>? cues;
        Object? failure;
        final job = engine
            .align(selection)
            .then<void>(
              (value) => cues = value,
              onError: (Object error, StackTrace stack) {
                failure = error;
              },
            )
            .whenComplete(() => done = true);
        // Pump while native inference runs: blocking the UI would stall this loop.
        while (!done && watch.elapsed < const Duration(minutes: 10)) {
          await tester.pump(const Duration(milliseconds: 100));
          pumps++;
        }
        await job.whenComplete(heartbeat.cancel);
        report.add({
          'case': name,
          'status': failure == null ? 'aligned' : 'rejected',
          if (failure != null) 'error': failure.toString(),
          'scope': 'fresh model session per app request; OS cache may be warm',
          'wallMs': watch.elapsedMilliseconds,
          'rtf':
              watch.elapsedMilliseconds /
              1000 /
              (selection.trimEnd - selection.trimStart),
          'pumpIterations': pumps,
          'maxHeartbeatGapMs': maxHeartbeatGapMs,
          'native': engine.lastMetrics,
          if (cues != null) 'cues': cues!.map((c) => c.toJson()).toList(),
        });
        await saveReport();
        debugPrint('DEVICE_CASE $name ${jsonEncode(report.last)}');
        if (rejects) {
          expect(failure, isA<AlignmentFailure>());
          expect(failure.toString(), contains('does not match'));
        } else if (failure != null) {
          throw failure!;
        }
        expect(pumps, greaterThan(2));
        return cues;
      }

      for (var run = 0; run < 2; run++) {
        final cues = (await runCase('base-$run', request))!;
        expect(cues.length, 2);
        expect(cues.first.start, inInclusiveRange(14.4, 15.7));
        expect(cues.last.end, inInclusiveRange(25.4, 26.8));
        expect(cues.expand((c) => c.words).length, 6);
      }
      final partial = (await runCase(
        'partial',
        AlignmentRequest(
          audioPath: fixture.path,
          trimStart: 17,
          trimEnd: 21.7,
          surah: 1,
          firstAyah: 2,
          lastAyah: 2,
          firstWord: 1,
          lastWord: 3,
        ),
      ))!;
      expect(partial.single.words.map((w) => w.index), [1, 2, 3]);
      await runCase(
        'wrong',
        AlignmentRequest(
          audioPath: fixture.path,
          trimStart: 14,
          trimEnd: 27,
          surah: 1,
          firstAyah: 5,
          lastAyah: 7,
        ),
        rejects: true,
      );
      final variantRoot = await Directory(
        '${root.path}/alignment-test-variants',
      ).create(recursive: true);
      final variants = await variantRoot.createTemp('run_');
      addTearDown(() => variants.delete(recursive: true));
      final slow = '${variants.path}/slow.wav';
      await engine.media.run([
        '-v',
        'error',
        '-ss',
        '14',
        '-i',
        fixture.path,
        '-af',
        'atrim=duration=13,asetpts=PTS-STARTPTS,atempo=0.5,apad,atrim=duration=26',
        '-ar',
        '16000',
        '-ac',
        '1',
        slow,
      ]);
      final slowRequest = AlignmentRequest(
        audioPath: slow,
        trimStart: 0,
        trimEnd: 26,
        surah: 1,
        firstAyah: 2,
        lastAyah: 3,
      );
      expect(
        (await runCase('slow', slowRequest))!.expand((c) => c.words).length,
        6,
      );
      final cancel = AlignmentCancellation();
      final cancelWatch = Stopwatch();
      Timer? cancelTimer;
      final job = engine.align(
        slowRequest,
        cancellation: cancel,
        onProgress: (v, _) {
          if (v > .1 && v < .85 && cancelTimer == null) {
            cancelTimer = Timer(const Duration(milliseconds: 100), () {
              cancelWatch.start();
              cancel.cancel();
            });
          }
        },
      );
      await expectLater(job, throwsA(isA<AlignmentFailure>()));
      cancelTimer?.cancel();
      expect(cancel.cancelled, isTrue);
      report.add({
        'case': 'cancel-during-inference',
        'status': 'cancelled',
        'latencyMs': cancelWatch.elapsedMilliseconds,
      });
      expect(
        await engine.model.directory
            .list()
            .where((f) => f is Directory && f.path.contains('audio_'))
            .toList(),
        isEmpty,
      );
      await saveReport();
      debugPrint('ALIGNMENT_DEVICE_REPORT ${await file.readAsString()}');
    },
    timeout: const Timeout(Duration(minutes: 25)),
  );
}
