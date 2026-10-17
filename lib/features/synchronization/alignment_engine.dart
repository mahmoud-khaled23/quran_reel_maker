import '../../models/reel_project.dart';

class AlignmentRequest {
  const AlignmentRequest({
    required this.audioPath,
    required this.trimStart,
    required this.trimEnd,
    required this.surah,
    required this.firstAyah,
    required this.lastAyah,
  });
  final String audioPath;
  final double trimStart, trimEnd;
  final int surah, firstAyah, lastAyah;
}

class AlignmentUnavailable implements Exception {
  const AlignmentUnavailable();
  @override
  String toString() =>
      'No validated offline Quran alignment model is installed. '
      'Choose the ayahs, then adjust each timestamp while listening.';
}

abstract interface class AlignmentEngine {
  Future<List<AyahCue>> align(AlignmentRequest request);
}

class UnavailableAlignmentEngine implements AlignmentEngine {
  @override
  Future<List<AyahCue>> align(AlignmentRequest request) async =>
      throw const AlignmentUnavailable();
}

/// A manual starting grid only. It makes no speech-recognition or confidence claim.
List<AyahCue> manualTimingGrid({
  required int surah,
  required int first,
  required int last,
  required double start,
  required double end,
}) {
  if (surah < 1 ||
      surah > 114 ||
      first < 1 ||
      last < first ||
      !start.isFinite ||
      !end.isFinite ||
      start < 0 ||
      end <= start ||
      (end - start) / (last - first + 1) < 1 / 30) {
    throw const FormatException(
      'Choose a valid ayah range and a longer audio segment.',
    );
  }
  final step = (end - start) / (last - first + 1);
  return List.generate(
    last - first + 1,
    (i) => AyahCue(
      surah: surah,
      ayah: first + i,
      start: start + i * step,
      end: start + (i + 1) * step,
    ),
  );
}
