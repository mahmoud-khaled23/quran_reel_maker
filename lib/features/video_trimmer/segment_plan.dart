import 'dart:math' as math;

import '../export/export_settings.dart';

class VideoSegment {
  const VideoSegment(this.index, this.startUs, this.endUs);
  final int index, startUs, endUs;
  double get start => startUs / 1000000;
  double get end => endUs / 1000000;
  double get duration => (endUs - startUs) / 1000000;
}

/// Integer arithmetic avoids accumulating fractional-second drift.
List<VideoSegment> segmentPlan(double sourceSeconds, double segmentSeconds) {
  if (![sourceSeconds, segmentSeconds].every((v) => v.isFinite && v > 0) ||
      sourceSeconds > 359999999 ||
      segmentSeconds > 359999999) {
    throw const FormatException(
      'Enter a finite, positive duration in seconds.',
    );
  }
  final total = (sourceSeconds * 1000000).round();
  final step = (segmentSeconds * 1000000).round();
  if (total < 1 || step < 1) {
    throw const FormatException('The duration is too small to represent.');
  }
  final count = (total + step - 1) ~/ step;
  if (count > 1000) {
    throw const FormatException(
      'Choose a longer duration: at most 1000 segments per batch.',
    );
  }
  return List.generate(
    count,
    (i) => VideoSegment(i, i * step, math.min(total, (i + 1) * step)),
  );
}

String segmentName(String value) {
  if (value.trim().isEmpty) {
    throw const FormatException('Enter a nonempty name.');
  }
  return exportStem(value);
}

/// Names are labels, never identifiers: renaming cannot reorder source intervals.
class SegmentNames {
  SegmentNames(String projectName, this.count)
    : _projectName = segmentName(projectName);
  final int count;
  String _projectName;
  final Map<int, String> _custom = {};
  String get projectName => _projectName;
  set projectName(String value) => _projectName = segmentName(value);
  bool isCustom(int index) => _custom.containsKey(index);
  void rename(int index, String value) {
    RangeError.checkValidIndex(index, List.filled(count, 0));
    _custom[index] = segmentName(value);
  }

  void reset(int index) => _custom.remove(index);
  SegmentNames resized(int count) {
    final next = SegmentNames(projectName, count);
    next._custom.addEntries(_custom.entries.where((e) => e.key < count));
    return next;
  }

  List<String> get filenames {
    final width = math.max(3, count.toString().length);
    final used = <String>{};
    return List.generate(count, (i) {
      final stem =
          _custom[i] ??
          '${exportStem(_projectName, maxBytes: 160 - width - 1)}_${(i + 1).toString().padLeft(width, '0')}';
      var name = '$stem.mp4', suffix = 2;
      while (!used.add(name.toLowerCase())) {
        final ending = ' (${suffix++})';
        name = '${exportStem(stem, maxBytes: 160 - ending.length)}$ending.mp4';
      }
      return name;
    });
  }
}
