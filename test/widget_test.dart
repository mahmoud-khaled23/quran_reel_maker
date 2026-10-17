import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quran_reel_maker/app.dart';
import 'package:quran_reel_maker/core/app_services.dart';
import 'package:quran_reel_maker/features/quran_text/quran_repository.dart';
import 'package:quran_reel_maker/media_engine/media_engine.dart';
import 'package:quran_reel_maker/models/reel_project.dart';
import 'package:quran_reel_maker/services/project_store.dart';

class FixtureEditor extends EditorController {
  @override
  ReelProject build() => const ReelProject(id: 'widget-test');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final size in [const Size(1366, 900), const Size(390, 844)]) {
    testWidgets('editor starts without overflow at $size', (tester) async {
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
              editorProvider.overrideWith(FixtureEditor.new),
            ],
            child: const QuranReelApp(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Quran Reel Maker'), findsOneWidget);
      expect(find.text('Import audio'), findsOneWidget);
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
          await File('$evidence/editor-${size.width.toInt()}.png')
              .writeAsBytes(png!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.pumpWidget(const SizedBox());
      await tester.binding.setSurfaceSize(null);
      await tester.runAsync(() => root.delete(recursive: true));
    });
  }
}
