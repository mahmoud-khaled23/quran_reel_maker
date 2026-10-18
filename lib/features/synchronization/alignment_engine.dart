import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../models/reel_project.dart';
import '../quran_text/quran_repository.dart';

class AlignmentRequest {
  const AlignmentRequest({
    required this.audioPath,
    required this.trimStart,
    required this.trimEnd,
    required this.surah,
    required this.firstAyah,
    required this.lastAyah,
    this.workerExecutable,
    this.firstWord = 0,
    this.lastWord,
  });
  final String audioPath;
  final double trimStart, trimEnd;
  final int surah, firstAyah, lastAyah;
  final String? workerExecutable;
  final int firstWord;
  final int? lastWord;
  Map<String, Object> toJson() => {
    'protocol': 1,
    'quranSha256': QuranRepository.textDigest,
    'audioPath': audioPath,
    'trimStart': trimStart,
    'trimEnd': trimEnd,
    'surah': surah,
    'firstAyah': firstAyah,
    'lastAyah': lastAyah,
    'firstWord': firstWord,
    'lastWord': ?lastWord,
  };
}

class AlignmentFailure implements Exception {
  const AlignmentFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

class AlignmentCancellation {
  final _cancelled = Completer<void>();
  bool get cancelled => _cancelled.isCompleted;
  Future<void> get whenCancelled => _cancelled.future;
  void cancel() {
    if (!cancelled) _cancelled.complete();
  }
}

abstract interface class AlignmentEngine {
  Future<List<AyahCue>> align(
    AlignmentRequest request, {
    AlignmentCancellation? cancellation,
    void Function(double, String)? onProgress,
  });
}

class ProcessAlignmentEngine implements AlignmentEngine {
  const ProcessAlignmentEngine({this.timeout = const Duration(minutes: 10)});
  final Duration timeout;
  static const model = 'quran-ctc-q4-v1';
  static const revision = 'f90650aac5d9dcff15230a19998c0027f45b33f1';

