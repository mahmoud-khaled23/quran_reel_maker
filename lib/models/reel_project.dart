import 'dart:convert';

enum BackgroundFit { cover, contain }

class WordCue {
  const WordCue({
    required this.index,
    required this.start,
    required this.end,
    this.score,
  });

  /// Whitespace word index in the unmodified Tanzil ayah (annotation-only tokens may be skipped).
  final int index;
  final double start, end;
  final double? score;
  Map<String, Object?> toJson() => {
    'index': index,
    'start': start,
    'end': end,
    'score': score,
  };
  factory WordCue.fromJson(Map<String, dynamic> j) => WordCue(
    index: j['index'] as int,
    start: (j['start'] as num).toDouble(),
    end: (j['end'] as num).toDouble(),
    score: (j['score'] as num?)?.toDouble(),
  );
}

class AyahCue {
  const AyahCue({
    required this.surah,
    required this.ayah,
    required this.start,
    required this.end,
    this.confidence,
    this.timingSource = 'manual',
    this.alignmentScore,
    this.alignmentModel,
    this.warnings = const [],
    this.words = const [],
    this.firstWord = 0,
    this.lastWord,
  });
  final int surah;
  final int ayah;

  /// Absolute seconds in the original audio, never relative to the trim.
  final double start;
  final double end;
  final double? confidence;
  final String timingSource;

  /// Uncalibrated acoustic match score, never an accuracy probability.
  final double? alignmentScore;
  final String? alignmentModel;
  final List<String> warnings;
  final List<WordCue> words;
  final int firstWord;
  final int? lastWord;
  AyahCue copyWith({
    double? start,
    double? end,
    int? firstWord,
    int? lastWord,
    List<WordCue>? words,
  }) => AyahCue(
    surah: surah,
    ayah: ayah,
    firstWord: firstWord ?? this.firstWord,
    lastWord: lastWord ?? this.lastWord,
    start: start ?? this.start,
    end: end ?? this.end,
    // Editing ayah boundaries invalidates the automatic word-level draft.
    confidence:
        start == null &&
            end == null &&
            firstWord == null &&
            lastWord == null &&
            words == null
        ? confidence
        : null,
    timingSource:
        start == null &&
            end == null &&
            firstWord == null &&
            lastWord == null &&
            words == null
        ? timingSource
        : 'edited',
    alignmentScore:
        start == null &&
            end == null &&
            firstWord == null &&
            lastWord == null &&
            words == null
        ? alignmentScore
        : null,
    alignmentModel: alignmentModel,
    warnings:
        start == null &&
            end == null &&
            firstWord == null &&
            lastWord == null &&
            words == null
        ? warnings
        : const [],
    words:
        words ??
        (start == null && end == null && firstWord == null && lastWord == null
            ? this.words
            : const []),
  );
  Map<String, Object?> toJson() => {
    'surah': surah,
    'ayah': ayah,
    'start': start,
    'end': end,
    'confidence': confidence,
    'timingSource': timingSource,
    'alignmentScore': alignmentScore,
    'alignmentModel': alignmentModel,
    'warnings': warnings,
    'firstWord': firstWord,
    'lastWord': lastWord,
    'words': words.map((w) => w.toJson()).toList(),
  };
  factory AyahCue.fromJson(Map<String, dynamic> j) => AyahCue(
    firstWord: j['firstWord'] as int? ?? 0,
    lastWord: j['lastWord'] as int?,
    surah: j['surah'] as int,
    ayah: j['ayah'] as int,
    start: (j['start'] as num).toDouble(),
    end: (j['end'] as num).toDouble(),
    confidence: (j['confidence'] as num?)?.toDouble(),
    timingSource: j['timingSource'] as String? ?? 'manual',
    alignmentScore: (j['alignmentScore'] as num?)?.toDouble(),
    alignmentModel: j['alignmentModel'] as String?,
    warnings: List<String>.unmodifiable(
      (j['warnings'] as List? ?? []).cast<String>(),
    ),
    words: List.unmodifiable(
      (j['words'] as List? ?? []).map(
        (w) => WordCue.fromJson(w as Map<String, dynamic>),
      ),
    ),
  );
}

