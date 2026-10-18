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
import '../../models/reel_project.dart';
import '../../services/export_destination.dart';
import '../audio_editor/time_field.dart';
import '../media_editor/trim_dialog.dart';
import '../export/export_settings.dart';
import '../preview/overlay_state.dart';
import '../synchronization/word_timing_dialog.dart';
import '../export/export_service.dart';
import '../preview/ayah_painter.dart';
import '../synchronization/alignment_engine.dart';
import '../synchronization/ayah_timeline.dart';

class EditorScreen extends ConsumerStatefulWidget {
  const EditorScreen({super.key});
  @override
  ConsumerState<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends ConsumerState<EditorScreen> {
  Player? audioPlayer, backgroundPlayer;
  VideoController? videoController;
  final subscriptions = <StreamSubscription<dynamic>>[];
  double position = 0, progress = 0;
  bool playing = false, busy = false, exporting = false;
  String status = 'Create a reel, one ayah at a time.';
  String? waveform;
  int surah = 1, firstAyah = 1, lastAyah = 7, firstWord = 0;
  int? lastWord;
  bool syncingVideo = false;
  CancellationToken? exportToken;
  AlignmentCancellation? alignmentToken;
  String? workerPath;
  bool aligning = false;
  File? lastExport;
  AppServices get services => ref.read(servicesProvider);
  ReelProject? get project => ref.read(editorProvider);
  bool get locked => busy || exporting;
  @override
  void initState() {
    super.initState();
    unawaited(loadWorkerPath());
    if (services.playbackError == null) {
      audioPlayer = Player();
      backgroundPlayer = Player();
      videoController = VideoController(backgroundPlayer!);
      unawaited(backgroundPlayer!.setVolume(0));

      subscriptions.add(
        audioPlayer!.stream.position.listen((value) {
          if (!mounted || project == null) return;
          final time = value.inMilliseconds / 1000;
          if (playing) unawaited(syncVideo(time));
          if (time >= project!.trimEnd && playing) unawaited(pause());
          setState(
            () => position = time.clamp(project!.trimStart, project!.trimEnd),
          );
        }),
      );
      subscriptions.add(
        audioPlayer!.stream.playing.listen((value) {
          if (mounted) setState(() => playing = value);
        }),
      );
      subscriptions.add(
        audioPlayer!.stream.error.listen((e) => message('Playback: $e')),
      );
      subscriptions.add(
        backgroundPlayer!.stream.error.listen(
          (e) => message('Video preview: $e'),
        ),
      );
    }
    if (project != null) return;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => action(() async {
        ref
            .read(editorProvider.notifier)
            .replace(await services.store.create());
      }),
    );
  }

