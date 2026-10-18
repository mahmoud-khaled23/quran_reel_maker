import '../audio_editor/time_format.dart';

import 'package:flutter/material.dart';

import '../../models/reel_project.dart';

/// Source-time segments. Empty spaces deliberately remain visible as gaps.
class AyahTimeline extends StatelessWidget {
  const AyahTimeline({
    super.key,
    required this.project,
    required this.position,
    required this.onSeek,
  });
  final ReelProject project;
  final double position;
  final ValueChanged<double> onSeek;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth;
      double x(double seconds) =>
          ((seconds - project.trimStart) / project.duration).clamp(0, 1) *
          width;
      return SizedBox(
        height: 48,
        child: Stack(
          children: [
            const Positioned.fill(child: ColoredBox(color: Color(0xFF283434))),
            for (final cue in project.cues)
              if (cue.end > project.trimStart && cue.start < project.trimEnd)
                Positioned(
                  left: x(cue.start),
                  width: (x(cue.end) - x(cue.start)).clamp(1, width),
                  top: 4,
                  bottom: 4,
                  child: Tooltip(
                    message:
                        '${cue.surah}:${cue.ayah} · ${timeLabel(cue.start)}–${timeLabel(cue.end)}',
                    child: Semantics(
                      button: true,
                      label: 'Seek to ${cue.surah}:${cue.ayah}',
                      child: InkWell(
                        onTap: () => onSeek(
                          cue.start.clamp(project.trimStart, project.trimEnd),
                        ),
                        child: Container(
                          alignment: Alignment.center,
                          margin: const EdgeInsets.only(right: 1),
                          color: cue.timingSource == 'automatic'
                              ? const Color(0xFF65562F)
                              : const Color(0xFF285A49),
                          child: Text(
                            '${cue.surah}:${cue.ayah}',
                            maxLines: 1,
                            overflow: TextOverflow.clip,
                            style: const TextStyle(fontSize: 11),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            Positioned(
              left: x(position).clamp(0, (width - 2).clamp(0, width)),
              top: 0,
              bottom: 0,
              width: 2,
              child: const IgnorePointer(
                child: ColoredBox(color: Colors.white),
              ),
            ),
          ],
        ),
      );
    },
  );
}
