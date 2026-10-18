import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../audio_editor/time_field.dart';

/// A separate player previews the original file; confirmation stores bounds only.
class MediaTrimDialog extends StatefulWidget {
  const MediaTrimDialog({
    super.key,
    required this.path,
    required this.duration,
    required this.video,
    this.start = 0,
    this.end,
    this.playbackError,
  });
  final String path;
  final double duration, start;
  final double? end;
  final bool video;
  final String? playbackError;
  @override
  State<MediaTrimDialog> createState() => _MediaTrimDialogState();
}

class _MediaTrimDialogState extends State<MediaTrimDialog> {
  Player? player;
  VideoController? controller;
  final subscriptions = <StreamSubscription<dynamic>>[];
  late double start = widget.start, end = widget.end ?? widget.duration;
  late double position = start;
  bool ready = false, playing = false, seeking = false;
  String? error;
  @override
  void initState() {
    super.initState();
    error = widget.playbackError;
    if (error != null) return;
    player = Player();
    if (widget.video) controller = VideoController(player!);
    subscriptions.add(
      player!.stream.position.listen((time) {
        if (!mounted || seeking) return;
        final seconds = time.inMilliseconds / 1000;
        if (seconds >= end && playing) unawaited(player!.pause());
        setState(() => position = seconds.clamp(start, end));
      }),
    );
    subscriptions.add(
      player!.stream.playing.listen((value) {
        if (mounted) setState(() => playing = value);
      }),
    );
    subscriptions.add(
      player!.stream.error.listen((message) {
        if (mounted) {
          setState(
            () => error = 'Preview could not decode this file: $message',
          );
        }
      }),
    );
    unawaited(open());
  }

  Future<void> open() async {
    try {
      await player!.open(Media(widget.path), play: false);
      await player!.seek(Duration(milliseconds: (start * 1000).round()));
      if (mounted) setState(() => ready = true);
    } catch (e) {
      if (mounted) setState(() => error = 'Preview unavailable: $e');
    }
  }

  Future<void> seek(double time) async {
    seeking = true;
    try {
      await player?.seek(Duration(milliseconds: (time * 1000).round()));
      if (mounted) setState(() => position = time);
    } finally {
      seeking = false;
    }
  }

  bool trim(double a, double b) {
    if (!validTrim(a, b, widget.duration)) return false;
    setState(() {
      start = a;
      end = b;
      position = a;
    });
    unawaited(() async {
      await player?.pause();
      await seek(a);
    }());
    return true;
  }

  @override
  void dispose() {
    for (final sub in subscriptions) {
      unawaited(sub.cancel());
    }
    unawaited(player?.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.video ? 'Preview & trim video' : 'Preview & trim audio'),
    content: SizedBox(
      width: 620,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Non-destructive: the original file is preserved. Only this selection is used.',
            ),
            if (controller != null)
              SizedBox(
                height: 220,
                child: Video(
                  controller: controller!,
                  controls: NoVideoControls,
                  fit: BoxFit.contain,
                ),
              ),
            if (!ready && error == null) const LinearProgressIndicator(),
            if (error != null)
              Text(error!, style: const TextStyle(color: Colors.amber)),
            Text('${timeLabel(position)} / ${timeLabel(widget.duration)}'),
            Row(
              children: [
                IconButton(
                  tooltip: playing ? 'Pause segment' : 'Play selected segment',
                  onPressed: !ready
                      ? null
                      : () async {
                          if (playing) {
                            await player!.pause();
                          } else {
                            if (position >= end - 0.03 || position < start) {
                              await seek(start);
                            }
                            await player!.play();
                          }
                        },
                  icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                ),
                Expanded(
                  child: Slider(
                    value: position.clamp(start, end),
                    min: start,
                    max: end,
                    label: timeLabel(position),
                    onChanged: !ready
                        ? null
                        : (t) {
                            unawaited(seek(t));
                          },
                  ),
                ),
              ],
            ),
            RangeSlider(
              values: RangeValues(start, end),
              min: 0,
              max: widget.duration,
              labels: RangeLabels(timeLabel(start), timeLabel(end)),
              onChanged: (range) => trim(
                (range.start * 1000).round() / 1000,
                (range.end * 1000).floor() / 1000,
              ),
            ),
            Row(
              children: [
                Expanded(
                  child: TimeField(
                    label: 'Selection start',
                    value: start,
                    onChanged: (t) => trim(t, end),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TimeField(
                    label: 'Selection end',
                    value: end,
                    onChanged: (t) => trim(start, t),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text('${timeLabel(end - start)} selected'),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, RangeValues(start, end)),
        child: const Text('Use selection'),
      ),
    ],
  );
}
