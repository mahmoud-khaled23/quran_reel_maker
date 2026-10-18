import 'package:flutter/material.dart';

import '../../models/reel_project.dart';
import '../audio_editor/time_field.dart';

import '../quran_text/quran_words.dart';

/// Empty manual fields require the user to enter real boundaries, never a grid.
class WordTimingDialog extends StatefulWidget {
  const WordTimingDialog({super.key, required this.cue, required this.verse});
  final AyahCue cue;
  final String verse;
  @override
  State<WordTimingDialog> createState() => _WordTimingDialogState();
}

class _WordTimingDialogState extends State<WordTimingDialog> {
  late final tokens = widget.verse.split(RegExp(r'\s+'));
  late int first = widget.cue.firstWord,
      last = widget.cue.lastWord ?? tokens.length - 1;
  late final starts = List.generate(
    tokens.length,
    (i) => TextEditingController(text: existing(i, true)),
  );
  late final ends = List.generate(
    tokens.length,
    (i) => TextEditingController(text: existing(i, false)),
  );
  String? error;
  String existing(int index, bool start) {
    for (final word in widget.cue.words) {
      if (word.index == index) return timeLabel(start ? word.start : word.end);
    }
    return '';
  }

  double? enteredTime(int index, bool start) {
    final text = (start ? starts[index] : ends[index]).text;
    for (final word in widget.cue.words) {
      final original = start ? word.start : word.end;
      if (word.index == index && text == timeLabel(original)) return original;
    }
    return parseTime(text);
  }

  @override
  void dispose() {
    for (final c in [...starts, ...ends]) {
      c.dispose();
    }
    super.dispose();
  }

  void save(bool timed) {
    final words = <WordCue>[];
    var previous = widget.cue.start;
    for (var i = first; timed && i <= last; i++) {
      if (!isSpokenToken(tokens[i])) continue;
      final a = enteredTime(i, true), b = enteredTime(i, false);
      if (a == null ||
          b == null ||
          a < previous - 0.000001 ||
          b <= a ||
          b > widget.cue.end + 0.000001) {
        setState(
          () => error =
              'Word ${i + 1}: enter ordered HH:MM:SS:FFF boundaries inside the ayah. Empty fields cannot become automatic timings.',
        );
        return;
      }
      words.add(WordCue(index: i, start: a, end: b));
      previous = b;
    }
    if (timed && words.isEmpty) {
      setState(() => error = 'Select at least one spoken word.');
      return;
    }
    Navigator.pop(
      context,
      widget.cue.copyWith(firstWord: first, lastWord: last, words: words),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Recited words & timing'),
    content: SizedBox(
      width: 680,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Ayah ${timeLabel(widget.cue.start)} – ${timeLabel(widget.cue.end)}. Choose the recited excerpt. Progressive display requires a time for every spoken word in it.',
            ),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<int>(
                    initialValue: first,
                    key: ValueKey('first-$first'),
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'First recited word',
                    ),
                    items: List.generate(
                      tokens.length,
                      (i) => DropdownMenuItem(
                        value: i,
                        child: Text('${i + 1}. ${tokens[i]}'),
                      ),
                    ),
                    onChanged: (v) => setState(() {
                      first = v!;
                      if (last < first) last = first;
                    }),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: DropdownButtonFormField<int>(
                    initialValue: last,
                    key: ValueKey('last-$first-$last'),
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Last recited word',
                    ),
                    items: List.generate(
                      tokens.length - first,
                      (i) => DropdownMenuItem(
                        value: i + first,
                        child: Text('${i + first + 1}. ${tokens[i + first]}'),
                      ),
                    ),
                    onChanged: (v) => setState(() => last = v!),
                  ),
                ),
              ],
            ),
            for (var i = first; i <= last; i++)
              if (isSpokenToken(tokens[i]))
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 80,
                        child: Text(
                          tokens[i],
                          textDirection: TextDirection.rtl,
                        ),
                      ),
                      Expanded(
                        child: TextField(
                          controller: starts[i],
                          keyboardType: TextInputType.datetime,
                          decoration: const InputDecoration(
                            labelText: 'Word start',
                            hintText: 'HH:MM:SS:FFF',
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: ends[i],
                          keyboardType: TextInputType.datetime,
                          decoration: const InputDecoration(
                            labelText: 'Word end',
                            hintText: 'HH:MM:SS:FFF',
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            if (error != null)
              Text(error!, style: const TextStyle(color: Colors.amber)),
            const Text(
              'Passage timing shows this selected excerpt throughout the ayah interval. It makes no word-sync claim. Use the main player to listen and seek before editing.',
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      TextButton(
        onPressed: () => save(false),
        child: const Text('Use passage timing'),
      ),
      FilledButton(
        onPressed: () => save(true),
        child: const Text('Save word timings'),
      ),
    ],
  );
}
