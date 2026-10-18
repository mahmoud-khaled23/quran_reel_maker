import '../quran_text/quran_words.dart';
import '../../models/reel_project.dart';

/// A contiguous excerpt of original whitespace tokens, including punctuation.
class OverlayState {
  const OverlayState(this.cueIndex, this.firstWord, this.lastWord);
  final int cueIndex, firstWord, lastWord;
  String get key => '${cueIndex}_${firstWord}_$lastWord';
  String text(String verse) => canonicalExcerpt(verse, firstWord, lastWord);
}

/// Preview and export share the 30 fps clock. Word onsets are never rounded early.
/// Hold prefixes across short pauses; clear gaps longer than 750 ms and cue ends.
OverlayState? overlayAt(ReelProject project, double sourceTime) {
  final frame = ((sourceTime - project.trimStart) * 30 + 1e-7).floor();
  final time = project.trimStart + frame / 30;
  if (frame < 0 || time >= project.trimEnd) return null;
  for (var i = 0; i < project.cues.length; i++) {
    final cue = project.cues[i];
    if (time + 1e-8 < cue.start || time >= cue.end - 1e-8) continue;
    if (cue.words.isEmpty) {
      // Explicit manual passage fallback: no invented word timing.
      return OverlayState(i, cue.firstWord, cue.lastWord ?? 1000000);
    }
    final words = cue.words
        .where((w) => w.end > project.trimStart && w.start < project.trimEnd)
        .toList();
    if (words.isEmpty) return null;
    var reached = -1;
    for (var j = 0; j < words.length; j++) {
      if (words[j].start <= time + 1e-8) reached = j;
    }
    if (reached < 0) return null;
    final word = words[reached];
    if (time >= word.end - 1e-8 &&
        (reached == words.length - 1 ||
            words[reached + 1].start - word.end > 0.75)) {
      return null;
    }
    return OverlayState(i, words.first.index, word.index);
  }
  return null;
}
