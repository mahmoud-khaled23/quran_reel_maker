import 'dart:io';

import '../features/export/export_settings.dart';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../media_engine/media_engine.dart';

class NamedVideoExport {
  const NamedVideoExport(this.file, this.name);
  final File file;
  final String name;
}

/// Copy only to reserved new files; on cancellation/failure roll back this batch.
Future<List<String>> copyVideoBatch(
  List<NamedVideoExport> videos,
  Directory destination, {
  required CancellationToken token,
  required void Function(double) progress,
}) async {
  final created = <File>[];
  final paths = <String>[];
  try {
    var total = 0, copied = 0;
    for (final video in videos) {
      total += await video.file.length();
    }
    for (final video in videos) {
      token.check();
      final target = await reserveExport(destination, video.name);
      created.add(target);
      final sink = target.openWrite();
      try {
        await for (final bytes in video.file.openRead()) {
          token.check();
          sink.add(bytes);
          await sink.flush();
          copied += bytes.length;
          progress(total == 0 ? 0 : copied / total);
        }
      } finally {
        await sink.close();
      }
      final notice = File('${video.file.path}.txt');
      if (await notice.exists()) {
        final sidecar = File('${target.path}.txt');
        await sidecar.create(exclusive: true);
        created.add(sidecar);
        await notice.copy(sidecar.path);
      }
      paths.add(target.path);
    }
    token.check();
    return paths;
  } catch (error) {
    for (final file in created.reversed) {
      if (await file.exists()) await file.delete();
    }
    if (error is FileSystemException) {
      throw MediaFailure(
        'Could not save the segments. Check free space and folder permissions; new files from this attempt were removed. ${error.osError?.message ?? error.message}',
      );
    }
    rethrow;
  }
}

Future<List<String>?> saveVideoBatch(
  List<NamedVideoExport> videos, {
  required CancellationToken token,
  required void Function(double) progress,
}) async {
  if (Platform.isAndroid) {
    const channel = MethodChannel('quran_reel/files');
    channel.setMethodCallHandler((call) async {
      if (call.method == 'saveProgress') {
        progress((call.arguments as num).toDouble().clamp(0, 1));
      }
    });
    token.onCancel = () {
      channel.invokeMethod<void>('cancelSave');
    };
    try {
      token.check();
      final result = await channel.invokeListMethod<String>('saveVideos', {
        'videos': videos
            .map(
              (v) => {'path': v.file.path, 'name': '${exportStem(v.name)}.mp4'},
            )
            .toList(),
      });
      return result;
    } on PlatformException catch (e) {
      if (e.code == 'cancelled') throw ExportCancelled();
      throw MediaFailure('Could not save segments: ${e.message}');
    } finally {
      token.onCancel = null;
      channel.setMethodCallHandler(null);
    }
  }
  final folder = await FilePicker.platform.getDirectoryPath(
    dialogTitle: 'Save video segments to folder',
  );
  if (folder == null) return null;
  return copyVideoBatch(
    videos,
    Directory(folder),
    token: token,
    progress: progress,
  );
}

Future<String?> saveExportCopy(File file) async {
  if (Platform.isAndroid) {
    return const MethodChannel('quran_reel/files').invokeMethod<String>(
      'saveVideo',
      {'path': file.path, 'name': p.basename(file.path)},
    );
  }
  final destination = await FilePicker.platform.saveFile(
    dialogTitle: 'Save your reel',
    fileName: p.basename(file.path),
    type: FileType.custom,
    allowedExtensions: ['mp4'],
  );
  if (destination == null) return null;
  final target = destination.toLowerCase().endsWith('.mp4')
      ? destination
      : '$destination.mp4';
  if (p.equals(file.path, target)) return target;
  final reserved = await reserveExport(
    Directory(p.dirname(target)),
    p.basenameWithoutExtension(target),
  );
  try {
    await file.copy(reserved.path);
    await File('${file.path}.txt').copy('${reserved.path}.txt');
    return reserved.path;
  } catch (_) {
    await reserved.delete();
    rethrow;
  }
}
