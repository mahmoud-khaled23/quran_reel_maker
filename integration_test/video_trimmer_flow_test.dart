import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:quran_reel_maker/app.dart';
import 'package:quran_reel_maker/core/app_services.dart';
import 'package:quran_reel_maker/features/quran_text/quran_repository.dart';
import 'package:quran_reel_maker/media_engine/media_engine.dart';
import 'package:quran_reel_maker/services/project_store.dart';

import 'editor_flow_test.dart' show FixturePicker;

class TrimmerPicker extends FixturePicker {
  TrimmerPicker(super.paths, this.folder);
  final String folder;
  @override
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    bool lockParentWindow = false,
    String? initialDirectory,
  }) async => folder;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native standalone video select, preview, split, rename and save',
    (tester) async {
      MediaKit.ensureInitialized();
      final root = await Directory.systemTemp.createTemp('qrm_trimmer_ui_');
      final engine = createMediaEngine();
      final picker = FilePicker.platform;
      Future<void> idle() async {
        final deadline = DateTime.now().add(const Duration(seconds: 60));
        do {
          await tester.pump(const Duration(milliseconds: 200));
          if (!tester.any(find.byType(LinearProgressIndicator)) &&
              !tester.any(find.byType(CircularProgressIndicator))) {
            return;
          }
        } while (DateTime.now().isBefore(deadline));
        fail('Trimmer operation did not complete within 60 seconds.');
      }

      try {
        final source = File('${root.path}/lecture_recording.mp4');
        await engine.run([
          '-y',
          '-v',
          'error',
          '-f',
          'lavfi',
          '-i',
          'testsrc2=s=320x240:r=20:d=3.7',
          '-f',
          'lavfi',
          '-i',
          'sine=duration=3.7',
          '-c:v',
          await engine.encoder(),
          '-g',
          '300',
          '-c:a',
          'aac',
          '-threads',
          '1',
          source.path,
        ]);
        final original = await source.readAsBytes();
        final folder = Directory('${root.path}/saved')..createSync();
        final existing = File('${folder.path}/Z first.mp4')
          ..writeAsStringSync('keep');
        FilePicker.platform = TrimmerPicker([source.path], folder.path);
        final services = AppServices(
          store: ProjectStore(Directory('${root.path}/projects')),
          quran: await QuranRepository.load(),
          engine: engine,
          exports: Directory('${root.path}/exports'),
        );
        await tester.pumpWidget(
          ProviderScope(
            overrides: [servicesProvider.overrideWithValue(services)],
            child: const RepaintBoundary(
              key: Key('trimmer-evidence'),
              child: QuranReelApp(),
            ),
          ),
        );
        await idle();
        final container = ProviderScope.containerOf(
          tester.element(find.byType(QuranReelApp)),
        );
        final originalProject = container.read(editorProvider);
        Future<void> screenshot(String name) async {
          const evidence = String.fromEnvironment('MEDIA_EVIDENCE');
          if (evidence.isEmpty) return;
          await tester.pump();
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const Key('trimmer-evidence')),
          );
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory(evidence).create(recursive: true);
          await File('$evidence/$name.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        }

        await tester.tap(find.text('Video Trimmer'));
        await idle();
        await tester.tap(find.text('Select video'));
        await idle();
        expect(
          tester
              .widget<TextField>(find.widgetWithText(TextField, 'Project name'))
              .controller!
              .text,
          'lecture_recording',
        );
        final scroll = find
            .descendant(
              of: find.byKey(const Key('trimmer-scroll')),
              matching: find.byType(Scrollable),
            )
            .first;
        Future<void> reveal(Finder finder, double delta) async {
          await tester.scrollUntilVisible(finder, delta, scrollable: scroll);
          await Scrollable.ensureVisible(
            tester.element(finder),
            alignment: 0.5,
          );
          await tester.pump(const Duration(milliseconds: 200));
        }

        await tester.tap(find.byTooltip('Play video'));
        await idle();
        expect(find.byTooltip('Pause video'), findsOneWidget);
        await tester.tap(find.byTooltip('Pause video'));
        await idle();
        await screenshot('trimmer-source');
        await reveal(find.byType(DropdownButtonFormField<double>), 300);
        await tester.tap(find.byType(DropdownButtonFormField<double>));
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.text('Custom seconds').last);
        await tester.pump(const Duration(milliseconds: 300));
        await tester.enterText(
          find.widgetWithText(TextField, 'Custom duration in seconds'),
          '1.25',
        );
        await tester.pump();
        await reveal(find.text('1. lecture_recording_001.mp4'), 300);
        await tester.tap(find.text('Rename').first);
        await tester.pump(const Duration(milliseconds: 300));
        await tester.enterText(
          find.widgetWithText(TextField, 'Filename without .mp4'),
          'Z first',
        );
        await tester.tap(find.text('Apply name'));
        await tester.pump(const Duration(milliseconds: 300));
        final title = find.widgetWithText(TextField, 'Project name');
        await reveal(title, -300);
        await tester.enterText(title, 'Renamed project');
        await tester.pump();
        await reveal(find.text('Process segments'), 300);
        await tester.tap(find.text('Process segments'));
        await idle();
        expect(find.text('3 generated segments'), findsOneWidget);
        await screenshot('trimmer-segments');
        await reveal(find.text('1. Z first.mp4'), 300);
        await tester.tap(find.text('Preview').first);
        await idle();
        await reveal(find.text('Generated segment 1'), -300);
        await tester.tap(find.byTooltip('Play video'));
        await idle();
        expect(find.byTooltip('Pause video'), findsOneWidget);
        await tester.tap(find.byTooltip('Pause video'));
        await idle();
        await reveal(find.text('Save all segments…'), 300);
        await tester.tap(find.text('Save all segments…'));
        await idle();
        expect(find.textContaining('Saved 3 segments:'), findsOneWidget);
        for (final name in [
          'Z first (2).mp4',
          'Renamed project_002.mp4',
          'Renamed project_003.mp4',
        ]) {
          final info = await engine.inspect('${folder.path}/$name');
          expect(info.hasVideo && info.hasAudio, true);
        }
        expect(await existing.readAsString(), 'keep');
        expect(await source.readAsBytes(), original);
        expect(container.read(editorProvider), same(originalProject));
        await tester.pageBack();
        await idle();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(milliseconds: 500));
        expect(await services.exports.list().length, 0);
      } finally {
        FilePicker.platform = picker;
        await root.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
