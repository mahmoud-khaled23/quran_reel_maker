import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quran_reel_maker/app.dart';
import 'package:quran_reel_maker/core/app_services.dart';
import 'package:quran_reel_maker/features/quran_text/quran_repository.dart';
import 'package:quran_reel_maker/media_engine/media_engine.dart';
import 'package:quran_reel_maker/models/reel_project.dart';
import 'package:quran_reel_maker/services/project_store.dart';

import '../integration_test/editor_flow_test.dart' show FixturePicker;

class MetadataEngine extends MediaEngine {
  @override
  Future<String> run(
    List<String> arguments, {
    bool probe = false,
    CancellationToken? token,
    void Function(double)? onTime,
  }) async {
    expect(probe, true, reason: 'Planning must not render a Quran reel.');
    return jsonEncode({
      'format': {'duration': '120', 'start_time': '0'},
      'streams': [
        {
          'codec_type': 'video',
          'codec_name': 'h264',
          'width': 640,
          'height': 480,
          'avg_frame_rate': '30/1',
        },
      ],
    });
  }
}

class EmptyEditor extends EditorController {
  @override
  ReelProject build() => const ReelProject(id: 'untouched');
}

void main() {
  FilePicker.platform = FixturePicker([]);
  for (final size in [const Size(1366, 900), const Size(390, 844)]) {
    testWidgets(
      'independent trimmer navigation, names, presets and validation at $size',
      (tester) async {
        late Directory root;
        late QuranRepository quran;
        await tester.runAsync(() async {
          root = await Directory.systemTemp.createTemp('qrm_trimmer_widget_');
          quran = await QuranRepository.load();
          await (FontLoader(
            'NotoSans',
          )..addFont(rootBundle.load('assets/fonts/NotoSans.ttf'))).load();
          await File('${root.path}/lecture_recording.mp4')
              .writeAsString('fixture');
        });
        final picker = FilePicker.platform;
        FilePicker.platform = FixturePicker([
          '${root.path}/lecture_recording.mp4',
        ]);
        await tester.binding.setSurfaceSize(size);
        try {
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                editorProvider.overrideWith(EmptyEditor.new),
                servicesProvider.overrideWithValue(
                  AppServices(
                    store: ProjectStore(root),
                    quran: quran,
                    engine: MetadataEngine(),
                    exports: root,
                    playbackError: 'Native playback disabled in widget test.',
                  ),
                ),
              ],
              child: const QuranReelApp(),
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text('Video Trimmer'));
          await tester.pumpAndSettle();
          expect(find.text('Select video'), findsOneWidget);
          await tester.runAsync(() async {
            await tester.tap(find.text('Select video'));
            await Future<void>.delayed(const Duration(milliseconds: 100));
          });
          await tester.pumpAndSettle();
          final title = find.widgetWithText(TextField, 'Project name');
          expect(
            tester.widget<TextField>(title).controller!.text,
            'lecture_recording',
          );
          final scroll = find
              .descendant(
                of: find.byKey(const Key('trimmer-scroll')),
                matching: find.byType(Scrollable),
              )
              .first;
          Future<void> reveal(Finder target, double delta) async {
            await tester.scrollUntilVisible(target, delta, scrollable: scroll);
            await Scrollable.ensureVisible(
              tester.element(target),
              alignment: 0.5,
            );
            await tester.pumpAndSettle();
          }

          await reveal(find.text('4 expected segments'), 300);
          for (final value in [60, 90, 30]) {
            await reveal(find.byType(DropdownButtonFormField<double>), -300);
            await tester.tap(find.byType(DropdownButtonFormField<double>));
            await tester.pumpAndSettle();
            await tester.tap(find.text('$value seconds').last);
            await tester.pumpAndSettle();
            expect(
              find.text('${value == 30 ? 4 : 2} expected segments'),
              findsOneWidget,
            );
          }
          await reveal(find.text('1. lecture_recording_001.mp4'), 300);
          await tester.tap(find.text('Rename').first);
          await tester.pumpAndSettle();
          await tester.enterText(
            find.widgetWithText(TextField, 'Filename without .mp4'),
            'Z custom',
          );
          await tester.tap(find.text('Apply name'));
          await tester.pumpAndSettle();
          await reveal(title, -300);
          await tester.enterText(title, 'new:/project');
          await tester.pumpAndSettle();
          await reveal(find.text('1. Z custom.mp4'), 300);
          expect(find.text('1. Z custom.mp4'), findsOneWidget);
          await reveal(find.text('2. new__project_002.mp4'), 300);
          await reveal(title, -300);
          await tester.enterText(title, '');
          await tester.pumpAndSettle();
          await reveal(find.text('Enter a nonempty name.'), 300);
          expect(
            tester
                .widget<FilledButton>(
                  find.widgetWithText(FilledButton, 'Process segments'),
                )
                .onPressed,
            isNull,
          );
          await reveal(title, -300);
          await tester.enterText(title, 'Restored');
          await reveal(find.byType(DropdownButtonFormField<double>), 300);
          await tester.tap(find.byType(DropdownButtonFormField<double>));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Custom seconds').last);
          await tester.pumpAndSettle();
          final duration = find.widgetWithText(
            TextField,
            'Custom duration in seconds',
          );
          await tester.ensureVisible(duration);
          await tester.enterText(duration, '-1');
          await tester.pumpAndSettle();
          expect(
            find.text('Enter a finite, positive duration in seconds.'),
            findsOneWidget,
          );
          await tester.enterText(duration, '12.5');
          await tester.pumpAndSettle();
          expect(find.text('10 expected segments'), findsOneWidget);
          final container = ProviderScope.containerOf(
            tester.element(find.byType(QuranReelApp)),
          );
          expect(container.read(editorProvider)!.id, 'untouched');
          expect(container.read(editorProvider)!.audio, isNull);
          expect(tester.takeException(), isNull);
          await tester.pageBack();
          await tester.pumpAndSettle();
          expect(find.text('Video Trimmer'), findsOneWidget);
        } finally {
          FilePicker.platform = picker;
          await tester.pumpWidget(const SizedBox());
          await tester.binding.setSurfaceSize(null);
          await tester.runAsync(() => root.delete(recursive: true));
        }
      },
    );
  }
}
