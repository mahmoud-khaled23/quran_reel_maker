import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:quran_reel_maker/features/export/export_plan.dart';
import 'package:quran_reel_maker/features/quran_text/quran_repository.dart';
import 'package:quran_reel_maker/features/synchronization/alignment_engine.dart';
import 'package:quran_reel_maker/models/reel_project.dart';

const request = AlignmentRequest(
  audioPath: '/tmp/audio.wav',
  trimStart: 60,
  trimEnd: 64,
  surah: 1,
  firstAyah: 2,
  lastAyah: 2,
);
Map<String, dynamic> response() => {
  'protocol': 1,
  'type': 'result',
  'timeline': 'source',
  'model': ProcessAlignmentEngine.model,
  'revision': ProcessAlignmentEngine.revision,
  'quranSha256': QuranRepository.textDigest,
  'cues': [
    {
      'surah': 1,
      'ayah': 2,
      'start': 61.0,
      'end': 63.0,
      'timingSource': 'automatic',
      'alignmentModel': ProcessAlignmentEngine.model,
      'alignmentScore': 0.7,
      'warnings': ['Listen and review.'],
      'words': [
        {'index': 0, 'start': 61.0, 'end': 63.0, 'score': 0.7},
      ],
    },
  ],
};

void main() {
  test(
    'automatic times rebase exactly once for export and survive save/load',
    () {
      final cues = validateAlignmentResult(response(), request);
      final project = ReelProject(
        id: 'test',
        audio: 'media/audio.wav',
        audioDuration: 70,
        trimStart: 60,
        trimEnd: 64,
        cues: cues,
      );
      final restored = ReelProject.decode(project.encode());
      expect(restored.cues.single.words.single.start, 61);
      expect(restored.cues.single.confidence, isNull);
      expect(restored.reviewed, isFalse);
      expect(
        project.validate(forExport: true),
        contains('Review ayah timings before export.'),
      );
      expect(
        overlayTimeline(restored)
            .map((s) => [s.startFrame, s.endFrame, s.cueIndex]),
        [
          [0, 30, null],
          [30, 90, 0],
          [90, 120, null],
        ],
      );
      final edited = restored.cues.single.copyWith(end: 63.5);
      expect(edited.words, isEmpty);
      expect(edited.alignmentScore, isNull);
      expect(edited.timingSource, 'edited');
    },
  );

  test('worker results reject wrong clock, references, unsafe words and nonfinite times', () {
    for (final change in <void Function(Map<String, dynamic>)>[
      (r) => r['timeline'] = 'trim-relative',
      (r) => r['revision'] = 'unknown',
      (r) => r['cues'][0]['ayah'] = 3,
      (r) => r['cues'][0]['start'] = 0,
      (r) => r['cues'][0]['end'] = double.nan,
      (r) => r['cues'][0]['words'][0]['end'] = 65,
      (r) => r['cues'][0]['words'][0]['index'] = -1,
      (r) => r['cues'][0]['alignmentScore'] = double.infinity,
      (r) => r['cues'][0]['warnings'] = <String>[],
      (r) => r['cues'][0]['confidence'] = 1,
    ]) {
      final value = response();
      change(value);
      expect(
        () => validateAlignmentResult(value, request),
        throwsFormatException,
      );
    }
  });

  test('old schema without alignment fields still loads as manual', () {
    final cue = AyahCue.fromJson({'surah': 1, 'ayah': 2, 'start': 1, 'end': 2});
    expect(cue.timingSource, 'manual');
    expect(cue.words, isEmpty);
  });

  group('local subprocess protocol', () {
    late Directory root;
    setUp(() async {
      root = await Directory.systemTemp.createTemp('qrm_protocol_');
    });
    tearDown(() async {
      await root.delete(recursive: true);
    });
    Future<AlignmentRequest> worker(String code) async {
      final file = File('${root.path}/worker with spaces');
      await file.writeAsString(
        '#!/usr/bin/env python3\nimport sys,json,time\n$code\n',
      );
      final result = await Process.run('chmod', ['+x', file.path]);
      expect(result.exitCode, 0);
      return AlignmentRequest(
        audioPath: request.audioPath,
        trimStart: 60,
        trimEnd: 64,
        surah: 1,
        firstAyah: 2,
        lastAyah: 2,
        workerExecutable: file.path,
      );
    }

    test('reads progress and a complete result without shell interpretation', () async {
      final r = await worker(
        'request=json.loads(sys.stdin.readline())\nassert request["trimStart"]==60\nprint(json.dumps({"protocol":1,"type":"progress","value":0.5,"message":"Aligning"}),flush=True)\nprint(${jsonEncode(jsonEncode(response()))},flush=True)',
      );
      final updates = <double>[];
      final cues = await const ProcessAlignmentEngine().align(
        r,
        onProgress: (p, _) => updates.add(p),
      );
      expect(cues.single.start, 61);
      expect(updates, [0.5]);
    });

    test('preserves actionable errors from a missing model', () async {
      final r = await worker(
        'sys.stdin.readline()\nprint(json.dumps({"protocol":1,"type":"error","message":"Run setup-alignment.sh"}),flush=True)\nsys.exit(1)',
      );
      await expectLater(
        const ProcessAlignmentEngine().align(r),
        throwsA(
          isA<AlignmentFailure>().having(
            (e) => e.message,
            'message',
            contains('setup-alignment.sh'),
          ),
        ),
      );
    });

    test('cancellation and timeout terminate a stalled worker', () async {
      final r = await worker('sys.stdin.readline()\ntime.sleep(60)');
      final cancellation = AlignmentCancellation();
      final running = const ProcessAlignmentEngine().align(
        r,
        cancellation: cancellation,
      );
      final assertion = expectLater(
        running,
        throwsA(
          isA<AlignmentFailure>().having(
            (e) => e.message,
            'message',
            contains('cancelled'),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      cancellation.cancel();
      await assertion;
      await expectLater(
        const ProcessAlignmentEngine(timeout: Duration(milliseconds: 100))
            .align(r),
        throwsA(
          isA<AlignmentFailure>().having(
            (e) => e.message,
            'message',
            contains('timed out'),
          ),
        ),
      );
    });

    test('malformed or incomplete output fails safely', () async {
      for (final output in ['not-json', '{"protocol":2,"type":"result"}', '']) {
        final r = await worker(
          'sys.stdin.readline()\nprint(${jsonEncode(output)},flush=True)',
        );
        await expectLater(
          const ProcessAlignmentEngine().align(r),
          throwsA(isA<AlignmentFailure>()),
        );
      }
    });
    test('malformed output terminates a worker that keeps running', () async {
      final r = await worker(
        'sys.stdin.readline()\nprint("not-json",flush=True)\ntime.sleep(60)',
      );
      await expectLater(
        const ProcessAlignmentEngine()
            .align(r)
            .timeout(const Duration(seconds: 5)),
        throwsA(isA<AlignmentFailure>()),
      );
    });
  }, skip: !Platform.isLinux);
}
