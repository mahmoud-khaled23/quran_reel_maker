// Standalone release-mode probe: no flutter_test/VM service dependency.
// Build ONLY with QRM_ALIGNMENT_BENCHMARK=true; provision the isolated debug
// package first, then replace it with this same-signed release APK (adb install -r).
// Results are printed as QRM_RELEASE_CASE / QRM_RELEASE_DONE in adb logcat.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:quran_reel_maker/features/quran_text/quran_repository.dart';
import 'package:quran_reel_maker/features/synchronization/alignment_engine.dart';
import 'package:quran_reel_maker/features/synchronization/android_alignment_engine.dart';
import 'package:quran_reel_maker/media_engine/media_engine.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  if (!const bool.fromEnvironment('QRM_ALIGNMENT_BENCHMARK')) {
    throw StateError('Use the isolated benchmark application ID.');
  }
  runApp(const MaterialApp(home: ReleaseProbe()));
}

class ReleaseProbe extends StatefulWidget {
  const ReleaseProbe({super.key});
  @override
  State<ReleaseProbe> createState() => _ReleaseProbeState();
}

class _ReleaseProbeState extends State<ReleaseProbe> {
  final messages = <String>[];
  bool busy = true;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => run());
  }

  void log(String value) {
    // Intentional console output: logcat is readable even in non-debuggable APKs.
    debugPrint(value, wrapWidth: null);
    if (mounted) setState(() => messages.add(value));
  }

  Future<void> run() async {
    log('QRM_RELEASE_START');
    try {
      final root = await getApplicationSupportDirectory();
      final engine = AndroidAlignmentEngine(
        media: createMediaEngine(),
        quran: await QuranRepository.load(),
        model: AlignmentModelStore(
          Directory(
            '${root.path}/alignment-models/${ProcessAlignmentEngine.model}',
          ),
        ),
      );
      final audio = '${root.path}/alignment-test.ogg';
      if (!await File(audio).exists()) {
        throw StateError('Provision the benchmark fixture first.');
      }
      final request = AlignmentRequest(
        audioPath: audio,
        trimStart: 14,
        trimEnd: 27,
        surah: 1,
        firstAyah: 2,
        lastAyah: 3,
      );
      // Ten sequential requests exercise release JNI, allocation/release and
      // latency drift. This single reciter is not an accuracy evaluation corpus.
      for (var i = 0; i < 10; i++) {
        final watch = Stopwatch()..start();
        var previous = 0, maxGap = 0;
        final heartbeat = Timer.periodic(const Duration(milliseconds: 50), (_) {
          final now = watch.elapsedMilliseconds;
          if (now - previous > maxGap) maxGap = now - previous;
          previous = now;
        });
        try {
          final cues = await engine.align(request);
          if (cues.length != 2 ||
              cues.expand((c) => c.words).length != 6 ||
              cues.first.start < 14.4 ||
              cues.first.start > 15.7 ||
              cues.last.end < 25.4 ||
              cues.last.end > 26.8) {
            throw StateError(
              'Canonical coverage/broad regression window failed.',
            );
          }
          log(
            'QRM_RELEASE_CASE ${jsonEncode({'case': 'base-$i', 'status': 'aligned', 'release': const bool.fromEnvironment('dart.vm.product'), 'accuracyGroundTruth': false, 'wallMs': watch.elapsedMilliseconds, 'rtf': watch.elapsedMilliseconds / 13000, 'maxHeartbeatGapMs': maxGap, 'native': engine.lastMetrics})}',
          );
        } finally {
          heartbeat.cancel();
        }
      }
      // Maximum-duration resource workload. Repeating the fixture cannot match
      // this short selection: require rejection, never score it as accuracy.
      final scratch = await Directory('${root.path}/release-probe')
          .create(recursive: true);
      final longAudio = File('${scratch.path}/long.wav');
      try {
        await engine.media.run([
          '-y',
          '-v',
          'error',
          '-stream_loop',
          '-1',
          '-i',
          audio,
          '-t',
          '180',
          '-ar',
          '16000',
          '-ac',
          '1',
          longAudio.path,
        ]);
        final watch = Stopwatch()..start();
        var previous = 0, maxGap = 0;
        final heartbeat = Timer.periodic(const Duration(milliseconds: 50), (_) {
          final now = watch.elapsedMilliseconds;
          if (now - previous > maxGap) maxGap = now - previous;
          previous = now;
        });
        AlignmentFailure? rejection;
        try {
          await engine.align(
            AlignmentRequest(
              audioPath: longAudio.path,
              trimStart: 0,
              trimEnd: 180,
              surah: 1,
              firstAyah: 2,
              lastAyah: 3,
            ),
          );
        } on AlignmentFailure catch (error) {
          rejection = error;
        } finally {
          heartbeat.cancel();
        }
        if (rejection == null ||
            !rejection.toString().contains('does not match')) {
          throw StateError(
            'Long negative must reject for wrong text: $rejection',
          );
        }
        log(
          'QRM_RELEASE_CASE ${jsonEncode({'case': '180-second-repeated-negative', 'status': 'rejected', 'release': const bool.fromEnvironment('dart.vm.product'), 'accuracyGroundTruth': false, 'wallMs': watch.elapsedMilliseconds, 'rtf': watch.elapsedMilliseconds / 180000, 'maxHeartbeatGapMs': maxGap, 'native': engine.lastMetrics})}',
        );
      } finally {
        if (await longAudio.exists()) await longAudio.delete();
      }
      log('QRM_RELEASE_DONE passed');
    } catch (error) {
      log('QRM_RELEASE_DONE failed: $error');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Isolated release benchmark')),
    body: Column(
      children: [
        if (busy) const LinearProgressIndicator(),
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'Keep this app visible. Tests use the private CC0 fixture; no download or network request is made.',
          ),
        ),
        Expanded(
          child: ListView(
            children: [
              for (final text in messages)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: SelectableText(text),
                ),
            ],
          ),
        ),
      ],
    ),
  );
}
