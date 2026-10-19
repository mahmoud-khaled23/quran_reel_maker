import 'package:quran_reel_maker/features/audio_editor/time_format.dart';

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';
import 'package:quran_reel_maker/app.dart';
import 'package:quran_reel_maker/core/app_services.dart';
import 'package:quran_reel_maker/features/quran_text/quran_repository.dart';
import 'package:quran_reel_maker/features/synchronization/alignment_engine.dart';
import 'package:quran_reel_maker/features/synchronization/android_alignment_engine.dart';
import 'package:quran_reel_maker/features/synchronization/ayah_timeline.dart';
import 'package:quran_reel_maker/media_engine/media_engine.dart';
import 'package:quran_reel_maker/services/project_store.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'real local aligner reviews, edits, saves and exports a nonzero trim',
    (tester) async {
      if (Platform.isAndroid &&
          !const bool.fromEnvironment('QRM_ALIGNMENT_BENCHMARK')) {
        throw StateError('Android tests require the isolated benchmark ID.');
      }
      MediaKit.ensureInitialized();
      final root = await Directory.systemTemp.createTemp('qrm_alignment_ui_');
      final store = ProjectStore(Directory('${root.path}/projects'));
      final engine = createMediaEngine();
      final quran = await QuranRepository.load();
      final support = Platform.isAndroid
          ? await getApplicationSupportDirectory()
          : null;
      try {
        final original = await store.create();
        final audio = await store.importFile(
          original.id,
          support == null
              ? File('test/fixtures/alignment/fatiha-cc0.ogg').absolute
              : File('${support.path}/alignment-test.ogg'),
          'audio',
        );
        final image = '${root.path}/background.png';
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
          image,
        ]);
        final background = await store.importFile(
          original.id,
          File(image),
          'background',
        );
        final seeded = original.copyWith(
          title: 'Alignment fixture',
          audio: audio,
          audioDuration: 92.72,
          trimStart: 14,
          trimEnd: 27,
          background: background,
          cues: manualTimingGrid(
            surah: 1,
            first: 2,
            last: 3,
            start: 14,
            end: 27,
          ),
        );
        await store.save(seeded);
        if (support == null) {
          await File('${root.path}/alignment-worker-path.txt')
              .writeAsString(File('scripts/alignment-worker.sh').absolute.path);
        }
        final services = AppServices(
          store: store,
          quran: quran,
          engine: engine,
          exports: Directory('${root.path}/exports'),
          alignment: support == null
              ? const ProcessAlignmentEngine()
              : AndroidAlignmentEngine(
                  media: engine,
                  quran: quran,
                  model: AlignmentModelStore(
                    Directory(
                      '${support.path}/alignment-models/${ProcessAlignmentEngine.model}',
                    ),
                  ),
                ),
        );
        await tester.pumpWidget(
          ProviderScope(
            overrides: [servicesProvider.overrideWithValue(services)],
            child: const QuranReelApp(),
          ),
        );
        Future<void> idle() async {
          final deadline = DateTime.now().add(const Duration(minutes: 3));
          do {
            await tester.pump(const Duration(milliseconds: 200));
            if (!tester.any(find.byType(LinearProgressIndicator)) &&
                !tester.any(find.byType(CircularProgressIndicator))) {
              return;
            }
          } while (DateTime.now().isBefore(deadline));
          fail('Editor operation exceeded three minutes.');
        }

        Future<void> tap(String label) async {
          debugPrint('Alignment UI test: $label');
          final target = find.text(label);
          await tester.ensureVisible(target);
          await tester.pump(const Duration(milliseconds: 350));
          await tester.tap(target);
          await idle();
        }

        await idle();
        debugPrint('Alignment UI test: open seeded project');
        // Opening the seeded project also restores its selected ayah range.
        await tester.tap(find.text('Projects'));
        // The editor stays busy while this modal is open; do not wait for its
        // indeterminate progress indicator to settle.
        for (var i = 0; i < 50 && !tester.any(find.byType(AlertDialog)); i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(find.byType(AlertDialog), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.text('Alignment fixture'));
        await idle();
        debugPrint('Alignment UI test: project opened');
        await tap('Align automatically');
        final container = ProviderScope.containerOf(
          tester.element(find.byType(QuranReelApp)),
        );
        final aligned = container.read(editorProvider)!;
        expect(aligned.cues, hasLength(2));
        expect(
          aligned.cues.every((c) => c.timingSource == 'automatic'),
          isTrue,
        );
        expect(aligned.cues.first.start, inInclusiveRange(14.4, 15.7));
        expect(aligned.cues.last.end, inInclusiveRange(25.4, 26.8));
        expect(aligned.cues.first.words, hasLength(4));
        expect(aligned.reviewed, isFalse);
        expect(find.byType(AyahTimeline), findsOneWidget);
        expect(find.text('Rerun alignment'), findsOneWidget);
        // Exercise playback seeking and word review without assuming audible output.
        await tester.ensureVisible(find.byTooltip('Seek to ayah').first);
        await tester.tap(find.byTooltip('Seek to ayah').first);
        await idle();
        final boundaries = find.text('Word boundaries · tap to seek').first;
        await tester.ensureVisible(boundaries);
        await tester.tap(boundaries);
        await tester.pumpAndSettle();
        expect(find.byType(ActionChip), findsWidgets);
        await tap('I reviewed the ayahs and their timing');
        await tap('Save');
        expect((await store.load(aligned.id)).reviewed, isTrue);
        final end = find.widgetWithText(TextField, 'End').first;
        await tester.ensureVisible(end);
        await tester.enterText(end, timeLabel(aligned.cues.first.end - 0.05));
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await idle();
        expect(container.read(editorProvider)!.reviewed, isFalse);
        expect(container.read(editorProvider)!.cues.first.words, isEmpty);
        await tap('I reviewed the ayahs and their timing');
        await tester.ensureVisible(find.text('Export MP4'));
        await tester.tap(find.text('Export MP4'));
        for (var i = 0; i < 50 && !tester.any(find.text('Render MP4')); i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.text('Render MP4'));
        await idle();
        final output =
            (await services.exports
                    .list()
                    .where((f) => f.path.endsWith('.mp4'))
                    .toList())
                .single;
        expect((await engine.inspect(output.path)).duration, closeTo(13, 0.1));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      } finally {
        await root.delete(recursive: true);
      }
    },
    skip: !const bool.fromEnvironment('QRM_REAL_ALIGNMENT'),
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
