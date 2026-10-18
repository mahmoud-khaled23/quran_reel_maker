/// Whitespace indices always refer to the untouched canonical text.
bool isSpokenToken(String token) => RegExp(r'[ء-غف-يٱ]').hasMatch(token);

String canonicalExcerpt(
  String verse,
  int first,
  int last, {
  int? selectionEnd,
}) {
  final tokens = RegExp(r'\S+').allMatches(verse).toList();
  if (first < 0 || first >= tokens.length || last < first) return '';
  var end = last.clamp(first, tokens.length - 1);
  final limit = (selectionEnd ?? tokens.length - 1).clamp(
    end,
    tokens.length - 1,
  );
  // Preserve adjacent pause/sajdah marks without exposing the next spoken word.
  while (end < limit && !isSpokenToken(tokens[end + 1].group(0)!)) {
    end++;
  }
  return verse.substring(tokens[first].start, tokens[end].end);
}
