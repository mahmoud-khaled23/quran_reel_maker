import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:quran_reel_maker/features/audio_editor/time_format.dart';
import 'package:quran_reel_maker/features/export/export_plan.dart';
import 'package:quran_reel_maker/features/export/export_settings.dart';
import 'package:quran_reel_maker/features/preview/overlay_state.dart';
import 'package:quran_reel_maker/features/quran_text/quran_words.dart';
import 'package:quran_reel_maker/media_engine/media_engine.dart';
import 'package:quran_reel_maker/models/reel_project.dart';

class ProbeEngine extends MediaEngine {
  ProbeEngine(this.data);
  final Map<String, Object> data;
  @override
  Future<String> run(
    List<String> arguments, {
    bool probe = false,
    CancellationToken? token,
    void Function(double)? onTime,
  }) async => jsonEncode(data);
}

void main() {
  test('HH:MM:SS:FFF parses exact milliseconds including hour rollover', () {
    for (final pair in {
      '00:00:05:250': 5.25,
      '00:01:23:045': 83.045,
      '01:02:03:500': 3723.5,
      '100:00:00:001': 360000.001,
    }.entries) {
      expect(parseTime(pair.key), pair.value);
      expect(timeLabel(pair.value), pair.key);
    }
    expect(timeLabel(59.9996), '00:01:00:000');
    for (final invalid in [
      '1',
      '00:60:00:000',
      '00:00:60:000',
      '00:00:01:20',
      '-01:00:00:000',
      'NaN',
      '01:01:01.001',
      '9223372036854775807:00:00:000',
    ]) {
      expect(parseTime(invalid), isNull);
    }
  });
  test('media trim validation and source video loop clocks', () {
    expect(validTrim(1, 2, 3), isTrue);
    for (final times in [
      [-1.0, 2.0],
      [2.0, 2.0],
      [1.0, 3.1],
      [double.nan, 2.0],
    ]) {
      expect(validTrim(times[0], times[1], 3), isFalse);
    }
    const project = ReelProject(
      id: 'clock',
      audio: 'media/a.wav',
      audioDuration: 30,
      trimStart: 14,
      trimEnd: 27,
      videoBackground: true,
      videoDuration: 10,
      videoTrimStart: 3,
      videoTrimEnd: 5,
    );
    expect(project.videoTime(14), 3);
    expect(project.videoTime(17.5), 4.5);
    expect(project.copyWith(videoTrimEnd: 11).validate(), isNotEmpty);
  });
  test('progressive excerpts obey onsets, long pauses, partial range and nonzero trim', () {
    const project = ReelProject(
      id: 'words',
      audio: 'media/a.wav',
      audioDuration: 30,
      trimStart: 10,
      trimEnd: 16,
      cues: [
        AyahCue(
          surah: 1,
          ayah: 2,
          start: 10.01,
          end: 15,
          firstWord: 1,
          lastWord: 3,
          words: [
            WordCue(index: 1, start: 10.01, end: 10.8, score: 0.7),
            WordCue(index: 2, start: 11, end: 12, score: 0.7),
            WordCue(index: 3, start: 14, end: 15, score: 0.7),
          ],
        ),
      ],
    );
    const verse = 'أَوَّلٌ ثَانٍ ثَالِثٌ رَابِعٌ خَامِسٌ';
    expect(overlayAt(project, 10), isNull);
    expect(
      overlayAt(project, 10.02),
      isNull,
    ); // No early onset on the frame clock.
    expect(overlayAt(project, 10.04)!.text(verse), 'ثَانٍ');
    expect(overlayAt(project, 11.5)!.text(verse), 'ثَانٍ ثَالِثٌ');
    expect(overlayAt(project, 12.5), isNull);
    expect(overlayAt(project, 14.2)!.text(verse), 'ثَانٍ ثَالِثٌ رَابِعٌ');
    expect(overlayAt(project, 15.1), isNull);
    expect(
      overlayAt(project.copyWith(trimStart: 11), 11.5)!.text(verse),
      'ثَالِثٌ',
    );
    for (final span in overlayTimeline(project)) {
      for (var f = span.startFrame; f < span.endFrame; f++) {
        expect(
          span.state?.key,
          overlayAt(project, project.trimStart + f / 30)?.key,
        );
      }
    }
  });
  test('manual fallback uses only the selected excerpt and preserves original marks', () {
    const project = ReelProject(
      id: 'manual',
      audio: 'media/a.wav',
      audioDuration: 3,
      trimEnd: 3,
      cues: [
        AyahCue(surah: 1, ayah: 1, start: 0, end: 2, firstWord: 1, lastWord: 2),
      ],
    );
    expect(overlayAt(project, 1)!.text('أ  بٌ   جٍ د'), 'بٌ   جٍ');
    expect(overlayAt(project, 2.1), isNull);
    expect(canonicalExcerpt('أ ب ۖ ج', 1, 1), 'ب ۖ');
  });
  test('all six resolutions preserve aspect and cap low-resolution video', () {
    for (final quality in exportResolutions) {
      final size = exportSize(
        ReelProject(id: 'size', exportResolution: quality),
      );
      expect(size.width, quality);
      expect(size.width / size.height, closeTo(9 / 16, 0.01));
      expect(size.width % 2 + size.height % 2, 0);
    }
    const source = ReelProject(
      id: 'size',
      videoBackground: true,
      originalAspect: true,
      backgroundWidth: 640,
      backgroundHeight: 360,
    );
    expect(exportSize(source).toString(), '640 × 360');
    expect(
      exportSize(source.copyWith(exportResolution: 144)).toString(),
      '256 × 144',
    );
    expect(
      () => exportSize(source.copyWith(exportResolution: 999)),
      throwsFormatException,
    );
  });
  test(
    'probe respects rotation, sample aspect and excludes cover art',
    () async {
      final info = await ProbeEngine({
        'streams': [
          {
            'codec_type': 'video',
            'width': 100,
            'height': 100,
            'disposition': {'attached_pic': 1},
          },
          {
            'codec_type': 'video',
            'width': 720,
            'height': 480,
            'sample_aspect_ratio': '4:3',
            'side_data_list': [
              {'rotation': -90},
            ],
          },
        ],
        'format': {'duration': '10'},
      }).inspect('test');
      expect(info.width, 480);
      expect(info.height, 960);
    },
  );
  test('readable Unicode filenames sanitize unsafe characters and reserve atomically', () async {
    expect(exportStem('Surah Al Rahman'), 'Surah Al Rahman');
    expect(exportStem('سورة الرحمن'), 'سورة الرحمن');
    expect(exportStem('a/b\\c:*?"<>|.'), 'a_b_c_______');
    expect(exportStem('CON'), '_CON');
    expect(exportStem('...'), 'Quran Reel');
    expect(exportStem('Reel.mp4'), 'Reel');
    final root = await Directory.systemTemp.createTemp('qrm_names_');
    addTearDown(() => root.delete(recursive: true));
    final files = await Future.wait(
      List.generate(3, (_) => reserveExport(root, 'Surah Al Rahman')),
    );
    expect(files.map((f) => f.path).toSet(), hasLength(3));
    expect(files.any((f) => f.path.endsWith('Surah Al Rahman.mp4')), isTrue);
  });
  test('old projects retain defaults; new trims, style and partial cues round trip', () {
    const old =
        '{"schemaVersion":1,"id":"legacy","title":"Old","audio":null,"audioDuration":0,"trimStart":0,"trimEnd":0,"background":null,"videoBackground":false,"fit":"cover","cropX":0.5,"cropY":0.5,"reviewed":false,"cues":[]}';
    final loaded = ReelProject.decode(old);
    expect(loaded.originalAspect, isFalse);
    expect(loaded.exportResolution, 1080);
    final changed = loaded.copyWith(
      videoDuration: 5,
      videoTrimStart: 1,
      videoTrimEnd: 4,
      overlayX: 0.2,
      overlayY: 0.8,
      fontColor: 0xFFFFD77A,
      textBackground: false,
      exportResolution: 360,
      originalAspect: true,
    );
    expect(ReelProject.decode(changed.encode()).toJson(), changed.toJson());
  });
}
