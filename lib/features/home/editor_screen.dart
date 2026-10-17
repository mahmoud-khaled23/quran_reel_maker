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
  int surah = 1, firstAyah = 1, lastAyah = 7;
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
      unawaited(backgroundPlayer!.setPlaylistMode(PlaylistMode.single));
      subscriptions.add(
        audioPlayer!.stream.position.listen((value) {
          if (!mounted || project == null) return;
          final time = value.inMilliseconds / 1000;
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
    if (project!.videoBackground) {
      final duration = backgroundPlayer?.state.duration.inMilliseconds ?? 0;
      final relative = ((seconds - project!.trimStart) * 1000).round();
      await backgroundPlayer?.seek(
        Duration(milliseconds: duration > 0 ? relative % duration : 0),
      );
    }
    if (mounted) setState(() => position = seconds);
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
    final current = project!;
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
    await pause();
    final relative = await services.store.importFile(
      project!.id,
      File(path),
      'audio',
    );
    edit(
      project!.copyWith(
        audio: relative,
        audioDuration: info.duration,
        trimStart: 0,
        trimEnd: info.duration,
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
    if (!info.hasVideo || (video && info.duration <= 0)) {
      throw MediaFailure('This background cannot be decoded.');
    }
    await pause();
    final relative = await services.store.importFile(
      project!.id,
      File(path),
      'background',
    );
    edit(project!.copyWith(background: relative, videoBackground: video));
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
                      '${item.cues.length} ayahs · ${item.duration.toStringAsFixed(1)} s',
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
      lastExport = null;
      await loadPlayers();
    }
  }

  Future<void> startExport() async {
    await pause();
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
          status = 'Your reel is ready. Save a copy to your chosen location.';
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
          '${value.duration.toStringAsFixed(3)} s selected · ${timeLabel(value.audioDuration)} source',
          style: const TextStyle(fontSize: 11),
        ),
      ],
      if (services.playbackError != null) Text(services.playbackError!),
    ],
  );
  Widget backgroundSection(ReelProject value) => section(
    '02',
    'Set the scene',
    'A quiet background. A vertical canvas. Your recitation in focus.',
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
        Text(
          value.videoBackground
              ? 'Video loops from its beginning. Background sound is muted.'
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
                onChanged: (n) => setState(() => lastAyah = n!),
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
            'After setup, alignment works offline. Select complete ayahs; omit introductions. Android supports manual timing.',
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
                        ? 'Manually edited · word draft cleared'
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
                                      '${word.start.toStringAsFixed(2)}–${word.end.toStringAsFixed(2)} s · ${quran.verse(cue.surah, cue.ayah).split(RegExp(r'\s+'))[word.index]}',
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

  Widget preview(ReelProject value, {bool compact = false}) {
    AyahCue? active;
    for (final cue in value.cues) {
      if (position >= cue.start && position < cue.end) {
        active = cue;
        break;
      }
    }
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
    final alignment = Alignment(value.cropX * 2 - 1, value.cropY * 2 - 1);
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
        const Row(
          children: [
            Text(
              'YOUR REEL',
              style: TextStyle(
                fontSize: 11,
                letterSpacing: 2,
                color: Color(0xFF9DB0A9),
              ),
            ),
            Spacer(),
            Text(
              '9:16 · 1080p · 30 fps',
              style: TextStyle(fontSize: 11, color: Color(0xFF9DB0A9)),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Center(
          child: SizedBox(
            height: compact ? 310 : 520,
            child: AspectRatio(
              aspectRatio: 9 / 16,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: ColoredBox(
                  color: Colors.black,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      background,
                      CustomPaint(
                        painter: AyahPainter(
                          text: active == null
                              ? null
                              : services.quran.verse(active.surah, active.ayah),
                          reference: active == null
                              ? null
                              : '${services.quran.surahs[active.surah - 1].name} · ${active.surah}:${active.ayah}',
                          attribution: value.cues.isNotEmpty,
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
