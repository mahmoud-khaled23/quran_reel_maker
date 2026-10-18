import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;

import '../../core/app_services.dart';
import '../../media_engine/media_engine.dart';
import '../../services/export_destination.dart';
import '../audio_editor/time_format.dart';
import 'segment_plan.dart';
import 'segmentation_service.dart';

class VideoTrimmerPage extends ConsumerStatefulWidget {
  const VideoTrimmerPage({super.key, this.completedReel, this.projectName});
  final File? completedReel;
  final String? projectName;
  @override
  ConsumerState<VideoTrimmerPage> createState() => _VideoTrimmerPageState();
}

class _VideoTrimmerPageState extends ConsumerState<VideoTrimmerPage> {
  final title = TextEditingController(),
      custom = TextEditingController(text: '45');
  final subscriptions = <StreamSubscription<dynamic>>[];
  Player? player;
  VideoController? video;
  SegmentSource? source;
  SegmentNames? names;
  List<VideoSegment> plan = [];
  SegmentationResult? result;
  CancellationToken? token;
  double preset = 30,
      progress = 0,
      position = 0,
      previewStart = 0,
      previewEnd = 1;
  bool busy = false,
      playing = false,
      ready = false,
      saved = false,
      allowLeave = false;
  bool fromReel = false;
  String status =
      'Select a video to split. No Quran alignment or overlays are required.';
  String previewLabel = 'Source video';
  String? validation, playbackError;
  AppServices get services => ref.read(servicesProvider);
  SegmentationService get processor => SegmentationService(services.engine);
  double get seconds =>
      preset == 0 ? double.tryParse(custom.text) ?? double.nan : preset;

