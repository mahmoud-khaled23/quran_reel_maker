import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:quran_reel_maker/features/export/export_settings.dart';
import 'package:quran_reel_maker/features/video_trimmer/segment_plan.dart';
import 'package:quran_reel_maker/media_engine/media_engine.dart';
import 'package:quran_reel_maker/services/export_destination.dart';

void main() {
  test(
    'long Unicode project names keep their numbering after save sanitization',
    () {
      final names = SegmentNames(List.filled(100, 'آ').join(), 2);
      expect(names.filenames[0], endsWith('_001.mp4'));
      expect(names.filenames[1], endsWith('_002.mp4'));
      for (final name in names.filenames) {
        expect(utf8.encode(name).length, lessThanOrEqualTo(164));
        expect('${exportStem(name)}.mp4', name);
      }
    },
  );
  test('120-second presets include the final remainder', () {
    expect(segmentPlan(120, 30).map((s) => s.duration), [30, 30, 30, 30]);
    expect(segmentPlan(120, 60).map((s) => s.duration), [60, 60]);
    expect(segmentPlan(120, 90).map((s) => s.duration), [90, 30]);
    expect(segmentPlan(122.75, 60).map((s) => s.duration), [60, 60, 2.75]);
    expect(segmentPlan(12, 30).single.duration, 12);
  });
  test(
    'fractional boundaries cover the source exactly without drift or gaps',
    () {
      final plan = segmentPlan(99.999999, 0.333333);
      expect(plan.first.startUs, 0);
      expect(plan.last.endUs, 99999999);
      for (var i = 1; i < plan.length; i++) {
        expect(plan[i].startUs, plan[i - 1].endUs);
        expect(plan[i].index, i);
        expect(plan[i].duration, greaterThan(0));
      }
      expect(
        plan.fold<int>(0, (sum, s) => sum + s.endUs - s.startUs),
        99999999,
      );
    },
  );
  test(
    'invalid, unrepresentable and excessive duration/count inputs rejected',
    () {
      for (final value in [0.0, -1.0, double.nan, double.infinity, 0.0000001]) {
        expect(() => segmentPlan(120, value), throwsFormatException);
        expect(() => segmentPlan(value, 30), throwsFormatException);
      }
      expect(() => segmentPlan(120, 0.001), throwsFormatException);
    },
  );
  test(
    'project edits update automatic names and preserve custom names/order',
    () {
      final names = SegmentNames('lecture_recording', 4);
      expect(names.filenames, [
        for (var i = 1; i <= 4; i++) 'lecture_recording_00$i.mp4',
      ]);
      names.rename(1, 'Z opening');
      names.rename(3, 'A ending.mp4');
      names.projectName = 'new:/project';
      expect(names.filenames, [
        'new__project_001.mp4',
        'Z opening.mp4',
        'new__project_003.mp4',
        'A ending.mp4',
      ]);
      expect(names.resized(3).filenames, names.filenames.take(3));
      names.reset(1);
      expect(names.filenames[1], 'new__project_002.mp4');
      expect(() => names.projectName = '  ', throwsFormatException);
      expect(() => names.rename(0, ''), throwsFormatException);
      expect(
        SegmentNames('سورة الفاتحة', 1000).filenames.first,
        'سورة الفاتحة_0001.mp4',
      );
    },
  );
  test(
    'custom/default and case-insensitive duplicate names are disambiguated',
    () {
      final names = SegmentNames('lecture', 4);
      names.rename(0, 'lecture_002');
      names.rename(2, 'LECTURE_002');
      names.rename(3, 'lecture_002 (2)');
      expect(names.filenames, [
        'lecture_002.mp4',
        'lecture_002 (2).mp4',
        'LECTURE_002 (3).mp4',
        'lecture_002 (2) (2).mp4',
      ]);
    },
  );
  test(
    'batch saving reserves collisions and copies notices without overwrites',
    () async {
      final root = await Directory.systemTemp.createTemp('qrm_names_');
      try {
        final source = File('${root.path}/source.mp4')
          ..writeAsBytesSync([1, 2, 3]);
        File('${source.path}.txt').writeAsStringSync('license notice');
        final destination = Directory('${root.path}/out')..createSync();
        final existing = File('${destination.path}/lecture_001.mp4')
          ..writeAsStringSync('keep');
        File('${destination.path}/lecture_001 (2).mp4.txt')
            .writeAsStringSync('keep sidecar');
        final saved = await copyVideoBatch(
          [
            NamedVideoExport(source, 'lecture_001.mp4'),
            NamedVideoExport(source, 'lecture_001.mp4'),
          ],
          destination,
          token: CancellationToken(),
          progress: (_) {},
        );
        expect(saved.map((p) => p.split('/').last), [
          'lecture_001 (3).mp4',
          'lecture_001 (4).mp4',
        ]);
        expect(await existing.readAsString(), 'keep');
        for (final path in saved) {
          expect(await File(path).readAsBytes(), [1, 2, 3]);
          expect(await File('$path.txt').readAsString(), 'license notice');
        }
        final token = CancellationToken();
        await expectLater(
          copyVideoBatch(
            [NamedVideoExport(source, 'cancelled')],
            destination,
            token: token,
            progress: (_) => token.cancel(),
          ),
          throwsA(isA<ExportCancelled>()),
        );
        expect(await File('${destination.path}/cancelled.mp4').exists(), false);
        expect(
          await File('${destination.path}/cancelled.mp4.txt').exists(),
          false,
        );
        expect(await existing.readAsString(), 'keep');
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
}