  @override
  void dispose() {
    exportToken?.cancel();
    alignmentToken?.cancel();
    for (final subscription in subscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(audioPlayer?.dispose());
    unawaited(backgroundPlayer?.dispose());
    super.dispose();
  }

  void message(String text) {
    if (!mounted) return;
    setState(() => status = text);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text, maxLines: 3, overflow: TextOverflow.ellipsis),
        action: SnackBarAction(
          label: 'Details',
          onPressed: () => showDialog<void>(
            context: context,
            builder: (_) => AlertDialog(
              title: const Text('Details'),
              content: SingleChildScrollView(child: SelectableText(text)),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Close'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> action(Future<void> Function() operation) async {
    if (locked) return;
    setState(() => busy = true);
    try {
      await operation();
    } catch (error) {
      message(error.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  File get workerConfig => File(
    p.join(services.store.root.parent.path, 'alignment-worker-path.txt'),
  );
  Future<void> loadWorkerPath() async {
    try {
      if (await workerConfig.exists()) {
        final path = (await workerConfig.readAsString()).trim();
        if (mounted && path.isNotEmpty) setState(() => workerPath = path);
      }
    } catch (_) {
      /* A missing preference must not prevent manual editing. */
    }
  }

  Future<void> chooseWorker() async {
    if (!Platform.isLinux) {
      message(
        'The Python worker currently runs on Linux. Android retains manual timing with playback and editable boundaries.',
      );
      return;
    }
    final picked = await FilePicker.platform.pickFiles(
      dialogTitle:
          'Select scripts/alignment-worker.sh after running setup-alignment.sh',
    );
    final path = picked?.files.single.path;
    if (path == null) return;
    await workerConfig.parent.create(recursive: true);
    await workerConfig.writeAsString(path);
    if (mounted) setState(() => workerPath = path);
    message(
      'Local worker selected. Choose the matching ayahs and complete audio segment, then Align automatically.',
    );
  }

  Future<void> alignAutomatically() async {
    final original = project!;
    await pause();
    alignmentToken = AlignmentCancellation();
    setState(() {
      aligning = true;
      progress = 0;
      status = 'Starting local alignment…';
    });
    try {
      final cues = await services.alignment.align(
        AlignmentRequest(
          audioPath: mediaPath(original.audio!),
          trimStart: original.trimStart,
          trimEnd: original.trimEnd,
          surah: surah,
          firstAyah: firstAyah,
          lastAyah: lastAyah,
          workerExecutable: workerPath,
          firstWord: firstWord,
          lastWord: lastWord,
        ),
        cancellation: alignmentToken,
        onProgress: (value, text) {
          if (mounted) {
            setState(() {
              progress = value;
              status = text;
            });
          }
        },
      );
      if (!mounted || alignmentToken!.cancelled) return;
      for (final cue in cues) {
        final words = services.quran
            .verse(cue.surah, cue.ayah)
            .split(RegExp(r'\s+'));
        if (cue.words.any((word) => word.index >= words.length)) {
          throw const FormatException(
            'Worker returned an invalid Quran word reference. Existing timings were kept.',
          );
        }
      }
      if (edit(original.copyWith(cues: cues, reviewed: false))) {
        message(
          'Automatic draft ready. Listen to each ayah and inspect the word boundaries. Review is required before export.',
        );
      }
    } finally {
      if (mounted) setState(() => aligning = false);
      alignmentToken = null;
    }
  }

  bool edit(ReelProject value) {
    try {
      ref.read(editorProvider.notifier).edit(value);
      return true;
    } catch (error) {
      message(error.toString());
      return false;
    }
  }

  String mediaPath(String relative) =>
      p.join(services.store.directory(project!.id).path, relative);
  Future<void> pause() async {
    await audioPlayer?.pause();
    await backgroundPlayer?.pause();
  }

  Future<void> seek(double seconds) async {
    await audioPlayer?.seek(
      Duration(microseconds: (seconds * 1000000).round()),
    );
    await syncVideo(seconds, force: true);
    if (mounted) setState(() => position = seconds);
  }

  Future<void> syncVideo(double time, {bool force = false}) async {
    if (syncingVideo ||
        backgroundPlayer == null ||
        project?.videoBackground != true) {
      return;
    }
    final target = project!.videoTime(
      time,
      fallbackDuration: backgroundPlayer!.state.duration.inMilliseconds / 1000,
    );
    final actual = backgroundPlayer!.state.position.inMilliseconds / 1000;
    if (!force && (target - actual).abs() < 0.18) return;
    syncingVideo = true;
    try {
      await backgroundPlayer!.seek(
        Duration(milliseconds: (target * 1000).round()),
      );
      if (playing) await backgroundPlayer!.play();
    } finally {
      syncingVideo = false;
    }
  }

  Future<RangeValues?> previewTrim(
    String path,
    double duration,
    bool video, {
    double start = 0,
    double? end,
  }) async {
    await pause();
    if (!mounted) return null;
    return showDialog<RangeValues>(
      context: context,
      barrierDismissible: false,
      builder: (_) => MediaTrimDialog(
        path: path,
        duration: duration,
        video: video,
        start: start,
        end: end,
        playbackError: services.playbackError,
      ),
    );
  }

  Future<void> reviewTrim(bool video) async {
    final current = project!;
    final range = await previewTrim(
      mediaPath(video ? current.background! : current.audio!),
      video ? current.videoDuration : current.audioDuration,
      video,
      start: video ? current.videoTrimStart : current.trimStart,
      end: video ? current.videoTrimEnd : current.trimEnd,
    );
    if (range == null) return;
    edit(
      video
          ? current.copyWith(
              videoTrimStart: range.start,
              videoTrimEnd: range.end,
            )
          : current.copyWith(
              trimStart: range.start,
              trimEnd: range.end,
              reviewed: false,
            ),
    );
    await loadPlayers();
  }

  Future<void> togglePlayback() async {
    if (audioPlayer == null) {
      message(services.playbackError ?? 'Playback unavailable.');
      return;
    }
    if (playing) {
      await pause();
      return;
    }
    if (position < project!.trimStart || position >= project!.trimEnd - 0.05) {
      await seek(project!.trimStart);
    }
    if (project!.videoBackground) await backgroundPlayer?.play();
    await audioPlayer!.play();
  }

  Future<void> loadPlayers() async {
    await pause();
    var current = project!;
    if (current.videoBackground &&
        current.background != null &&
        current.videoDuration == 0) {
      final info = await services.engine.inspect(
        mediaPath(current.background!),
      );
      current = current.copyWith(
        videoDuration: info.duration,
        videoTrimEnd: info.duration,
        backgroundWidth: info.width,
        backgroundHeight: info.height,
      );
      if (!edit(current)) return;
    }
    if (current.videoBackground && current.background != null) {
      await backgroundPlayer?.open(
        Media(mediaPath(current.background!)),
        play: false,
      );
    } else {
      await backgroundPlayer?.stop();
    }
    if (current.audio != null) {
      await audioPlayer?.open(Media(mediaPath(current.audio!)), play: false);
      await seek(current.trimStart);
      final candidate = mediaPath('media/waveform.png');
      waveform = await File(candidate).exists() ? candidate : null;
    } else {
      await audioPlayer?.stop();
      waveform = null;
      position = 0;
      await syncVideo(current.trimStart, force: true);
    }
    if (mounted) setState(() {});
  }

  Future<void> importAudio() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['mp3', 'wav', 'm4a', 'aac', 'flac', 'ogg', 'opus'],
    );
    final path = picked?.files.single.path;
    if (path == null) return;
    final info = await services.engine.inspect(path);
    if (!info.hasAudio || !info.duration.isFinite || info.duration < 1 / 30) {
      throw MediaFailure('This file has no readable audio duration.');
    }
    final range = await previewTrim(path, info.duration, false);
    if (range == null) return;
    final relative = await services.store.importFile(
      project!.id,
      File(path),
      'audio',
    );
    edit(
      project!.copyWith(
        audio: relative,
        audioDuration: info.duration,
        trimStart: range.start,
        trimEnd: range.end,
        cues: [],
        reviewed: false,
      ),
    );
    await ref.read(editorProvider.notifier).save();
    final wave = mediaPath('media/waveform.png');
    try {
      if (await File(wave).exists()) await File(wave).delete();
      setState(() => status = 'Reading the full recitation waveform…');
      await services.engine.waveform(mediaPath(relative), wave);
      await FileImage(File(wave)).evict();
      waveform = wave;
    } catch (error) {
      if (await File(wave).exists()) await File(wave).delete();
      waveform = null;
      message('Audio imported. Waveform unavailable: $error');
    }
    await loadPlayers();
    if (mounted) {
      setState(
        () => status = 'Audio imported. Choose the segment you want to share.',
      );
    }
  }

  Future<void> importBackground(bool video) async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: video
          ? ['mp4', 'mov', 'mkv', 'webm']
          : ['png', 'jpg', 'jpeg', 'webp'],
    );
    final path = picked?.files.single.path;
    if (path == null) return;
    final info = await services.engine.inspect(path);
    if (!info.hasVideo ||
        info.width <= 0 ||
        info.height <= 0 ||
        (video && (!info.duration.isFinite || info.duration < 1 / 30))) {
      throw MediaFailure('This background cannot be decoded.');
    }
    RangeValues? range;
    if (video) {
      range = await previewTrim(path, info.duration, true);
      if (range == null) return;
    }
    await pause();
    final relative = await services.store.importFile(
      project!.id,
      File(path),
      'background',
    );
    edit(
      project!.copyWith(
        background: relative,
        videoBackground: video,
        backgroundWidth: info.width,
        backgroundHeight: info.height,
        videoDuration: video ? info.duration : 0,
        videoTrimStart: range?.start ?? 0,
        videoTrimEnd: range?.end ?? 0,
        originalAspect: video,
      ),
    );
    await ref.read(editorProvider.notifier).save();
    await loadPlayers();
  }

  Future<void> library() async {
    await ref.read(editorProvider.notifier).save();
    final projects = await services.store.list();
    if (!mounted) return;
    final selected = await showDialog<ReelProject>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Your projects'),
        content: SizedBox(
          width: 460,
          child: ListView(
            shrinkWrap: true,
            children: projects
                .map(
                  (item) => ListTile(
                    leading: const Icon(Icons.video_library_outlined),
                    title: Text(item.title),
                    subtitle: Text(
                      '${item.cues.length} ayahs · ${timeLabel(item.duration)}',
                    ),
                    onTap: () => Navigator.pop(context, item),
                  ),
                )
                .toList(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
    if (selected != null) {
      await pause();
      ref.read(editorProvider.notifier).replace(selected);
      if (selected.cues.isNotEmpty) {
        surah = selected.cues.first.surah;
        firstAyah = selected.cues.first.ayah;
        // A saved timeline can contain multiple surahs or repeated ayahs.
        // Keep the single-surah selection controls within their valid range.
        lastAyah = selected.cues
            .where((cue) => cue.surah == surah)
            .map((cue) => cue.ayah)
            .reduce((a, b) => a > b ? a : b);
      }
      firstWord = selected.cues.isEmpty ? 0 : selected.cues.first.firstWord;
      lastWord = selected.cues.isEmpty
          ? null
          : selected.cues
                .lastWhere((c) => c.surah == surah && c.ayah == lastAyah)
                .lastWord;
      lastExport = null;
      await loadPlayers();
    }
  }

  Future<void> startExport() async {
    await pause();
    final name = await availableExport(services.exports, project!.title);
    if (!mounted) return;
    var selection = project!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('Export video'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Filename: ${p.basename(name.path)}'),
                const SizedBox(height: 16),
                DropdownButtonFormField<int>(
                  initialValue: selection.exportResolution,
                  decoration: const InputDecoration(labelText: 'Resolution'),
                  items: exportResolutions
                      .map(
                        (r) => DropdownMenuItem(value: r, child: Text('${r}p')),
                      )
                      .toList(),
                  onChanged: (r) => update(
                    () => selection = selection.copyWith(exportResolution: r),
                  ),
                ),
                const SizedBox(height: 12),
                Text('${exportSize(selection)} · 30 fps · H.264 / AAC'),
                const Text(
                  'Resolution sets the short edge. Source video limits the output size. Existing filenames receive a numbered suffix.',
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Render MP4'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true) return;
    if (!edit(selection)) return;
    await ref.read(editorProvider.notifier).save();
    final current = project!;
    setState(() {
      exporting = true;
      progress = 0;
      status = 'Rendering your reel…';
    });
    exportToken = CancellationToken();
    try {
      final file = await ExportService(services.engine, services.quran).export(
        current,
        services.store.directory(current.id),
        services.exports,
        token: exportToken!,
        progress: (value) {
          if (mounted) setState(() => progress = value);
        },
      );
      if (mounted) {
        setState(() {
          lastExport = file;
          status =
              '${p.basename(file.path)} is ready. Save a copy to your chosen location.';
        });
      }
    } on ExportCancelled {
      if (mounted) {
        setState(() => status = 'Export cancelled. Temporary files removed.');
      }
    } catch (error) {
      message(error.toString());
    } finally {
      if (mounted) setState(() => exporting = false);
    }
  }

  bool setTrim(double start, double end) {
    final value = project!.copyWith(
      trimStart: start,
      trimEnd: end,
      reviewed: false,
    );
    if (value.validate().isNotEmpty) {
      message(value.validate().join('\n'));
      return false;
    }
    edit(value);
    unawaited(
      action(() async {
        await pause();
        await seek(start);
      }),
    );
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final current = ref.watch(editorProvider);
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
              child: Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 32,
                runSpacing: 12,
                children: [
                  const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.auto_stories_outlined,
                        color: Color(0xFFA4E4C5),
                        size: 36,
                      ),
                      SizedBox(width: 14),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Quran Reel Maker',
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            'RECITE · COMPOSE · SHARE',
                            style: TextStyle(
                              fontSize: 10,
                              letterSpacing: 2.5,
                              color: Color(0xFF91A59E),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  Wrap(
                    spacing: 6,
                    runSpacing: 8,
                    children: [
                      TextButton.icon(
                        onPressed: locked
                            ? null
                            : () => action(() async {
                                await ref.read(editorProvider.notifier).save();
                                ref
                                    .read(editorProvider.notifier)
                                    .replace(await services.store.create());
                                firstWord = 0;
                                lastWord = null;
                                lastExport = null;
                                await loadPlayers();
                              }),
                        icon: const Icon(Icons.add),
                        label: const Text('New'),
                      ),
                      TextButton.icon(
                        onPressed: locked ? null : () => action(library),
                        icon: const Icon(Icons.folder_open),
                        label: const Text('Projects'),
                      ),
                      OutlinedButton.icon(
                        onPressed: current == null || locked
                            ? null
                            : () => action(() async {
                                await ref.read(editorProvider.notifier).save();
                                message(
                                  'Project saved with its imported media.',
                                );
                              }),
                        icon: const Icon(Icons.save_outlined),
                        label: const Text('Save'),
                      ),
                      FilledButton.icon(
                        onPressed:
                            current?.audio == null ||
                                current?.background == null ||
                                locked
                            ? null
                            : () => action(startExport),
                        icon: const Icon(Icons.file_upload_outlined),
                        label: const Text('Export MP4'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (busy && !exporting) const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: current == null
                  ? const Center(child: CircularProgressIndicator())
                  : LayoutBuilder(
                      builder: (context, constraints) {
                        final controls = AbsorbPointer(
                          absorbing: locked,
                          child: Column(
                            children: [
                              audioSection(current),
                              backgroundSection(current),
                              ayahSection(current),
                            ],
                          ),
                        );
                        if (constraints.maxWidth >= 1000) {
                          return Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: SingleChildScrollView(
                                  padding: const EdgeInsets.fromLTRB(
                                    20,
                                    8,
                                    12,
                                    20,
                                  ),
                                  child: controls,
                                ),
                              ),
                              SizedBox(
                                width: constraints.maxWidth > 1400 ? 480 : 390,
                                child: SingleChildScrollView(
                                  padding: const EdgeInsets.fromLTRB(
                                    12,
                                    8,
                                    24,
                                    20,
                                  ),
                                  child: preview(current),
                                ),
                              ),
                            ],
                          );
                        }
                        return SingleChildScrollView(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            children: [
                              preview(current, compact: true),
                              const SizedBox(height: 16),
                              controls,
                            ],
                          ),
                        );
                      },
                    ),
            ),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
              color: const Color(0xFF182222),
              child: Column(
                children: [
                  if (aligning) ...[
                    LinearProgressIndicator(value: progress),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: () => alignmentToken?.cancel(),
                        child: const Text('Cancel alignment'),
                      ),
                    ),
                  ],
                  if (exporting) ...[
                    LinearProgressIndicator(value: progress),
                    Row(
                      children: [
                        Text('Exporting ${(progress * 100).round()}%'),
                        const Spacer(),
                        TextButton(
                          onPressed: () => exportToken?.cancel(),
                          child: const Text('Cancel export'),
                        ),
                      ],
                    ),
                  ],
                  Row(
                    children: [
                      const Icon(
                        Icons.offline_bolt_outlined,
                        size: 16,
                        color: Color(0xFF9EE2C2),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          status,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Sources & licenses',
                        onPressed: () => showLicensePage(
                          context: context,
                          applicationName: 'Quran Reel Maker',
                          applicationVersion: '0.1.0',
                          applicationLegalese: 'Quran: https://tanzil.net/ · Uthmani 1.1 · CC BY 3.0\nAmiri Quran: OFL 1.1\nFFmpeg Android: GPL v3 components. See THIRD_PARTY_NOTICES.md.',
                        ),
                        icon: const Icon(Icons.info_outline, size: 18),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget section(
    String number,
    String title,
    String subtitle,
    List<Widget> children,
  ) => Card(
    margin: const EdgeInsets.only(bottom: 16),
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                number,
                style: const TextStyle(color: Color(0xFF9EE2C2), fontSize: 13),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            style: const TextStyle(color: Color(0xFF9DB0A9), fontSize: 12),
          ),
          const SizedBox(height: 20),
          ...children,
        ],
      ),
    ),
  );
  Widget audioSection(ReelProject value) => section(
    '01',
    'The recitation',
    'Import the full audio, then find the moment you want to share.',
    [
      TextFormField(
        key: ValueKey(value.id),
        initialValue: value.title,
        decoration: const InputDecoration(labelText: 'Project name'),
        onChanged: (title) => edit(project!.copyWith(title: title)),
      ),
      const SizedBox(height: 16),
      OutlinedButton.icon(
        onPressed: () => action(importAudio),
        icon: const Icon(Icons.audio_file_outlined),
        label: Text(value.audio == null ? 'Import audio' : 'Replace audio'),
      ),
      if (value.audio != null) ...[
        const SizedBox(height: 16),
        if (waveform != null)
          Container(
            color: const Color(0xFF0E1717),
            height: 80,
            width: double.infinity,
            child: Image.file(
              File(waveform!),
              fit: BoxFit.fill,
              errorBuilder: (_, _, _) => const SizedBox(),
            ),
          )
        else
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text(
              'Waveform unavailable · precise trimming is still available',
            ),
          ),
        RangeSlider(
          values: RangeValues(value.trimStart, value.trimEnd),
          min: 0,
          max: value.audioDuration,
          labels: RangeLabels(
            timeLabel(value.trimStart),
            timeLabel(value.trimEnd),
          ),
          onChanged: (range) {
            if (range.end - range.start >= 1 / 30) {
              edit(
                value.copyWith(
                  trimStart: range.start,
                  trimEnd: range.end,
                  reviewed: false,
                ),
              );
            }
          },
          onChangeEnd: (range) => setTrim(range.start, range.end),
        ),
        Row(
          children: [
            Expanded(
              child: TimeField(
                label: 'Trim start',
                value: value.trimStart,
                onChanged: (start) => setTrim(start, project!.trimEnd),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TimeField(
                label: 'Trim end',
                value: value.trimEnd,
                onChanged: (end) => setTrim(project!.trimStart, end),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          '${timeLabel(value.duration)} selected · ${timeLabel(value.audioDuration)} source',
          style: const TextStyle(fontSize: 11),
        ),
      ],
      if (value.audio != null)
        TextButton.icon(
          onPressed: () => action(() => reviewTrim(false)),
          icon: const Icon(Icons.content_cut),
          label: const Text('Preview & trim audio'),
        ),
      if (services.playbackError != null) Text(services.playbackError!),
    ],
  );
  Widget backgroundSection(ReelProject value) => section(
    '02',
    'Set the scene',
    'Preview the source, choose its segment, then compose your reel.',
    [
      Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          OutlinedButton.icon(
            onPressed: () => action(() => importBackground(false)),
            icon: const Icon(Icons.image_outlined),
            label: const Text('Import image'),
          ),
          OutlinedButton.icon(
            onPressed: () => action(() => importBackground(true)),
            icon: const Icon(Icons.movie_outlined),
            label: const Text('Import video'),
          ),
        ],
      ),
      if (value.background != null) ...[
        const SizedBox(height: 16),
        SegmentedButton<BackgroundFit>(
          segments: const [
            ButtonSegment(
              value: BackgroundFit.cover,
              label: Text('Fill & crop'),
              icon: Icon(Icons.crop),
            ),
            ButtonSegment(
              value: BackgroundFit.contain,
              label: Text('Fit'),
              icon: Icon(Icons.fit_screen),
            ),
          ],
          selected: {value.fit},
          onSelectionChanged: (fit) => edit(value.copyWith(fit: fit.single)),
        ),
        if (value.fit == BackgroundFit.cover) ...[
          const SizedBox(height: 12),
          const Text(
            'Crop focus · horizontal / vertical',
            style: TextStyle(fontSize: 12),
          ),
          Slider(
            value: value.cropX,
            onChanged: (x) => edit(value.copyWith(cropX: x)),
          ),
          Slider(
            value: value.cropY,
            onChanged: (y) => edit(value.copyWith(cropY: y)),
          ),
        ],
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Keep original aspect ratio'),
          value: value.originalAspect,
          onChanged: (v) => edit(value.copyWith(originalAspect: v)),
          subtitle: const Text(
            'Turn off for a portrait 9:16 reel with Fit or Fill & crop.',
          ),
        ),
        if (value.videoBackground && value.videoDuration > 0) ...[
          Text(
            '${timeLabel(value.videoTrimStart)} – ${timeLabel(value.videoTrimEnd)} / ${timeLabel(value.videoDuration)}',
          ),
          OutlinedButton.icon(
            onPressed: () => action(() => reviewTrim(true)),
            icon: const Icon(Icons.content_cut),
            label: const Text('Preview & trim video'),
          ),
        ],
        Text(
          value.videoBackground
              ? 'Only the selected video segment loops. Background sound is muted.'
              : 'Image holds for the selected audio duration.',
          style: const TextStyle(fontSize: 11, color: Color(0xFF9DB0A9)),
        ),
      ],
    ],
  );
  Widget ayahSection(ReelProject value) {
    final quran = services.quran;
    final selected = quran.surahs[surah - 1];
    return section(
      '03',
      'Words that stay with you',
      'Verified Uthmani text · Tanzil.net · 6,236 ayahs available offline',
      [
        DropdownButtonFormField<int>(
          initialValue: surah,
          key: ValueKey('surah-$surah'),
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Surah'),
          items: quran.surahs
              .map(
                (s) => DropdownMenuItem(
                  value: s.number,
                  child: Text('${s.number}. ${s.name}  ${s.arabic}'),
                ),
              )
              .toList(),
          onChanged: (number) => setState(() {
            firstWord = 0;
            lastWord = null;
            surah = number!;
            firstAyah = 1;
            lastAyah = quran.surahs[surah - 1].count.clamp(1, 7);
          }),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<int>(
                initialValue: firstAyah,
                key: ValueKey('first-$surah-$firstAyah'),
                decoration: const InputDecoration(labelText: 'First ayah'),
                items: List.generate(
                  selected.count,
                  (i) =>
                      DropdownMenuItem(value: i + 1, child: Text('${i + 1}')),
                ),
                onChanged: (n) => setState(() {
                  firstWord = 0;
                  lastWord = null;
                  firstAyah = n!;
                  if (lastAyah < firstAyah) lastAyah = firstAyah;
                }),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: DropdownButtonFormField<int>(
                initialValue: lastAyah,
                key: ValueKey('last-$surah-$lastAyah'),
                decoration: const InputDecoration(labelText: 'Last ayah'),
                items: List.generate(
                  selected.count - firstAyah + 1,
                  (i) => DropdownMenuItem(
                    value: i + firstAyah,
                    child: Text('${i + firstAyah}'),
                  ),
                ),
                onChanged: (n) => setState(() {
                  lastAyah = n!;
                  lastWord = null;
                }),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: wordSelector(
                'First recited word',
                quran.verse(surah, firstAyah),
                firstWord,
                (v) => setState(() {
                  firstWord = v;
                  if (firstAyah == lastAyah &&
                      lastWord != null &&
                      lastWord! < v) {
                    lastWord = v;
                  }
                }),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: wordSelector(
                'Last recited word',
                quran.verse(surah, lastAyah),
                lastWord ??
                    quran.verse(surah, lastAyah).split(RegExp(r'\s+')).length -
                        1,
                (v) => setState(() {
                  lastWord = v;
                  if (firstAyah == lastAyah && firstWord > v) firstWord = v;
                }),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            FilledButton.tonalIcon(
              onPressed: value.audio == null
                  ? null
                  : () {
                      try {
                        edit(
                          value.copyWith(
                            cues: manualTimingGrid(
                              surah: surah,
                              first: firstAyah,
                              last: lastAyah,
                              start: value.trimStart,
                              end: value.trimEnd,
                              firstWord: firstWord,
                              lastWord: lastWord,
                            ),
                            reviewed: false,
                          ),
                        );
                      } catch (error) {
                        message(error.toString());
                      }
                    },
              icon: const Icon(Icons.playlist_add),
              label: const Text('Create manual timings'),
            ),
            TextButton.icon(
              onPressed: value.audio == null
                  ? null
                  : () => action(alignAutomatically),
              icon: const Icon(Icons.model_training),
              label: Text(
                value.cues.any((c) => c.alignmentModel != null)
                    ? 'Rerun alignment'
                    : 'Align automatically',
              ),
            ),
            TextButton(
              onPressed: () => action(chooseWorker),
              child: const Text('Choose local worker'),
            ),
          ],
        ),
        const Padding(
          padding: EdgeInsets.only(top: 8),
          child: SelectableText(
            'Linux setup: ./scripts/setup-alignment.sh, then select scripts/alignment-worker.sh. '
            'After setup, alignment works offline. Select the matching ayahs and boundary words; omit introductions and repetitions. Android supports manual timing.',
            style: TextStyle(fontSize: 11, color: Color(0xFF9DB0A9)),
          ),
        ),
        if (value.cues.isNotEmpty) ...[
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text(
              'Manual grids are evenly spaced; automatic timings are drafts requiring review. Listen and adjust each ayah. '
              'All timestamps use the original audio. Mark uses the playhead. Gaps are allowed; overlaps are not.',
              style: TextStyle(fontSize: 12, color: Color(0xFFE4CB8F)),
            ),
          ),
          AyahTimeline(
            project: value,
            position: position,
            onSeek: (t) => action(() async {
              await pause();
              await seek(t);
            }),
          ),
          const SizedBox(height: 12),
          ...value.cues.asMap().entries.map((entry) {
            final cue = entry.value;
            bool update(double start, double end) {
              final cues = List<AyahCue>.of(project!.cues);
              cues[entry.key] = cue.copyWith(start: start, end: end);
              return edit(project!.copyWith(cues: cues, reviewed: false));
            }

            return Container(
              key: ValueKey('${value.id}-${cue.surah}-${cue.ayah}'),
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFF101919),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Text(
                        '${cue.surah}:${cue.ayah}',
                        style: const TextStyle(color: Color(0xFF9EE2C2)),
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: 'Seek to ayah',
                        onPressed: () => action(() async {
                          await pause();
                          await seek(
                            cue.start.clamp(value.trimStart, value.trimEnd),
                          );
                        }),
                        icon: const Icon(Icons.play_circle_outline),
                      ),
                    ],
                  ),
                  Text(
                    cue.timingSource == 'automatic'
                        ? 'Automatic draft · acoustic score ${cue.alignmentScore?.toStringAsFixed(2) ?? "unknown"} (not confidence)'
                        : cue.timingSource == 'edited'
                        ? 'Manually edited'
                        : 'Manual timing',
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFFE4CB8F),
                    ),
                  ),
                  for (final warning in cue.warnings)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        warning,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xFFE4CB8F),
                        ),
                      ),
                    ),
                  Text(
                    quran.verse(cue.surah, cue.ayah),
                    textDirection: TextDirection.rtl,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontFamily: 'AmiriQuran',
                      fontSize: 25,
                      height: 1.9,
                    ),
                  ),
                  if (cue.words.isEmpty)
                    const Text(
                      'Passage timing: the selected excerpt stays visible for this interval. Add word timings for progressive display.',
                      style: TextStyle(fontSize: 11, color: Colors.amber),
                    ),
                  TextButton.icon(
                    icon: const Icon(Icons.edit_note),
                    label: const Text('Edit recited words & timing'),
                    onPressed: () => action(() async {
                      await pause();
                      if (!mounted) return;
                      final result = await showDialog<AyahCue>(
                        context: context,
                        builder: (_) => WordTimingDialog(
                          cue: cue,
                          verse: quran.verse(cue.surah, cue.ayah),
                        ),
                      );
                      if (result != null) {
                        final cues = List<AyahCue>.of(project!.cues)
                          ..[entry.key] = result;
                        if (edit(
                          project!.copyWith(cues: cues, reviewed: false),
                        )) {
                          setState(() {
                            if (cue.surah == surah && cue.ayah == firstAyah) {
                              firstWord = result.firstWord;
                            }
                            if (cue.surah == surah && cue.ayah == lastAyah) {
                              lastWord = result.lastWord;
                            }
                          });
                        }
                      }
                    }),
                  ),
                  if (cue.words.isNotEmpty)
                    Material(
                      type: MaterialType.transparency,
                      child: ExpansionTile(
                        tilePadding: EdgeInsets.zero,
                        title: const Text(
                          'Word boundaries · tap to seek',
                          style: TextStyle(fontSize: 12),
                        ),
                        children: [
                          Wrap(
                            spacing: 6,
                            children: cue.words
                                .map(
                                  (word) => ActionChip(
                                    label: Text(
                                      '${timeLabel(word.start)}–${timeLabel(word.end)} · ${quran.verse(cue.surah, cue.ayah).split(RegExp(r'\s+'))[word.index]}',
                                      textDirection: TextDirection.ltr,
                                    ),
                                    onPressed: () => action(() async {
                                      await pause();
                                      await seek(
                                        word.start.clamp(
                                          value.trimStart,
                                          value.trimEnd,
                                        ),
                                      );
                                    }),
                                  ),
                                )
                                .toList(),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TimeField(
                          label: 'Start',
                          value: cue.start,
                          onChanged: (t) => update(t, cue.end),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TimeField(
                          label: 'End',
                          value: cue.end,
                          onChanged: (t) => update(cue.start, t),
                        ),
                      ),
                    ],
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      TextButton(
                        onPressed: () => update(position, cue.end),
                        child: const Text('Mark start'),
                      ),
                      TextButton(
                        onPressed: () => update(cue.start, position),
                        child: const Text('Mark end'),
                      ),
                    ],
                  ),
                ],
              ),
            );
          }),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: value.reviewed,
            onChanged: (reviewed) => edit(value.copyWith(reviewed: reviewed)),
            title: const Text('I reviewed the ayahs and their timing'),
            subtitle: const Text(
              'Check the recitation matches the selected text.',
              style: TextStyle(fontSize: 12),
            ),
          ),
          TextButton(
            onPressed: () => edit(value.copyWith(cues: [], reviewed: false)),
            child: const Text('Remove text overlays'),
          ),
        ],
      ],
    );
  }

  Widget wordSelector(
    String label,
    String verse,
    int selected,
    void Function(int) changed,
  ) {
    final words = verse.split(RegExp(r'\s+'));
    return DropdownButtonFormField<int>(
      key: ValueKey('$label-$verse-$selected'),
      initialValue: selected,
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      items: words
          .asMap()
          .entries
          .map(
            (e) => DropdownMenuItem(
              value: e.key,
              child: Text(
                '${e.key + 1}. ${e.value}',
                overflow: TextOverflow.ellipsis,
              ),
            ),
          )
          .toList(),
      onChanged: (v) => changed(v!),
    );
  }

  Widget preview(ReelProject value, {bool compact = false}) {
    final overlay = overlayAt(value, position);
    final active = overlay == null ? null : value.cues[overlay.cueIndex];
    final size = exportSize(value);
    Widget background = Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF355E52), Color(0xFF10221E), Color(0xFF57604B)],
        ),
      ),
      child: const Center(
        child: Icon(
          Icons.landscape_outlined,
          color: Color(0x3382DFBB),
          size: 90,
        ),
      ),
    );
    final fit = value.fit == BackgroundFit.cover
        ? BoxFit.cover
        : BoxFit.contain;
    final alignment = value.fit == BackgroundFit.cover
        ? Alignment(value.cropX * 2 - 1, value.cropY * 2 - 1)
        : Alignment.center;
    if (value.background != null) {
      if (value.videoBackground && videoController != null) {
        background = Video(
          controller: videoController!,
          controls: NoVideoControls,
          fit: fit,
          alignment: alignment,
          fill: Colors.black,
        );
      } else if (!value.videoBackground) {
        background = Image.file(
          File(mediaPath(value.background!)),
          fit: fit,
          alignment: alignment,
          errorBuilder: (_, _, _) =>
              const Center(child: Text('Cannot preview this image')),
        );
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Text(
              'YOUR REEL',
              style: TextStyle(
                fontSize: 11,
                letterSpacing: 2,
                color: Color(0xFF9DB0A9),
              ),
            ),
            Spacer(),
            Text(
              '$size · 30 fps',
              style: TextStyle(fontSize: 11, color: Color(0xFF9DB0A9)),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: compact ? 310 : 520),
            child: AspectRatio(
              aspectRatio: size.width / size.height,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: ColoredBox(
                  color: Colors.black,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      background,
                      LayoutBuilder(
                        // Draggable claims movement before the enclosing vertical
                        // scroll view. A pan recognizer loses vertical drags to it.
                        builder: (context, bounds) => Draggable<Object>(
                          feedback: const SizedBox.shrink(),
                          maxSimultaneousDrags: locked ? 0 : 1,
                          onDragUpdate: locked
                              ? null
                              : (details) => edit(
                                  project!.copyWith(
                                    overlayX:
                                        (project!.overlayX +
                                                details.delta.dx /
                                                    bounds.maxWidth)
                                            .clamp(0, 1),
                                    overlayY:
                                        (project!.overlayY +
                                                details.delta.dy /
                                                    bounds.maxHeight)
                                            .clamp(0, 1),
                                  ),
                                ),
                          child: CustomPaint(
                            painter: AyahPainter(
                              text: active == null
                                  ? null
                                  : overlay!.text(
                                      services.quran.verse(
                                        active.surah,
                                        active.ayah,
                                      ),
                                    ),
                              reference: active == null
                                  ? null
                                  : '${services.quran.surahs[active.surah - 1].name} · ${active.surah}:${active.ayah}',
                              attribution: value.cues.isNotEmpty,
                              outputSize: Size(
                                size.width.toDouble(),
                                size.height.toDouble(),
                              ),
                              x: value.overlayX,
                              y: value.overlayY,
                              fontColor: value.fontColor,
                              textBackground: value.textBackground,
                            ),
                          ),
                        ),
                      ),
                      if (value.background == null)
                        const Positioned(
                          top: 40,
                          left: 20,
                          right: 20,
                          child: Text(
                            'Your background goes here',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Color(0xFFBDD0C6),
                              fontSize: 12,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            IconButton.filled(
              tooltip: playing ? 'Pause preview' : 'Play preview',
              onPressed: value.audio == null || locked
                  ? null
                  : () => action(togglePlayback),
              icon: Icon(playing ? Icons.pause : Icons.play_arrow),
            ),
            Expanded(
              child: Slider(
                value: value.audio == null
                    ? 0
                    : position.clamp(value.trimStart, value.trimEnd),
                min: value.trimStart,
                max: value.trimEnd > value.trimStart ? value.trimEnd : 1,
                onChanged: value.audio == null || locked
                    ? null
                    : (time) => setState(() => position = time),
                onChangeEnd: (time) => action(() async {
                  await pause();
                  await seek(time);
                }),
              ),
            ),
          ],
        ),
        Text(
          '${timeLabel(position)} / ${timeLabel(value.trimEnd)}',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 12, color: Color(0xFF9DB0A9)),
        ),
        const SizedBox(height: 18),
        ExpansionTile(
          title: const Text('Text position & color'),
          subtitle: const Text('Drag on the preview or use these controls'),
          children: [
            const Text('Horizontal position'),
            Slider(
              value: value.overlayX,
              onChanged: locked
                  ? null
                  : (x) => edit(value.copyWith(overlayX: x)),
            ),
            const Text('Vertical position'),
            Slider(
              value: value.overlayY,
              onChanged: locked
                  ? null
                  : (y) => edit(value.copyWith(overlayY: y)),
            ),
            Wrap(
              spacing: 8,
              children: [
                for (final color in const [
                  0xFFFFFFFF,
                  0xFFFFD77A,
                  0xFFA4E4C5,
                  0xFF90CAF9,
                  0xFF000000,
                ])
                  ChoiceChip(
                    label: Icon(Icons.format_color_text, color: Color(color)),
                    selected: value.fontColor == color,
                    onSelected: locked
                        ? null
                        : (_) => edit(value.copyWith(fontColor: color)),
                  ),
              ],
            ),
            SwitchListTile(
              title: const Text('Text background'),
              value: value.textBackground,
              onChanged: locked
                  ? null
                  : (v) => edit(value.copyWith(textBackground: v)),
            ),
          ],
        ),
        if (lastExport != null)
          FilledButton.tonalIcon(
            onPressed: locked
                ? null
                : () => action(() async {
                    final path = await saveExportCopy(lastExport!);
                    if (path != null) message('Saved: $path');
                  }),
            icon: const Icon(Icons.download),
            label: const Text('Save exported video…'),
          ),
        const SizedBox(height: 12),
        const Text(
          'Made locally. Your audio and media stay on this device.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 11, color: Color(0xFF91A59E)),
        ),
      ],
    );
  }
}
