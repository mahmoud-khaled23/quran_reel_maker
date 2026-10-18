import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

import '../../models/reel_project.dart';

const exportResolutions = [144, 240, 360, 480, 720, 1080];

class ExportSize {
  const ExportSize(this.width, this.height);
  final int width, height;
  @override
  String toString() => '$width × $height';
}

/// Quality labels describe the short edge (1080p portrait = 1080 × 1920).
/// Video dimensions cap the result, so a low-resolution source isn't enlarged.
ExportSize exportSize(ReelProject project) {
  if (!exportResolutions.contains(project.exportResolution)) {
    throw const FormatException('Unsupported export resolution.');
  }
  final aspect = project.canvasAspect;
  var width = project.exportResolution * (aspect >= 1 ? aspect : 1.0);
  var height = project.exportResolution * (aspect >= 1 ? 1.0 : 1 / aspect);
  if (project.videoBackground &&
      project.backgroundWidth > 0 &&
      project.backgroundHeight > 0) {
    final factor = math.min(
      1.0,
      math.min(
        project.backgroundWidth / width,
        project.backgroundHeight / height,
      ),
    );
    width *= factor;
    height *= factor;
  }
  int even(double v) => math.max(2, (v / 2).floor() * 2);
  return ExportSize(even(width), even(height));
}

String exportStem(String title) {
  var value = title
      .replaceAll(RegExp(r'[\x00-\x1f\x7f<>:"/\\|?*]'), '_')
      .trim();
  value = value.replaceAll(RegExp(r'[. ]+$'), '');
  if (value.toLowerCase().endsWith('.mp4')) {
    value = value.substring(0, value.length - 4).trim();
  }
  if (value.isEmpty || value == '.' || value == '..') value = 'Quran Reel';
  if (RegExp(
    r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\.|$)',
    caseSensitive: false,
  ).hasMatch(value)) {
    value = '_$value';
  }
  final runes = value.runes.toList();
  while (utf8.encode(String.fromCharCodes(runes)).length > 160) {
    runes.removeLast();
  }
  return String.fromCharCodes(runes).replaceAll(RegExp(r'[. ]+$'), '');
}

Future<File> availableExport(Directory directory, String title) async {
  final stem = exportStem(title);
  for (var n = 1; ; n++) {
    final file = File(
      p.join(directory.path, '$stem${n == 1 ? '' : ' ($n)'}.mp4'),
    );
    if (!await FileSystemEntity.isFile(file.path) &&
        !await FileSystemEntity.isDirectory(file.path) &&
        !await Link(file.path).exists() &&
        !await File('${file.path}.txt').exists()) {
      return file;
    }
  }
}

/// Reserve the output atomically; collisions never overwrite a user's file.
Future<File> reserveExport(Directory directory, String title) async {
  while (true) {
    final file = await availableExport(directory, title);
    try {
      return await file.create(exclusive: true);
    } on FileSystemException {
      if (!await FileSystemEntity.isFile(file.path)) rethrow;
    }
  }
}
