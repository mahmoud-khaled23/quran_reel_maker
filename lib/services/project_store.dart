import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/reel_project.dart';

class ProjectStore {
  ProjectStore(this.root);
  final Directory root;
  Directory directory(String id) {
    if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(id)) {
      throw ArgumentError('Invalid ID');
    }
    return Directory(p.join(root.path, id));
  }

  Future<ReelProject> create() async {
    final project = ReelProject(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
    );
    await save(project);
    return project;
  }

  Future<void> save(ReelProject project) async {
    final errors = project.validate();
    if (errors.isNotEmpty) throw FormatException(errors.join(' '));
    final dir = directory(project.id);
    await dir.create(recursive: true);
    final temporary = File(p.join(dir.path, 'project.json.tmp'));
    await temporary.writeAsString(project.encode(), flush: true);
    await temporary.rename(p.join(dir.path, 'project.json'));
  }

  Future<ReelProject> load(String id) async {
    final project = ReelProject.decode(
      await File(p.join(directory(id).path, 'project.json')).readAsString(),
    );
    if (project.id != id) {
      throw const FormatException('Project ID does not match its folder.');
    }
    for (final name in [
      project.audio,
      project.background,
    ].whereType<String>()) {
      if (!await File(p.join(directory(id).path, name)).exists()) {
        throw FileSystemException('Project media is missing', name);
      }
    }
    return project;
  }

  Future<List<ReelProject>> list() async {
    if (!await root.exists()) return [];
    final projects = <ReelProject>[];
    await for (final dir in root.list()) {
      if (dir is! Directory) continue;
      try {
        projects.add(await load(p.basename(dir.path)));
      } on FileSystemException {
        continue;
      } on FormatException {
        continue;
      } on TypeError {
        continue;
      } on ArgumentError {
        continue;
      }
    }
    projects.sort((a, b) => b.id.compareTo(a.id));
    return projects;
  }

  Future<String> importFile(String id, File source, String kind) async {
    final extension = p.extension(source.path).toLowerCase();
    if (!RegExp(r'^\.[a-z0-9]{1,8}$').hasMatch(extension)) {
      throw const FormatException('Choose a file with a supported extension.');
    }
    final relative =
        'media/${kind}_${DateTime.now().microsecondsSinceEpoch}$extension';
    final destination = File(p.join(directory(id).path, relative));
    await destination.parent.create(recursive: true);
    await source.copy(destination.path);
    return relative;
  }
}
