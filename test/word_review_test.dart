import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quran_reel_maker/features/media_editor/trim_dialog.dart';
import 'package:quran_reel_maker/features/synchronization/word_timing_dialog.dart';
import 'package:quran_reel_maker/models/reel_project.dart';

void main() {
  testWidgets(
    'manual word review rejects empty fields and saves exact selected boundaries without scores',
    (tester) async {
      AyahCue? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                child: const Text('Open'),
                onPressed: () async {
                  saved = await showDialog<AyahCue>(
                    context: context,
                    builder: (_) => const WordTimingDialog(
                      cue: AyahCue(
                        surah: 1,
                        ayah: 2,
                        start: 10,
                        end: 20,
                        firstWord: 1,
                        lastWord: 2,
                      ),
                      verse: 'أَوَّلٌ ثَانٍ ثَالِثٌ رَابِعٌ',
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save word timings'));
      await tester.pump();
      expect(saved, isNull);
      expect(find.textContaining('Empty fields cannot become'), findsOneWidget);
      final starts = find.widgetWithText(TextField, 'Word start');
      final ends = find.widgetWithText(TextField, 'Word end');
      await tester.enterText(starts.at(0), '00:00:10:100');
      await tester.enterText(ends.at(0), '00:00:12:500');
      await tester.enterText(starts.at(1), '00:00:13:000');
      await tester.enterText(ends.at(1), '00:00:19:500');
      await tester.tap(find.text('Save word timings'));
      await tester.pumpAndSettle();
      expect(saved!.words.map((w) => w.index), [1, 2]);
      expect(saved!.words.first.start, 10.1);
      expect(saved!.words.last.end, 19.5);
      expect(saved!.words.every((w) => w.score == null), isTrue);
      expect(saved!.firstWord, 1);
      expect(saved!.lastWord, 2);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'unchanged acoustic word boundaries keep source precision on review',
    (tester) async {
      AyahCue? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                child: const Text('Open'),
                onPressed: () async {
                  saved = await showDialog<AyahCue>(
                    context: context,
                    builder: (_) => const WordTimingDialog(
                      cue: AyahCue(
                        surah: 1,
                        ayah: 1,
                        start: 1 / 3,
                        end: 2 / 3,
                        words: [
                          WordCue(
                            index: 0,
                            start: 1 / 3,
                            end: 2 / 3,
                            score: 0.7,
                          ),
                        ],
                      ),
                      verse: 'أَوَّلٌ',
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save word timings'));
      await tester.pumpAndSettle();
      expect(saved!.words.single.start, 1 / 3);
      expect(saved!.words.single.end, 2 / 3);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'trim dialog retains manual selection when playback dependency is unavailable',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      RangeValues? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                child: const Text('Open'),
                onPressed: () async {
                  saved = await showDialog<RangeValues>(
                    context: context,
                    builder: (_) => const MediaTrimDialog(
                      path: '/unused',
                      duration: 100,
                      video: false,
                      playbackError: 'Install playback dependency.',
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.text('Install playback dependency.'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextField, 'Selection start'),
        '00:00:05:250',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      await tester.enterText(
        find.widgetWithText(TextField, 'Selection end'),
        '00:01:23:045',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      await tester.tap(find.text('Use selection'));
      await tester.pumpAndSettle();
      expect(saved!.start, 5.25);
      expect(saved!.end, 83.045);
      expect(tester.takeException(), isNull);
      await tester.binding.setSurfaceSize(null);
    },
  );
}
