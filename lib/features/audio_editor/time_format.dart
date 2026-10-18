/// Display milliseconds, never frame numbers. Saved source times remain seconds.
String timeLabel(double seconds) {
  final ms = (seconds * 1000).round().clamp(0, 359999999999);
  String pad(int value, int digits) => value.toString().padLeft(digits, '0');
  return '${pad(ms ~/ 3600000, 2)}:${pad(ms ~/ 60000 % 60, 2)}:'
      '${pad(ms ~/ 1000 % 60, 2)}:${pad(ms % 1000, 3)}';
}

double? parseTime(String value) {
  final match = RegExp(r'^(\d{2,}):([0-5]\d):([0-5]\d):(\d{3})$')
      .firstMatch(value.trim());
  if (match == null) return null;
  final parts = List.generate(4, (i) => int.tryParse(match.group(i + 1)!));
  if (parts.any((p) => p == null) || parts[0]! > 99999) return null;
  final ms =
      parts[0]! * 3600000 + parts[1]! * 60000 + parts[2]! * 1000 + parts[3]!;
  return ms <= 359999999999 ? ms / 1000 : null;
}

bool validTrim(double start, double end, double duration) =>
    [start, end, duration].every((t) => t.isFinite) &&
    start >= 0 &&
    end <= duration + 0.000001 &&
    end - start >= 1 / 30;
