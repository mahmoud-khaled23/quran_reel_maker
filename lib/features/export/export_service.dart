import 'dart:io';
import 'dart:ui' as ui;

import 'package:path/path.dart' as p;

import '../../media_engine/media_engine.dart';
import '../../models/reel_project.dart';
import '../preview/ayah_painter.dart';
import '../quran_text/quran_repository.dart';
import 'export_plan.dart';

class ExportService {
  ExportService(this.engine, this.quran);
  final MediaEngine engine;
  final QuranRepository quran;
  Future<File> export(
    ReelProject project,
    Directory projectDirectory,
    Directory outputDirectory, {
    required CancellationToken token,
    required void Function(double) progress,
  }) async {
    final errors = project.validate(forExport: true);
    if (errors.isNotEmpty) throw MediaFailure(errors.join('\n'));
    final audio = File(p.join(projectDirectory.path, project.audio!));
    final background = File(p.join(projectDirectory.path, project.background!));
    if (!await audio.exists() || !await background.exists()) {
      throw MediaFailure('Source media is missing. Reimport it.');
    }
    token.check();
    final encoder = await engine.encoder();
    token.check();
    await outputDirectory.create(recursive: true);
    final workspace = await outputDirectory.createTemp('render_');
    try {
      final timeline = overlayTimeline(project);
      final rendered = <int?>{};
      String filename(int? index) =>
          index == null ? 'blank.png' : 'ayah_$index.png';
      for (final span in timeline) {
        token.check();
        if (!rendered.add(span.cueIndex)) continue;
        final cue = span.cueIndex == null ? null : project.cues[span.cueIndex!];
        final painter = AyahPainter(
          text: cue == null ? null : quran.verse(cue.surah, cue.ayah),
          reference: cue == null
              ? null
              : '${quran.surahs[cue.surah - 1].name} · ${cue.surah}:${cue.ayah}',
          attribution: project.cues.isNotEmpty,
        );
        final image = await painter.rasterize();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        if (bytes == null) {
          throw MediaFailure('Could not render Arabic overlay.');
        }
        await File(
          p.join(workspace.path, filename(span.cueIndex)),
        ).writeAsBytes(
          bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        );
        progress(0.15 * rendered.length / timeline.length);
      }
      // Only internally generated basenames enter the concat grammar.
      final concat = StringBuffer('ffconcat version 1.0\n');
      for (final span in timeline) {
        concat.writeln("file '${filename(span.cueIndex)}'");
        concat.writeln('option framerate 30');
        concat.writeln('duration ${span.duration.toStringAsFixed(9)}');
      }
      concat.writeln("file '${filename(timeline.last.cueIndex)}'");
      concat.writeln('option framerate 30');
      final list = File(p.join(workspace.path, 'overlays.ffconcat'));
      await list.writeAsString(concat.toString());
      token.check();
      final temporary = File(p.join(workspace.path, 'video.mp4'));
      await engine.run(
        exportArguments(
          project: project,
          audio: audio.path,
          background: background.path,
          overlayList: list.path,
          output: temporary.path,
          encoder: encoder,
          copyright: quran.copyright,
        ),
        token: token,
        onTime: (seconds) =>
            progress(0.15 + 0.84 * (seconds / project.duration).clamp(0, 1)),
      );
      token.check();
      final result = File(
        p.join(
          outputDirectory.path,
          'reel_${DateTime.now().microsecondsSinceEpoch}.mp4',
        ),
      );
      await temporary.rename(result.path);
      await File('${result.path}.txt').writeAsString(
        'Quran Reel Maker\nArabic font: Amiri Quran 1.003 (SIL OFL 1.1).\n'
        'Quran source: https://tanzil.net/\n${quran.copyright}\n',
      );
      progress(1);
      return result;
    } finally {
      if (await workspace.exists()) await workspace.delete(recursive: true);
    }
  }
}