class ReelProject {
  const ReelProject({
    required this.id,
    this.title = 'Untitled reel',
    this.audio,
    this.audioDuration = 0,
    this.trimStart = 0,
    this.trimEnd = 0,
    this.background,
    this.videoBackground = false,
    this.fit = BackgroundFit.cover,
    this.cropX = 0.5,
    this.cropY = 0.5,
    this.cues = const [],
    this.videoDuration = 0,
    this.videoTrimStart = 0,
    this.videoTrimEnd = 0,
    this.backgroundWidth = 0,
    this.backgroundHeight = 0,
    this.originalAspect = false,
    this.exportResolution = 1080,
    this.overlayX = 0.5,
    this.overlayY = 0.58,
    this.fontColor = 0xFFFFFFFF,
    this.textBackground = true,
    this.reviewed = false,
  });
  final String id;
  final String title;

  /// Paths relative to the project folder. Imported media is copied into it.
  final String? audio;
  final double audioDuration;
  final double trimStart;
  final double trimEnd;
  final String? background;
  final bool videoBackground;
  final BackgroundFit fit;
  final double cropX;
  final double cropY;
  final List<AyahCue> cues;
  final double videoDuration;
  final double videoTrimStart;
  final double videoTrimEnd;
  final int backgroundWidth;
  final int backgroundHeight;
  final bool originalAspect;
  final int exportResolution;
  final double overlayX;
  final double overlayY;
  final int fontColor;
  final bool textBackground;
  final bool reviewed;
  double get canvasAspect =>
      originalAspect && backgroundWidth > 0 && backgroundHeight > 0
      ? backgroundWidth / backgroundHeight
      : 9 / 16;
  double get videoSegmentDuration => videoTrimEnd - videoTrimStart;
  double videoTime(double audioTime, {double fallbackDuration = 0}) {
    final length = videoSegmentDuration > 0
        ? videoSegmentDuration
        : fallbackDuration;
    return length > 0
        ? videoTrimStart +
              ((audioTime - trimStart).clamp(0, double.infinity) % length)
        : 0;
  }

  double get duration => trimEnd - trimStart;

  ReelProject copyWith({
    String? title,
    String? audio,
    double? audioDuration,
    double? trimStart,
    double? trimEnd,
    String? background,
    bool? videoBackground,
    BackgroundFit? fit,
    double? cropX,
    double? cropY,
    List<AyahCue>? cues,
    double? videoDuration,
    double? videoTrimStart,
    double? videoTrimEnd,
    int? backgroundWidth,
    int? backgroundHeight,
    bool? originalAspect,
    int? exportResolution,
    double? overlayX,
    double? overlayY,
    int? fontColor,
    bool? textBackground,
    bool? reviewed,
  }) => ReelProject(
    id: id,
    title: title ?? this.title,
    audio: audio ?? this.audio,
    audioDuration: audioDuration ?? this.audioDuration,
    trimStart: trimStart ?? this.trimStart,
    trimEnd: trimEnd ?? this.trimEnd,
    background: background ?? this.background,
    videoBackground: videoBackground ?? this.videoBackground,
    fit: fit ?? this.fit,
    cropX: cropX ?? this.cropX,
    cropY: cropY ?? this.cropY,
    cues: List.unmodifiable(cues ?? this.cues),
    videoDuration: videoDuration ?? this.videoDuration,
    videoTrimStart: videoTrimStart ?? this.videoTrimStart,
    videoTrimEnd: videoTrimEnd ?? this.videoTrimEnd,
    backgroundWidth: backgroundWidth ?? this.backgroundWidth,
    backgroundHeight: backgroundHeight ?? this.backgroundHeight,
    originalAspect: originalAspect ?? this.originalAspect,
    exportResolution: exportResolution ?? this.exportResolution,
    overlayX: overlayX ?? this.overlayX,
    overlayY: overlayY ?? this.overlayY,
    fontColor: fontColor ?? this.fontColor,
    textBackground: textBackground ?? this.textBackground,
    reviewed: reviewed ?? this.reviewed,
  );

