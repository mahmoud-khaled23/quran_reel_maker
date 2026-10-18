import 'dart:io';
import 'dart:ui' as ui;

import 'package:path/path.dart' as p;

import '../../media_engine/media_engine.dart';
import '../../models/reel_project.dart';
import '../preview/ayah_painter.dart';
import '../quran_text/quran_repository.dart';
import 'export_plan.dart';
import 'export_settings.dart';

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
    // Older projects lack video metadata. Probe it before selecting dimensions.
    if (project.videoBackground &&
        project.background != null &&
        project.videoDuration == 0) {
      final info = await engine.inspect(
        p.join(projectDirectory.path, project.background!),
      );
      project = project.copyWith(
        videoDuration: info.duration,
        videoTrimEnd: info.duration,
        backgroundWidth: info.width,
        backgroundHeight: info.height,
      );
    }
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
    late final Directory workspace;
    try {
      await outputDirectory.create(recursive: true);
      workspace = await outputDirectory.createTemp('render_');
    } on FileSystemException catch (error) {
      throw MediaFailure(
        'Cannot create the export folder. Check free storage and write permissions. ${error.osError?.message ?? error.message}',
      );
    }
    try {
      final timeline = overlayTimeline(project);
      final rendered = <String>{};
      final size = exportSize(project);
      String filename(OverlaySpan span) => '${span.key}.png';
      for (final span in timeline) {
        token.check();
        if (!rendered.add(span.key)) continue;
        final cue = span.cueIndex == null ? null : project.cues[span.cueIndex!];
        final painter = AyahPainter(
          text: cue == null
              ? null
              : span.state!.text(quran.verse(cue.surah, cue.ayah)),
          reference: cue == null
              ? null
              : '${quran.surahs[cue.surah - 1].name} · ${cue.surah}:${cue.ayah}',
          attribution: project.cues.isNotEmpty,
          outputSize: ui.Size(size.width.toDouble(), size.height.toDouble()),
          x: project.overlayX,
          y: project.overlayY,
          fontColor: project.fontColor,
          textBackground: project.textBackground,
        );
        final image = await painter.rasterize();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        if (bytes == null) {
          throw MediaFailure('Could not render Arabic overlay.');
        }
        await File(p.join(workspace.path, filename(span))).writeAsBytes(
          bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        );
        progress(0.15 * rendered.length / timeline.length);
      }
      // Only internally generated basenames enter the concat grammar.
      final concat = StringBuffer('ffconcat version 1.0\n');
      for (final span in timeline) {
        concat.writeln("file '${filename(span)}'");
        concat.writeln('option framerate 30');
        concat.writeln('duration ${span.duration.toStringAsFixed(9)}');
      }
      concat.writeln("file '${filename(timeline.last)}'");
      concat.writeln('option framerate 30');
      final list = File(p.join(workspace.path, 'overlays.ffconcat'));
      await list.writeAsString(concat.toString());
      token.check();
      var videoPath = background.path;
      if (project.videoBackground) {
        token.check();
        videoPath = p.join(workspace.path, 'selected-video.mp4');
        await engine.run(
          videoTrimArguments(project, background.path, videoPath, encoder),
          token: token,
          onTime: (seconds) => progress(
            0.15 + 0.15 * (seconds / project.videoSegmentDuration).clamp(0, 1),
          ),
        );
      }
      final temporary = File(p.join(workspace.path, 'video.mp4'));
      await engine.run(
        exportArguments(
          project: project,
          audio: audio.path,
          background: videoPath,
          overlayList: list.path,
          output: temporary.path,
          encoder: encoder,
          copyright: quran.copyright,
        ),
        token: token,
        onTime: (seconds) =>
            progress(0.30 + 0.69 * (seconds / project.duration).clamp(0, 1)),
      );
      token.check();
      final info = await engine.inspect(temporary.path);
      token.check();
      if (!info.duration.isFinite ||
          !info.hasVideo ||
          !info.hasAudio ||
          (info.duration - project.duration).abs() > 0.2) {
        throw MediaFailure(
          'The encoded MP4 failed duration/stream verification. Try another quality or source file.',
        );
      }
      final notice = File(p.join(workspace.path, 'notice.txt'));
      await notice.writeAsString(
        'Quran Reel Maker\nArabic font: Amiri Quran 1.003 (SIL OFL 1.1).\n'
        'Quran source: https://tanzil.net/\n${quran.copyright}\n',
      );
      token.check();
      final result = await reserveExport(outputDirectory, project.title);
      try {
        await temporary.rename(result.path);
        await notice.rename('${result.path}.txt');
      } catch (_) {
        await result.delete();
        rethrow;
      }
      progress(1);
      return result;
    } on FileSystemException catch (error) {
      throw MediaFailure(
        'Cannot write the export. Check free storage and folder permissions, or choose a lower resolution. ${error.osError?.message ?? error.message}',
      );
    } finally {
      if (await workspace.exists()) await workspace.delete(recursive: true);
    }
  }
}
