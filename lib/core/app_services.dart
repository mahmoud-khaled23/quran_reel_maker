import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/quran_text/quran_repository.dart';
import '../media_engine/media_engine.dart';
import '../models/reel_project.dart';
import '../services/project_store.dart';

class AppServices {
  const AppServices({
    required this.store,
    required this.quran,
    required this.engine,
    required this.exports,
    this.playbackError,
  });
  final ProjectStore store;
  final QuranRepository quran;
  final MediaEngine engine;
  final Directory exports;
  final String? playbackError;
}

final servicesProvider = Provider<AppServices>(
  (ref) => throw UnimplementedError('Override at bootstrap.'),
);
final editorProvider = NotifierProvider<EditorController, ReelProject?>(
  EditorController.new,
);

class EditorController extends Notifier<ReelProject?> {
  @override
  ReelProject? build() => null;
  void replace(ReelProject project) {
    for (final cue in project.cues) {
      ref.read(servicesProvider).quran.verse(cue.surah, cue.ayah);
    }
    state = project;
  }

  void edit(ReelProject project) {
    final errors = project.validate();
    if (errors.isNotEmpty) throw FormatException(errors.join('\n'));
    state = project;
  }

  Future<void> save() async {
    if (state != null) await ref.read(servicesProvider).store.save(state!);
  }
}