  List<String> validate({bool forExport = false}) {
    final errors = <String>[];
    if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(id)) {
      errors.add('Invalid project ID.');
    }
    for (final file in [audio, background].whereType<String>()) {
      if (!RegExp(r'^media/[a-zA-Z0-9_.-]+$').hasMatch(file)) {
        errors.add('Unsafe media path.');
      }
    }
    if (![
      audioDuration,
      trimStart,
      trimEnd,
    ].every((n) => n.isFinite && n >= 0)) {
      errors.add(
        'Audio duration and trim times must be finite and non-negative.',
      );
    }
    if (audio == null &&
        (audioDuration != 0 ||
            trimStart != 0 ||
            trimEnd != 0 ||
            cues.isNotEmpty)) {
      errors.add('Import audio before setting trim times or ayah cues.');
    }
    if (audio != null &&
        (!audioDuration.isFinite ||
            audioDuration <= 0 ||
            !trimStart.isFinite ||
            !trimEnd.isFinite ||
            trimStart < 0 ||
            trimEnd > audioDuration + 0.001 ||
            duration < 1 / 30)) {
      errors.add('Trim must lie inside the audio and last at least one frame.');
    }
    if (!cropX.isFinite ||
        !cropY.isFinite ||
        cropX < 0 ||
        cropX > 1 ||
        cropY < 0 ||
        cropY > 1) {
      errors.add('Invalid crop position.');
    }
    if (![
          videoDuration,
          videoTrimStart,
          videoTrimEnd,
        ].every((n) => n.isFinite && n >= 0) ||
        (videoDuration > 0 &&
            (videoTrimEnd > videoDuration + 0.001 ||
                videoSegmentDuration < 1 / 30)) ||
        (videoDuration == 0 && (videoTrimStart != 0 || videoTrimEnd != 0))) {
      errors.add(
        'Video trim must lie inside the source and last at least one frame.',
      );
    }
    if (backgroundWidth < 0 ||
        backgroundHeight < 0 ||
        ![144, 240, 360, 480, 720, 1080].contains(exportResolution) ||
        ![overlayX, overlayY].every((n) => n.isFinite && n >= 0 && n <= 1) ||
        fontColor < 0xFF000000 ||
        fontColor > 0xFFFFFFFF) {
      errors.add('Invalid canvas, export resolution or overlay style.');
    }
    double previousEnd = -1;
    for (final cue in cues) {
      if (cue.surah < 1 ||
          cue.surah > 114 ||
          cue.ayah < 1 ||
          !cue.start.isFinite ||
          !cue.end.isFinite ||
          cue.start < 0 ||
          cue.end <= cue.start ||
          cue.end > audioDuration + 0.001 ||
          cue.start < previousEnd - 0.000001 ||
          (cue.confidence != null &&
              (!cue.confidence!.isFinite ||
                  cue.confidence! < 0 ||
                  cue.confidence! > 1))) {
        errors.add(
          'Ayah timings must be ordered, non-overlapping, and within the audio.',
        );
        break;
      }
      previousEnd = cue.end;
      if (!['manual', 'automatic', 'edited'].contains(cue.timingSource) ||
          (cue.alignmentScore != null &&
              (!cue.alignmentScore!.isFinite ||
                  cue.alignmentScore! < 0 ||
                  cue.alignmentScore! > 1))) {
        errors.add('Invalid alignment quality metadata.');
      }
      if (cue.firstWord < 0 ||
          (cue.lastWord != null && cue.lastWord! < cue.firstWord)) {
        errors.add('Invalid Quran word selection.');
      }
      var wordEnd = cue.start;
      var wordIndex = -1;
      for (final word in cue.words) {
        if (word.index <= wordIndex ||
            word.index < cue.firstWord ||
            (cue.lastWord != null && word.index > cue.lastWord!) ||
            !word.start.isFinite ||
            !word.end.isFinite ||
            word.start < wordEnd - 0.000001 ||
            word.end <= word.start ||
            word.end > cue.end + 0.000001 ||
            (word.score != null &&
                (!word.score!.isFinite ||
                    word.score! < 0 ||
                    word.score! > 1))) {
          errors.add('Word timings must be ordered and inside their ayah.');
          break;
        }
        wordEnd = word.end;
        wordIndex = word.index;
      }
    }
    if (forExport) {
      if (audio == null) errors.add('Import audio first.');
      if (background == null) errors.add('Import a background first.');
      if (cues.isNotEmpty && !reviewed) {
        errors.add('Review ayah timings before export.');
      }
    }
    return errors;
  }

  Map<String, Object?> toJson() => {
    'schemaVersion': 1,
    'id': id,
    'title': title,
    'audio': audio,
    'audioDuration': audioDuration,
    'trimStart': trimStart,
    'trimEnd': trimEnd,
    'background': background,
    'videoBackground': videoBackground,
    'fit': fit.name,
    'cropX': cropX,
    'cropY': cropY,
    'videoDuration': videoDuration,
    'videoTrimStart': videoTrimStart,
    'videoTrimEnd': videoTrimEnd,
    'backgroundWidth': backgroundWidth,
    'backgroundHeight': backgroundHeight,
    'originalAspect': originalAspect,
    'exportResolution': exportResolution,
    'overlayX': overlayX,
    'overlayY': overlayY,
    'fontColor': fontColor,
    'textBackground': textBackground,
    'reviewed': reviewed,
    'cues': cues.map((c) => c.toJson()).toList(),
  };
  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());
  factory ReelProject.decode(String source) {
    final j = jsonDecode(source) as Map<String, dynamic>;
    if (j['schemaVersion'] != 1) {
      throw const FormatException('Unsupported project version.');
    }
    final project = ReelProject(
      id: j['id'] as String,
      title: j['title'] as String,
      audio: j['audio'] as String?,
      audioDuration: (j['audioDuration'] as num).toDouble(),
      trimStart: (j['trimStart'] as num).toDouble(),
      trimEnd: (j['trimEnd'] as num).toDouble(),
      background: j['background'] as String?,
      videoBackground: j['videoBackground'] as bool,
      fit: BackgroundFit.values.byName(j['fit'] as String),
      cropX: (j['cropX'] as num).toDouble(),
      cropY: (j['cropY'] as num).toDouble(),
      videoDuration: (j['videoDuration'] as num?)?.toDouble() ?? 0,
      videoTrimStart: (j['videoTrimStart'] as num?)?.toDouble() ?? 0,
      videoTrimEnd: (j['videoTrimEnd'] as num?)?.toDouble() ?? 0,
      backgroundWidth: j['backgroundWidth'] as int? ?? 0,
      backgroundHeight: j['backgroundHeight'] as int? ?? 0,
      originalAspect: j['originalAspect'] as bool? ?? false,
      exportResolution: j['exportResolution'] as int? ?? 1080,
      overlayX: (j['overlayX'] as num?)?.toDouble() ?? 0.5,
      overlayY: (j['overlayY'] as num?)?.toDouble() ?? 0.58,
      fontColor: j['fontColor'] as int? ?? 0xFFFFFFFF,
      textBackground: j['textBackground'] as bool? ?? true,
      reviewed: j['reviewed'] as bool,
      cues: List.unmodifiable(
        (j['cues'] as List).map(
          (c) => AyahCue.fromJson(c as Map<String, dynamic>),
        ),
      ),
    );
    final errors = project.validate();
    if (errors.isNotEmpty) throw FormatException(errors.join(' '));
    return project;
  }
}
