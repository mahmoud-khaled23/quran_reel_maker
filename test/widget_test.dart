import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quran_reel_maker/app.dart';
import 'package:quran_reel_maker/core/app_services.dart';
import 'package:quran_reel_maker/features/preview/ayah_painter.dart';
import 'package:quran_reel_maker/features/quran_text/quran_repository.dart';
import 'package:quran_reel_maker/media_engine/media_engine.dart';
import 'package:quran_reel_maker/models/reel_project.dart';
import 'package:quran_reel_maker/services/project_store.dart';

class FixtureEditor extends EditorController {
  @override
  ReelProject build() => const ReelProject(id: 'widget-test');
}

class AlignedFixtureEditor extends EditorController {
  @override
  ReelProject build() => const ReelProject(
    id: 'aligned-widget',
    audio: 'media/audio.ogg',
    audioDuration: 70,
    trimStart: 60,
    trimEnd: 64,
    cues: [
      AyahCue(
        surah: 1,
        ayah: 2,
        start: 61,
        end: 63,
        timingSource: 'automatic',
        alignmentModel: 'quran-ctc-q4-v1',
        alignmentScore: 0.7,
        warnings: [
          'Automatic draft: listen to every boundary before export. Acoustic scores are not accuracy probabilities.',
        ],
        words: [WordCue(index: 0, start: 61, end: 63, score: 0.7)],
      ),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Fit centers the background after crop focus changes, matching export',
    (tester) async {
      late Directory root;
      late QuranRepository quran;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('qrm_fit_');
        quran = await QuranRepository.load();
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            servicesProvider.overrideWithValue(
              AppServices(
                store: ProjectStore(root),
                quran: quran,
                engine: ProcessMediaEngine(),
                exports: root,
                playbackError: 'Playback disabled for widget tests.',
              ),
            ),
            editorProvider.overrideWith(FixtureEditor.new),
          ],
          child: const QuranReelApp(),
        ),
      );
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(QuranReelApp)),
      );
      final changed = container
          .read(editorProvider)!
          .copyWith(background: 'media/missing.png', cropX: 0, cropY: 1);
      container.read(editorProvider.notifier).edit(changed);
      await tester.pumpAndSettle();
      expect(
        tester.widget<Image>(find.byType(Image)).alignment,
        const Alignment(-1, 1),
      );
      container
          .read(editorProvider.notifier)
          .edit(changed.copyWith(fit: BackgroundFit.contain));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Image>(find.byType(Image)).alignment,
        Alignment.center,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => root.delete(recursive: true));
    },
  );

  for (final size in [const Size(1366, 900), const Size(390, 844)]) {
    testWidgets(
      'drag and color controls update the shared painter and saved project at $size',
      (tester) async {
        late Directory root;
        late QuranRepository quran;
        await tester.runAsync(() async {
          root = await Directory.systemTemp.createTemp('qrm_style_');
          quran = await QuranRepository.load();
          await File('${root.path}/widget-test/media/audio.ogg')
              .create(recursive: true);
          await (FontLoader(
            'NotoSans',
          )..addFont(rootBundle.load('assets/fonts/NotoSans.ttf'))).load();
          await (FontLoader(
            'AmiriQuran',
          )..addFont(rootBundle.load('assets/fonts/AmiriQuran.ttf'))).load();
        });
        final store = ProjectStore(root);
        await tester.binding.setSurfaceSize(size);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              servicesProvider.overrideWithValue(
                AppServices(
                  store: store,
                  quran: quran,
                  engine: ProcessMediaEngine(),
                  exports: root,
                  playbackError: 'Playback disabled for widget tests.',
                ),
              ),
              editorProvider.overrideWith(FixtureEditor.new),
            ],
            child: const QuranReelApp(),
          ),
        );
        final container = ProviderScope.containerOf(
          tester.element(find.byType(QuranReelApp)),
        );
        container
            .read(editorProvider.notifier)
            .edit(
              const ReelProject(
                id: 'widget-test',
                audio: 'media/audio.ogg',
                audioDuration: 3,
                trimEnd: 3,
                cues: [
                  AyahCue(surah: 1, ayah: 1, start: 0, end: 3, lastWord: 0),
                ],
              ),
            );
        await tester.pumpAndSettle();
        final canvas = find.byWidgetPredicate(
          (w) => w is CustomPaint && w.painter is AyahPainter,
        );
        AyahPainter painter() =>
            tester.widget<CustomPaint>(canvas).painter! as AyahPainter;
        expect(painter().text, isNotEmpty);
        await tester.ensureVisible(canvas);
        await tester.timedDrag(
          canvas,
          const Offset(48, 64),
          const Duration(milliseconds: 400),
        );
        await tester.pumpAndSettle();
        final moved = container.read(editorProvider)!;
        expect(moved.overlayX, greaterThan(0.5));
        expect(moved.overlayY, greaterThan(0.58));
        expect(painter().x, moved.overlayX);
        expect(painter().y, moved.overlayY);
        await tester.ensureVisible(find.text('Text position & color'));
        await tester.tap(find.text('Text position & color'));
        await tester.pumpAndSettle();
        final gold = find.byWidgetPredicate(
          (w) =>
              w is ChoiceChip &&
              w.label is Icon &&
              (w.label as Icon).color == const Color(0xFFFFD77A),
        );
        await tester.ensureVisible(gold);
        await tester.tap(gold);
        await tester.pumpAndSettle();
        expect(painter().fontColor, 0xFFFFD77A);
        await tester.ensureVisible(find.text('Text background'));
        await tester.tap(find.text('Text background'));
        await tester.pumpAndSettle();
        expect(painter().textBackground, isFalse);
        await tester.runAsync(() async {
          await container.read(editorProvider.notifier).save();
          final saved = (await store.list()).single;
          expect(saved.overlayX, moved.overlayX);
          expect(saved.overlayY, moved.overlayY);
          expect(saved.fontColor, 0xFFFFD77A);
          expect(saved.textBackground, isFalse);
        });
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.binding.setSurfaceSize(null);
        await tester.runAsync(() => root.delete(recursive: true));
      },
    );
  }

  for (final (size, aligned) in [
    (const Size(1366, 900), false),
    (const Size(390, 844), false),
    (const Size(1366, 900), true),
    (const Size(390, 844), true),
  ]) {
    testWidgets('editor starts without overflow at $size, aligned=$aligned', (
      tester,
    ) async {
      late Directory root;
      late QuranRepository quran;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('qrm_widget_');
        quran = await QuranRepository.load();
        await (FontLoader(
          'NotoSans',
        )..addFont(rootBundle.load('assets/fonts/NotoSans.ttf'))).load();
        await (FontLoader(
          'AmiriQuran',
        )..addFont(rootBundle.load('assets/fonts/AmiriQuran.ttf'))).load();
        await (FontLoader(
          'MaterialIcons',
        )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
      });
      await tester.binding.setSurfaceSize(size);
      final boundary = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: ProviderScope(
            overrides: [
              servicesProvider.overrideWithValue(
                AppServices(
                  store: ProjectStore(root),
                  quran: quran,
                  engine: ProcessMediaEngine(),
                  exports: root,
                  playbackError: 'Playback disabled for widget tests.',
                ),
              ),
              editorProvider.overrideWith(
                aligned ? AlignedFixtureEditor.new : FixtureEditor.new,
              ),
            ],
            child: const QuranReelApp(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Quran Reel Maker'), findsOneWidget);
      expect(
        find.text(aligned ? 'Replace audio' : 'Import audio'),
        findsOneWidget,
      );
      if (aligned) {
        final words = find.text('Word boundaries · tap to seek');
        await tester.ensureVisible(words);
        await tester.tap(words);
        await tester.pumpAndSettle();
        expect(find.byType(ActionChip), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
      const evidence = String.fromEnvironment('MEDIA_EVIDENCE');
      if (evidence.isNotEmpty) {
        await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage();
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory(evidence).create(recursive: true);
          await File(
            '$evidence/editor-${size.width.toInt()}${aligned ? "-aligned" : ""}.png',
          ).writeAsBytes(png!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.pumpWidget(const SizedBox());
      await tester.binding.setSurfaceSize(null);
      await tester.runAsync(() => root.delete(recursive: true));
    });
  }
}