  @override
  void initState() {
    super.initState();
    playbackError = services.playbackError;
    if (playbackError == null) {
      player = Player();
      video = VideoController(player!);
      subscriptions.add(
        player!.stream.position.listen((p) {
          if (!mounted) return;
          final t = p.inMicroseconds / 1000000;
          if (t >= previewEnd && playing) unawaited(player!.pause());
          setState(() => position = t.clamp(previewStart, previewEnd));
        }),
      );
      subscriptions.add(
        player!.stream.playing.listen((v) {
          if (mounted) setState(() => playing = v);
        }),
      );
      subscriptions.add(
        player!.stream.error.listen((e) {
          if (mounted) {
            setState(() => playbackError = 'Playback: $e');
          }
        }),
      );
    }
    if (widget.completedReel != null) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => run(() => loadSource(widget.completedReel!, completed: true)),
      );
    }
  }

  @override
  void dispose() {
    token?.cancel();
    for (final s in subscriptions) {
      unawaited(s.cancel());
    }
    final oldResult = result;
    unawaited(() async {
      await player?.dispose();
      await oldResult?.dispose();
    }());
    title.dispose();
    custom.dispose();
    super.dispose();
  }

  Future<void> run(Future<void> Function() operation) async {
    if (busy) return;
    setState(() {
      busy = true;
      token = null;
      progress = 0;
    });
    try {
      await operation();
    } on ExportCancelled {
      if (mounted) {
        setState(
          () => status =
              'Cancelled. Incomplete files from this attempt were removed.',
        );
      }
    } catch (e) {
      if (mounted) setState(() => status = e.toString());
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
          token = null;
        });
      }
    }
  }

  void replan() {
    try {
      final projectName = segmentName(title.text);
      plan = source == null ? [] : segmentPlan(source!.info.duration, seconds);
      names =
          names?.resized(plan.length) ?? SegmentNames(projectName, plan.length);
      names!.projectName = projectName;
      validation = null;
    } on FormatException catch (e) {
      validation = e.message;
      plan = [];
    }
  }

  Future<void> preview(
    File file,
    double start,
    double end,
    String label,
  ) async {
    await player?.pause();
    if (!mounted) return;
    setState(() {
      ready = false;
      playbackError = services.playbackError;
      previewStart = start;
      previewEnd = end;
      position = start;
      previewLabel = label;
    });
    try {
      await player?.open(Media(file.path), play: false);
      await player?.seek(Duration(microseconds: (start * 1000000).round()));
      if (mounted) setState(() => ready = player != null);
    } catch (e) {
      if (mounted) setState(() => playbackError = 'Preview unavailable: $e');
    }
  }

  Future<bool> discard() async {
    if (result == null) return true;
    if (!saved) {
      final answer = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Discard unsaved segments?'),
          content: const Text(
            'Save the segments first if you want to keep them. The source video is never changed.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Keep editing'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Discard segments'),
            ),
          ],
        ),
      );
      if (answer != true) return false;
    }
    await player?.stop();
    await result?.dispose();
    if (mounted) {
      setState(() {
        result = null;
        saved = false;
        ready = false;
      });
    }
    return true;
  }

  Future<void> loadSource(File file, {bool completed = false}) async {
    final inspected = await processor.inspect(file);
    if (!mounted || !await discard()) return;
    setState(() {
      source = inspected;
      fromReel = completed;
      title.text = completed && widget.projectName != null
          ? widget.projectName!
          : p.basenameWithoutExtension(file.path);
      names = null;
      replan();
      status = 'Source files are kept unchanged. Preview the proposed boundaries before processing.';
    });
    await preview(
      file,
      0,
      inspected.info.duration,
      completed ? 'Completed reel' : 'Source video',
    );
  }

  Future<void> chooseVideo() async {
    await player?.pause();
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['mp4', 'mov', 'mkv', 'webm', 'avi', 'm4v'],
    );
    final path = picked?.files.single.path;
    if (path != null) await loadSource(File(path));
  }

  Future<void> split() async {
    if (source == null || validation != null) return;
    await player?.pause();
    token = CancellationToken();
    final generated = await processor.split(
      source!,
      seconds,
      services.exports,
      token: token!,
      progress: (value, message) {
        if (mounted) {
          setState(() {
            progress = value;
            status = message;
          });
        }
      },
    );
    if (!mounted) {
      await generated.dispose();
      return;
    }
    setState(() {
      result = generated;
      saved = false;
      status =
          '${generated.files.length} MP4 segments ready. ${generated.copiedVideo ? 'Compatible streams copied without re-encoding.' : 'Re-encoded at frame boundaries.'} Preview, rename, then save them to a folder.';
    });
  }

  Future<void> save() async {
    token = CancellationToken();
    final filenames = names!.filenames;
    setState(() {
      progress = 0;
      status = 'Choose a folder for your segments…';
    });
    final outputs = await saveVideoBatch(
      [
        for (var i = 0; i < result!.files.length; i++)
          NamedVideoExport(result!.files[i], filenames[i]),
      ],
      token: token!,
      progress: (v) {
        if (mounted) {
          setState(() {
            progress = v;
            status = 'Saving segments…';
          });
        }
      },
    );
    if (mounted) {
      setState(() {
        saved = outputs != null;
        status = outputs == null
            ? 'Folder selection cancelled. Your generated segments are still available.'
            : 'Saved ${outputs.length} segments:\n${outputs.join('\n')}';
      });
    }
  }

  Future<void> rename(int index) async {
    var text = p.basenameWithoutExtension(names!.filenames[index]);
    String? error;
    final value = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text('Rename segment ${index + 1}'),
          content: TextFormField(
            initialValue: text,
            onChanged: (value) => text = value,
            autofocus: true,
            decoration: InputDecoration(
              labelText: 'Filename without .mp4',
              errorText: error,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                try {
                  Navigator.pop(context, segmentName(text));
                } on FormatException catch (e) {
                  update(() => error = e.message);
                }
              },
              child: const Text('Apply name'),
            ),
          ],
        ),
      ),
    );
    if (value != null && mounted) {
      setState(() {
        names!.rename(index, value);
        saved = false;
      });
    }
  }

  Future<void> previewSegment(int index) async {
    if (result == null) {
      final s = plan[index];
      await preview(
        source!.file,
        s.start,
        s.end,
        'Proposed segment ${index + 1}',
      );
    } else {
      final file = result!.files[index];
      final info = await services.engine.inspect(file.path);
      await preview(file, 0, info.duration, 'Generated segment ${index + 1}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final segments = result?.segments ?? plan;
    final filenames = names?.filenames ?? [];
    return PopScope(
      canPop: allowLeave || (!busy && (result == null || saved)),
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (busy) {
          setState(
            () => status = 'Cancel the current operation before leaving.',
          );
          return;
        }
        if (await discard() && mounted) {
          setState(() => allowLeave = true);
          await WidgetsBinding.instance.endOfFrame;
          if (context.mounted) Navigator.pop(context);
        }
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Video Trimmer')),
        body: CustomScrollView(
          key: const Key('trimmer-scroll'),
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.all(16),
              sliver: SliverToBoxAdapter(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1000),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (fromReel)
                          const Card(
                            child: Padding(
                              padding: EdgeInsets.all(12),
                              child: Text(
                                'Splitting the completed reel: its Quran overlays and synchronized audio are already included.',
                              ),
                            ),
                          ),
                        Wrap(
                          spacing: 12,
                          runSpacing: 8,
                          children: [
                            FilledButton.icon(
                              onPressed: busy ? null : () => run(chooseVideo),
                              icon: const Icon(Icons.video_file_outlined),
                              label: Text(
                                source == null
                                    ? 'Select video'
                                    : 'Choose another video',
                              ),
                            ),
                            if (source != null)
                              TextButton(
                                onPressed: busy
                                    ? null
                                    : () => run(
                                        () => preview(
                                          source!.file,
                                          0,
                                          source!.info.duration,
                                          'Source video',
                                        ),
                                      ),
                                child: const Text('Preview full source'),
                              ),
                          ],
                        ),
                        if (source != null) ...[
                          const SizedBox(height: 12),
                          Text(p.basename(source!.file.path)),
                          Text(
                            'Source duration ${timeLabel(source!.info.duration)} · ${source!.info.width} × ${source!.info.height}',
                          ),
                          const SizedBox(height: 12),
                          Text(previewLabel),
                          if (video != null)
                            SizedBox(
                              height: 300,
                              child: Video(
                                controller: video!,
                                controls: NoVideoControls,
                                fit: BoxFit.contain,
                              ),
                            ),
                          if (playbackError != null)
                            Text(
                              playbackError!,
                              style: const TextStyle(color: Colors.amber),
                            ),
                          Row(
                            children: [
                              IconButton(
                                tooltip: playing ? 'Pause video' : 'Play video',
                                onPressed: busy || !ready
                                    ? null
                                    : () => run(() async {
                                        if (playing) {
                                          await player!.pause();
                                        } else {
                                          if (position >= previewEnd - 0.01) {
                                            await player!.seek(
                                              Duration(
                                                microseconds:
                                                    (previewStart * 1000000)
                                                        .round(),
                                              ),
                                            );
                                          }
                                          await player!.play();
                                        }
                                      }),
                                icon: Icon(
                                  playing ? Icons.pause : Icons.play_arrow,
                                ),
                              ),
                              Expanded(
                                child: Slider(
                                  min: previewStart,
                                  max: previewEnd,
                                  value: position.clamp(
                                    previewStart,
                                    previewEnd,
                                  ),
                                  label: timeLabel(position),
                                  onChanged: busy || !ready
                                      ? null
                                      : (v) => setState(() => position = v),
                                  onChangeEnd: (v) => run(() async {
                                    await player?.seek(
                                      Duration(
                                        microseconds: (v * 1000000).round(),
                                      ),
                                    );
                                  }),
                                ),
                              ),
                            ],
                          ),
                          Text(
                            '${timeLabel(position)} / ${timeLabel(previewEnd)}',
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 16),
                          TextField(
                            controller: title,
                            enabled: !busy,
                            decoration: const InputDecoration(
                              labelText: 'Project name',
                            ),
                            onChanged: (_) => setState(() {
                              try {
                                names?.projectName = title.text;
                                validation = null;
                                if (result == null) replan();
                              } on FormatException catch (e) {
                                validation = e.message;
                              }
                              saved = false;
                            }),
                          ),
                          const SizedBox(height: 12),
                          DropdownButtonFormField<double>(
                            initialValue: preset,
                            decoration: const InputDecoration(
                              labelText: 'Segment duration',
                            ),
                            items: const [
                              DropdownMenuItem(
                                value: 30,
                                child: Text('30 seconds'),
                              ),
                              DropdownMenuItem(
                                value: 60,
                                child: Text('60 seconds'),
                              ),
                              DropdownMenuItem(
                                value: 90,
                                child: Text('90 seconds'),
                              ),
                              DropdownMenuItem(
                                value: 0,
                                child: Text('Custom seconds'),
                              ),
                            ],
                            onChanged: busy || result != null
                                ? null
                                : (v) => setState(() {
                                    preset = v!;
                                    replan();
                                  }),
                          ),
                          if (preset == 0) ...[
                            const SizedBox(height: 12),
                            TextField(
                              controller: custom,
                              enabled: !busy && result == null,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                    decimal: true,
                                  ),
                              decoration: const InputDecoration(
                                labelText: 'Custom duration in seconds',
                                hintText: 'For example: 12.5',
                              ),
                              onChanged: (_) => setState(replan),
                            ),
                          ],
                          const SizedBox(height: 12),
                          if (validation != null)
                            Text(
                              validation!,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          Text(
                            '${segments.length} ${result == null ? 'expected' : 'generated'} segments',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const Text(
                            'Cuts follow source frames; audio packet boundaries can add a small offset. Compatible keyframes are copied; other cuts use H.264/AAC encoding. Existing filenames receive numbered suffixes.',
                          ),
                          if (segments.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              child: LayoutBuilder(
                                builder: (context, bounds) => GestureDetector(
                                  onTapDown: busy
                                      ? null
                                      : (d) {
                                          final t =
                                              d.localPosition.dx /
                                              bounds.maxWidth *
                                              source!.info.duration;
                                          final index = segments.indexWhere(
                                            (s) => t < s.end,
                                          );
                                          unawaited(
                                            run(
                                              () => previewSegment(
                                                index < 0
                                                    ? segments.length - 1
                                                    : index,
                                              ),
                                            ),
                                          );
                                        },
                                  child: CustomPaint(
                                    size: const Size(double.infinity, 40),
                                    painter: _BoundaryPainter(
                                      segments,
                                      source!.info.duration,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          Wrap(
                            spacing: 12,
                            runSpacing: 8,
                            children: [
                              FilledButton.icon(
                                onPressed:
                                    busy ||
                                        validation != null ||
                                        plan.isEmpty ||
                                        result != null
                                    ? null
                                    : () => run(split),
                                icon: const Icon(Icons.content_cut),
                                label: const Text('Process segments'),
                              ),
                              if (result != null)
                                FilledButton.icon(
                                  onPressed: busy || validation != null
                                      ? null
                                      : () => run(save),
                                  icon: const Icon(Icons.folder_copy_outlined),
                                  label: const Text('Save all segments…'),
                                ),
                              if (result != null)
                                TextButton(
                                  onPressed: busy
                                      ? null
                                      : () => run(() async {
                                          if (await discard()) {
                                            replan();
                                            await preview(
                                              source!.file,
                                              0,
                                              source!.info.duration,
                                              'Source video',
                                            );
                                          }
                                        }),
                                  child: const Text('Change split settings'),
                                ),
                            ],
                          ),
                        ],
                        const SizedBox(height: 16),
                        if (busy)
                          LinearProgressIndicator(
                            value: token == null ? null : progress,
                          ),
                        if (busy && token != null)
                          TextButton(
                            onPressed: token!.cancel,
                            child: const Text('Cancel processing / saving'),
                          ),
                        SelectableText(status),
                        const SizedBox(height: 12),
                        if (segments.isNotEmpty)
                          const Text(
                            'Segments in source order · tap Preview to inspect a boundary',
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            SliverList.builder(
              itemCount: segments.length,
              itemBuilder: (context, index) {
                final segment = segments[index];
                return Center(
                  child: SizedBox(
                    width: 1000,
                    child: Card(
                      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${index + 1}. ${filenames[index]}',
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            Text(
                              '${timeLabel(segment.start)} – ${timeLabel(segment.end)} · ${timeLabel(segment.duration)}',
                            ),
                            Wrap(
                              spacing: 8,
                              children: [
                                TextButton.icon(
                                  onPressed: busy
                                      ? null
                                      : () => run(() => previewSegment(index)),
                                  icon: const Icon(Icons.play_arrow),
                                  label: const Text('Preview'),
                                ),
                                TextButton.icon(
                                  onPressed: busy ? null : () => rename(index),
                                  icon: const Icon(Icons.edit_outlined),
                                  label: const Text('Rename'),
                                ),
                                if (names!.isCustom(index))
                                  TextButton(
                                    onPressed: busy
                                        ? null
                                        : () => setState(() {
                                            names!.reset(index);
                                            saved = false;
                                          }),
                                    child: const Text('Use automatic name'),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],
        ),
      ),
    );
  }
}

class _BoundaryPainter extends CustomPainter {
  const _BoundaryPainter(this.segments, this.duration);
  final List<VideoSegment> segments;
  final double duration;
  @override
  void paint(Canvas canvas, Size size) {
    for (final s in segments) {
      final left = s.start / duration * size.width,
          right = s.end / duration * size.width;
      canvas.drawRect(
        Rect.fromLTRB(left, 0, right, size.height),
        Paint()
          ..color = s.index.isEven
              ? const Color(0xFF355E52)
              : const Color(0xFF648C78),
      );
      canvas.drawLine(
        Offset(left, 0),
        Offset(left, size.height),
        Paint()..color = const Color(0xFFE6CD91),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _BoundaryPainter oldDelegate) =>
      oldDelegate.segments != segments || oldDelegate.duration != duration;
}
