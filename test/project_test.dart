import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:quran_reel_maker/models/reel_project.dart';
import 'package:quran_reel_maker/services/project_store.dart';
import 'package:quran_reel_maker/features/export/export_plan.dart';
import 'package:quran_reel_maker/features/synchronization/alignment_engine.dart';

const project = ReelProject(
  id: 'test',
  audio: 'media/audio.wav',
  audioDuration: 120,
  trimStart: 60,
  trimEnd: 64,
  background: 'media/bg.png',
  reviewed: true,
  cues: [
    AyahCue(surah: 1, ayah: 1, start: 58, end: 61),
    AyahCue(surah: 1, ayah: 2, start: 62, end: 65),
  ],
);
void main() {
  test(
    'absolute ayah timestamps clip and rebase exactly once; gaps stay blank',
    () {
      final spans = overlayTimeline(project);
      expect(
        spans.map((s) => [s.startFrame, s.endFrame, s.cueIndex]).toList(),
        [
          [0, 30, 0],
          [30, 60, null],
          [60, 120, 1],
        ],
      );
    },
  );
  test('no text still creates a full-duration blank overlay', () {
    final spans = overlayTimeline(project.copyWith(cues: []));
    expect(spans.single.duration, 4);
    expect(spans.single.cueIndex, isNull);
  });
  test('round trip does not embed or mutate Quran text', () {
    final restored = ReelProject.decode(project.encode());
    expect(restored.toJson(), project.toJson());
    expect(restored.validate(forExport: true), isEmpty);
  });
  test('reject invalid trim, overlaps, NaN and traversal paths', () {
    expect(project.copyWith(trimStart: 64).validate(), isNotEmpty);
    expect(project.copyWith(trimEnd: 121).validate(), isNotEmpty);
    expect(project.copyWith(cropX: double.nan).validate(), isNotEmpty);
    expect(project.copyWith(audio: '../secret.wav').validate(), isNotEmpty);
    expect(
      project
          .copyWith(
            cues: [
              const AyahCue(surah: 1, ayah: 1, start: 60, end: 62),
              const AyahCue(surah: 1, ayah: 2, start: 61, end: 63),
            ],
          )
          .validate(),
      isNotEmpty,
    );
    expect(
      project.copyWith(reviewed: false).validate(forExport: true),
      isNotEmpty,
    );
  });
  test('manual grid has no invented confidence and uses source time', () {
    final cues = manualTimingGrid(
      surah: 1,
      first: 2,
      last: 3,
      start: 60,
      end: 64,
    );
    expect(cues.first.start, 60);
    expect(cues.last.end, 64);
    expect(cues.every((c) => c.confidence == null), isTrue);
  });
  test('arguments keep hostile filenames separate from filter grammar', () {
    final args = exportArguments(
      project: project,
      audio: "/tmp/a'\"; touch x.wav",
      background: r'/tmp/bg $(echo x).png',
      overlayList: '/tmp/overlays.ffconcat',
      output: '/tmp/output.mp4',
      encoder: 'libx264',
    );
    expect(args[args.indexOf('-ss') + 1], '60.000000');
    expect(args, contains("/tmp/a'\"; touch x.wav"));
    expect(args[args.indexOf('-filter_complex') + 1], isNot(contains('touch')));
  });
  test(
    'project survives save/load with private copies of imported media',
    () async {
      final root = await Directory.systemTemp.createTemp('qrm_store_');
      addTearDown(() => root.delete(recursive: true));
      final store = ProjectStore(Directory('${root.path}/projects'));
      final original = await store.create();
      final source = File('${root.path}/input.wav');
      await source.writeAsBytes([1, 2, 3]);
      final relative = await store.importFile(original.id, source, 'audio');
      final changed = original.copyWith(
        audio: relative,
        audioDuration: 5,
        trimEnd: 5,
        title: 'Saved reel',
      );
      await store.save(changed);
      await source.delete();
      expect((await store.load(changed.id)).title, 'Saved reel');
      final malformed = Directory('${store.root.path}/bad');
      await malformed.create();
      await File('${malformed.path}/project.json')
          .writeAsString(project.encode().replaceFirst('"cover"', '"invalid"'));
      expect(await store.list(), hasLength(1));
      expect(
        File('${store.directory(changed.id).path}/project.json.tmp')
            .existsSync(),
        isFalse,
      );
    },
  );
  test('unsupported schema versions fail explicitly', () {
    expect(
      () => ReelProject.decode(
        project.encode().replaceFirst(
          '"schemaVersion": 1',
          '"schemaVersion": 99',
        ),
      ),
      throwsFormatException,
    );
  });
  test('empty projects reject malformed timing metadata before UI loading', () {
    const empty = ReelProject(id: 'empty');
    expect(empty.validate(), isEmpty);
    expect(empty.copyWith(trimStart: double.infinity).validate(), isNotEmpty);
    expect(empty.copyWith(trimEnd: -1).validate(), isNotEmpty);
    expect(
      empty.copyWith(audioDuration: 10, trimEnd: 10).validate(),
      isNotEmpty,
    );
    expect(
      () => ReelProject.decode(
        empty.encode().replaceFirst('"trimStart": 0', '"trimStart": 1e999'),
      ),
      throwsFormatException,
    );
  });
}
