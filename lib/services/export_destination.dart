import 'dart:io';

import '../features/export/export_settings.dart';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

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