  @override
  Future<List<AyahCue>> align(
    AlignmentRequest request, {
    AlignmentCancellation? cancellation,
    void Function(double, String)? onProgress,
  }) async {
    if (!Platform.isLinux) {
      throw const AlignmentFailure(
        'Automatic alignment currently runs on Linux with the local Python worker. On Android, use Create manual timings, playback and Mark start/end. No model is downloaded by the app.',
      );
    }
    if (cancellation?.cancelled ?? false) {
      throw const AlignmentFailure(
        'Alignment cancelled. Existing timings were kept.',
      );
    }
    final local = File('scripts/alignment-worker.sh').absolute;
    final executable =
        request.workerExecutable ??
        Platform.environment['QRM_ALIGNMENT_WORKER'] ??
        (await local.exists() ? local.path : 'quran-reel-align');
    Process process;
    try {
      process = await Process.start(executable, const [], runInShell: false);
    } on ProcessException {
      throw const AlignmentFailure(
        'Local alignment worker could not start. Run ./scripts/setup-alignment.sh in the project folder, then Choose local worker → scripts/alignment-worker.sh. Ensure it is executable. Manual timing remains available.',
      );
    }
    Timer? killTimer;
    var finished = false, timedOut = false;
    void stop() {
      if (finished) return;
      process.kill();
      killTimer ??= Timer(const Duration(seconds: 2), () {
        if (!finished) process.kill(ProcessSignal.sigkill);
      });
    }

    final deadline = Timer(timeout, () {
      timedOut = true;
      stop();
    });
    unawaited(cancellation?.whenCancelled.then((_) => stop()));
    Map<String, dynamic>? result;
    String? failure;
    final stderr = StringBuffer();
    final stderrDone = process.stderr.transform(utf8.decoder).forEach((chunk) {
      if (stderr.length < 4000) {
        stderr.write(
          chunk.substring(0, chunk.length.clamp(0, 4000 - stderr.length)),
        );
      }
    });
    final stdoutDone = () async {
      var bytes = 0;
      final bounded = process.stdout.map((chunk) {
        bytes += chunk.length;
        if (bytes > 2 * 1024 * 1024) {
          throw const FormatException('Worker response exceeds 2 MiB.');
        }
        return chunk;
      });
      await for (final line
          in bounded.transform(utf8.decoder).transform(const LineSplitter())) {
        final event = jsonDecode(line) as Map<String, dynamic>;
        if (event['protocol'] != 1) {
          throw const FormatException('Unsupported worker protocol.');
        }
        switch (event['type']) {
          case 'progress':
            final progress = (event['value'] as num).toDouble();
            if (!progress.isFinite || progress < 0 || progress > 1) {
              throw const FormatException('Invalid progress.');
            }
            onProgress?.call(progress, event['message'] as String);
          case 'error':
            failure = event['message'] as String;
          case 'result':
            if (result != null) {
              throw const FormatException('Duplicate worker result.');
            }
            result = event;
          default:
            throw const FormatException('Unknown worker event.');
        }
      }
    }();
    // Attach error handlers immediately, including while stdin is being sent.
    Object? streamError;
    final streamsDone = Future.wait([stdoutDone, stderrDone], eagerError: true)
        .then<void>(
          (_) {},
          onError: (Object error) {
            streamError = error;
            stop();
          },
        );
    try {
      process.stdin.writeln(jsonEncode(request.toJson()));
      try {
        await process.stdin.close();
      } on IOException {
        // A setup failure can exit before reading stdin; retain its diagnostic.
      }
      await streamsDone;
      final exitCode = await process.exitCode;
      if (cancellation?.cancelled ?? false) {
        throw const AlignmentFailure(
          'Alignment cancelled. Existing timings were kept.',
        );
      }
      if (timedOut) {
        throw const AlignmentFailure(
          'Alignment timed out. Select a shorter segment or close other applications. Existing timings were kept.',
        );
      }
      if (streamError != null) throw streamError!;
      if (failure != null) throw AlignmentFailure(failure!);
      if (exitCode != 0 || result == null) {
        throw AlignmentFailure(
          'Worker exited without an alignment (exit $exitCode). Rerun setup or use manual timing. ${stderr.toString()}',
        );
      }
      return validateAlignmentResult(result!, request);
    } on AlignmentFailure {
      rethrow;
    } catch (error) {
      stop();
      // Drain process/stream failures before returning to avoid unhandled futures.
      try {
        await streamsDone;
      } catch (_) {
        /* Report the original failure. */
      }
      if (cancellation?.cancelled ?? false) {
        throw const AlignmentFailure(
          'Alignment cancelled. Existing timings were kept.',
        );
      }
      throw AlignmentFailure(
        'Invalid or incompatible alignment worker response: $error. Update the worker and app together, or use manual timing.',
      );
    } finally {
      await process.exitCode;
      finished = true;
      deadline.cancel();
      killTimer?.cancel();
    }
  }
}

List<AyahCue> validateAlignmentResult(
  Map<String, dynamic> result,
  AlignmentRequest request,
) {
  if (result['timeline'] != 'source' ||
      result['model'] != ProcessAlignmentEngine.model ||
      result['revision'] != ProcessAlignmentEngine.revision ||
      result['quranSha256'] != QuranRepository.textDigest) {
    throw const FormatException(
      'Worker timeline, Quran version or model does not match.',
    );
  }
  final cues = (result['cues'] as List)
      .map((c) => AyahCue.fromJson(c as Map<String, dynamic>))
      .toList();
  if (cues.length != request.lastAyah - request.firstAyah + 1) {
    throw const FormatException('Incomplete ayah result.');
  }
  for (var i = 0; i < cues.length; i++) {
    final cue = cues[i];
    if (cue.surah != request.surah ||
        cue.ayah != request.firstAyah + i ||
        cue.start < request.trimStart ||
        cue.end > request.trimEnd + 0.001 ||
        cue.timingSource != 'automatic' ||
        cue.alignmentModel != ProcessAlignmentEngine.model ||
        cue.alignmentScore == null ||
        cue.confidence != null ||
        cue.words.isEmpty ||
        cue.words.any((word) => word.score == null) ||
        (i == 0 && cue.firstWord != request.firstWord) ||
        (i == cues.length - 1 &&
            request.lastWord != null &&
            cue.lastWord != request.lastWord) ||
        cue.warnings.isEmpty) {
      throw const FormatException(
        'Invalid alignment references, bounds or quality metadata.',
      );
    }
  }
  final errors = ReelProject(
    id: 'alignment',
    audio: 'media/audio.wav',
    audioDuration: request.trimEnd,
    trimStart: request.trimStart,
    trimEnd: request.trimEnd,
    cues: cues,
  ).validate();
  if (errors.isNotEmpty) throw FormatException(errors.join(' '));
  return List.unmodifiable(cues);
}

/// A manual starting grid only. It makes no speech-recognition or confidence claim.
List<AyahCue> manualTimingGrid({
  required int surah,
  required int first,
  required int last,
  required double start,
  required double end,
  int firstWord = 0,
  int? lastWord,
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
      firstWord: i == 0 ? firstWord : 0,
      lastWord: i == last - first ? lastWord : null,
      start: start + i * step,
      end: start + (i + 1) * step,
    ),
  );
}
