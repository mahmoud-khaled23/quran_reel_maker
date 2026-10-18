import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:quran_reel_maker/app.dart';
import 'package:quran_reel_maker/core/app_services.dart';
import 'package:quran_reel_maker/features/quran_text/quran_repository.dart';
import 'package:quran_reel_maker/media_engine/media_engine.dart';
import 'package:quran_reel_maker/models/reel_project.dart';
import 'package:quran_reel_maker/services/project_store.dart';

// Only the OS dialog is replaced. Import, native players, probing, waveform,
// project storage, Arabic painting, and FFmpeg export use the real app services.
class FixturePicker extends FilePicker {
  FixturePicker(this.paths);
  final List<String> paths;
  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = false,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    final file = File(paths.removeAt(0));
    return FilePickerResult([
      PlatformFile(
        name: file.uri.pathSegments.last,
        path: file.path,
        size: await file.length(),
      ),
    ]);
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native editor imports, trims, times, saves, reopens and exports',
    (tester) async {
      Future<void> idle({bool allowDialog = false}) async {
        final deadline = DateTime.now().add(const Duration(seconds: 60));
        do {
          await tester.pump(const Duration(milliseconds: 200));
          if (allowDialog && tester.any(find.byType(AlertDialog))) return;
          if (!tester.any(find.byType(LinearProgressIndicator)) &&
              !tester.any(find.byType(CircularProgressIndicator))) {
            return;
          }
        } while (DateTime.now().isBefore(deadline));
        fail('Editor remained busy for 60 seconds.');
      }

      MediaKit.ensureInitialized();
      final root = await Directory.systemTemp.createTemp('qrm_ui_');
      final engine = createMediaEngine();
      final picker = FilePicker.platform;
      try {
        await engine.run([
          '-y',
          '-v',
          'error',
          '-f',
          'lavfi',
          '-i',
          'sine=frequency=440:duration=4',
          '${root.path}/audio.wav',
        ]);
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
          '${root.path}/bg.png',
        ]);
        await engine.run([
          '-y',
          '-v',
          'error',
          '-loop',
          '1',
          '-i',
          '${root.path}/bg.png',
          '-t',
          '3',
          '-c:v',
          await engine.encoder(),
          '-pix_fmt',
          'yuv420p',
          '-threads',
          '1',
          '${root.path}/bg.mp4',
        ]);
        FilePicker.platform = FixturePicker([
          '${root.path}/audio.wav',
          '${root.path}/bg.png',
          '${root.path}/bg.mp4',
        ]);
        final services = AppServices(
          store: ProjectStore(Directory('${root.path}/projects')),
          quran: await QuranRepository.load(),
          engine: engine,
          exports: Directory('${root.path}/exports'),
        );
        await tester.pumpWidget(
          ProviderScope(
            overrides: [servicesProvider.overrideWithValue(services)],
            child: const QuranReelApp(),
          ),
        );
        await idle();
        Future<void> tapText(String text) async {
          debugPrint("UI test: $text");
          final target = tester.any(find.byType(AlertDialog))
              ? find.descendant(
                  of: find.byType(AlertDialog),
                  matching: find.text(text),
                )
              : find.text(text);
          await tester.ensureVisible(target);
          await tester.tap(target);
          await idle(
            allowDialog: [
              'Projects',
              'Import audio',
              'Import video',
            ].contains(text),
          );
        }

        await tapText('Import audio');
        await tester.pump(const Duration(milliseconds: 400));
        await tester.enterText(
          find.widgetWithText(TextField, 'Selection start'),
          '00:00:00:500',
        );
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump();
        for (var i = 0; i < 50; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          if (tester
                  .widget<IconButton>(
                    find.byWidgetPredicate(
                      (w) =>
                          w is IconButton &&
                          w.tooltip == 'Play selected segment',
                    ),
                  )
                  .onPressed !=
              null) {
            break;
          }
        }
        await tester.tap(find.byTooltip('Play selected segment'));
        await tester.pump(const Duration(milliseconds: 700));
        expect(find.byTooltip('Pause segment'), findsOneWidget);
        await tester.tap(find.byTooltip('Pause segment'));
        await tapText('Use selection');
        expect(find.text('Replace audio'), findsOneWidget);
        final trim = find.widgetWithText(TextField, 'Trim start');
        await tester.ensureVisible(trim);
        await tester.enterText(trim, '00:00:01:000');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await idle();
        await tapText('Import image');
        await tapText('Import video');
        await tester.pump(const Duration(milliseconds: 400));
        await tester.enterText(
          find.widgetWithText(TextField, 'Selection start'),
          '00:00:00:500',
        );
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump();
        await tester.enterText(
          find.widgetWithText(TextField, 'Selection end'),
          '00:00:01:500',
        );
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump();
        for (var i = 0; i < 50; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          if (tester
                  .widget<IconButton>(
                    find.byWidgetPredicate(
                      (w) =>
                          w is IconButton &&
                          w.tooltip == 'Play selected segment',
                    ),
                  )
                  .onPressed !=
              null) {
            break;
          }
        }
        await tester.ensureVisible(find.byTooltip('Play selected segment'));
        await tester.tap(find.byTooltip('Play selected segment'));
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byTooltip('Pause segment'), findsOneWidget);
        await tester.tap(find.byTooltip('Pause segment'));
        await tapText('Use selection');
        await tapText('Create manual timings');
        await tapText('I reviewed the ayahs and their timing');
        await tapText('Save');
        final saved = (await services.store.list()).single;
        expect(saved.trimStart, 1);
        expect(saved.videoTrimStart, 0.5);
        expect(saved.videoTrimEnd, 1.5);
        expect(saved.cues.length, 7);
        expect(saved.reviewed, isTrue);
        await File('${root.path}/audio.wav').delete();
        await File('${root.path}/bg.png').delete();
        await File('${root.path}/bg.mp4').delete();
        await tapText('Projects');
        await tapText(saved.title);
        // A legitimate saved timeline may contain different surahs. Opening it
        // must not put the single-surah dropdown outside its list of ayahs.
        final container = ProviderScope.containerOf(
          tester.element(find.byType(QuranReelApp)),
        );
        container
            .read(editorProvider.notifier)
            .edit(
              saved.copyWith(
                cues: const [
                  AyahCue(surah: 114, ayah: 6, start: 1, end: 2),
                  AyahCue(surah: 2, ayah: 286, start: 2, end: 4),
                ],
              ),
            );
        await tapText('Save');
        await tapText('Projects');
        await tapText(saved.title);
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.text('Export MP4'));
        await tester.tap(find.text('Export MP4'));
        for (var i = 0; i < 50 && !tester.any(find.text('Render MP4')); i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.text('Render MP4'));
        await idle();
        expect(find.text('Save exported video…'), findsOneWidget);
        final exports = await services.exports
            .list()
            .where((f) => f.path.endsWith('.mp4'))
            .toList();
        expect(exports, hasLength(1));
        expect(
          (await engine.inspect(exports.single.path)).duration,
          closeTo(3, 0.1),
        );
        await tapText('Split completed reel…');
        expect(find.text('Completed reel'), findsOneWidget);
        expect(find.text(exports.single.uri.pathSegments.last), findsOneWidget);
        expect(
          find.textContaining('Splitting the completed reel:'),
          findsOneWidget,
        );
        await tester.pageBack();
        await idle();
        expect(find.text('Save exported video…'), findsOneWidget);
        expect(await File(exports.single.path).exists(), true);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await idle();
      } finally {
        FilePicker.platform = picker;
        await root.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
