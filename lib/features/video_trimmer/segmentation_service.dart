import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

import '../../media_engine/media_engine.dart';
import 'segment_plan.dart';

class SegmentSource {
  const SegmentSource(
    this.file,
    this.info,
    this.video,
    this.audio,
    this.formatStart,
  );
  final File file;
  final MediaInfo info;
  final Map<String, dynamic> video;
  final List<Map<String, dynamic>> audio;
  final double formatStart;
  double get fps {
    final ratio = '${video['avg_frame_rate']}'
        .split('/')
        .map(double.tryParse)
        .toList();
    final value =
        ratio.length == 2 &&
            ratio[0] != null &&
            ratio[1] != null &&
            ratio[1]! > 0
        ? ratio[0]! / ratio[1]!
        : 0;
    return value.isFinite && value > 0 ? value.toDouble() : 0;
  }
}

class SegmentationResult {
  const SegmentationResult(
    this.directory,
    this.files,
    this.segments,
    this.copiedVideo,
  );
  final Directory directory;
  final List<File> files;
  final List<VideoSegment> segments;
  final bool copiedVideo;
  Future<void> dispose() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}

/// One FFmpeg pass assigns each video packet to exactly one MP4. No independent
/// input seeks per segment, no repeated source decodes and no Quran dependency.
class SegmentationService {
  const SegmentationService(this.engine);
  final MediaEngine engine;

  Future<SegmentSource> inspect(File file) async {
    if (!await file.exists()) {
      throw MediaFailure('The source video is missing. Select it again.');
    }
    final info = await engine.inspect(file.path);
    if (!info.hasVideo ||
        !info.duration.isFinite ||
        info.duration <= 0 ||
        info.width < 2 ||
        info.height < 2) {
      throw MediaFailure(
        'Select a readable video with a finite duration. Still images cannot be segmented.',
      );
    }
    final json = jsonDecode(
      await engine.run([
        '-v',
        'error',
        '-show_streams',
        '-show_format',
        '-of',
        'json',
        file.path,
      ], probe: true),
    ) as Map<String, dynamic>;
    final streams = (json['streams'] as List).cast<Map<String, dynamic>>();
    return SegmentSource(
      file,
      info,
      streams.firstWhere(
        (s) =>
            s['codec_type'] == 'video' &&
            (s['disposition'] as Map?)?['attached_pic'] != 1,
      ),
      streams.where((s) => s['codec_type'] == 'audio').toList(),
      double.tryParse('${json['format']?['start_time']}') ?? 0,
    );
  }

  Future<bool> _canCopy(
    SegmentSource source,
    List<VideoSegment> plan,
    CancellationToken token,
  ) async {
    // Conservative: no reordered frames, compatible pixel format/codecs and a
    // zero-origin clock. Other inputs use the precise, closed-GOP encode path.
    if (source.video['codec_name'] != 'h264' ||
        !['yuv420p', 'yuvj420p'].contains(source.video['pix_fmt']) ||
        source.audio.any((a) => a['codec_name'] != 'aac')) {
      return false;
    }
    if (plan.length == 1) return true;
    if (source.video['has_b_frames'] != 0 ||
        source.formatStart.abs() > 0.000001 ||
        (double.tryParse('${source.video['start_time']}') ?? 1).abs() >
            0.000001) {
      return false;
    }
    final cuts = plan.map((s) => s.start).toList();
    final json = jsonDecode(
      await engine.run(
        [
          '-v',
          'error',
          '-select_streams',
          'V:0',
          '-read_intervals',
          cuts.map((t) => '${t.toStringAsFixed(6)}%+0.1').join(','),
          '-show_packets',
          '-show_entries',
          'packet=pts_time,dts_time,flags',
          '-of',
          'json',
          source.file.path,
        ],
        probe: true,
        token: token,
      ),
    ) as Map;
    final keys = (json['packets'] as List? ?? [])
        .where(
          (packet) =>
              '${packet['flags']}'.contains('K') &&
              packet['pts_time'] == packet['dts_time'],
        )
        .map((packet) => double.tryParse('${packet['pts_time']}'))
        .whereType<double>();
    return cuts.every(
      (cut) => keys.any((key) => (key - cut).abs() <= 0.000001),
    );
  }

  Future<SegmentationResult> split(
    SegmentSource source,
    double seconds,
    Directory workRoot, {
    required CancellationToken token,
    required void Function(double, String) progress,
  }) async {
    final plan = segmentPlan(source.info.duration, seconds);
    if (source.fps > 0 && seconds < 1 / source.fps - 0.000001) {
      throw MediaFailure(
        'Choose a segment duration of at least one source frame (${(1 / source.fps).toStringAsFixed(6)} seconds).',
      );
    }
    Directory? workspace;
    try {
      token.check();
      progress(0, 'Checking keyframes and codecs…');
      final copy = await _canCopy(source, plan, token);
      token.check();
      if (!copy &&
          [
            'smpte2084',
            'arib-std-b67',
          ].contains(source.video['color_transfer'])) {
        throw MediaFailure(
          'This HDR source needs tone mapping for an SDR encode. Convert it to SDR first, or choose boundaries compatible with stream copy. The source is unchanged.',
        );
      }
      final encoder = copy ? '' : await engine.encoder();
      token.check();
      await workRoot.create(recursive: true);
      workspace = await workRoot.createTemp('trimmer_');
      final listing = p.join(workspace.path, 'segments.csv');
      final message = copy
          ? 'Splitting compatible streams without re-encoding…'
          : 'Encoding precise cuts into H.264/AAC segments…';
      await engine.run(
        [
          '-y',
          '-hide_banner',
          '-loglevel',
          'warning',
          '-filter_threads',
          '1',
          '-i',
          source.file.path,
          '-map',
          '0:V:0',
          '-map',
          '0:a?',
          '-map_metadata',
          '0',
          '-map_chapters',
          '-1',
          if (copy) ...[
            '-c',
            'copy',
          ] else ...[
            '-vf',
            'scale=ceil(iw/2)*2:ceil(ih/2)*2,format=yuv420p',
            '-fps_mode',
            'passthrough',
            '-enc_time_base',
            '1:1000000',
            '-c:v',
            encoder,
            '-bf',
            '0',
            if (encoder == 'libx264') ...[
              '-preset',
              'veryfast',
              '-crf',
              '18',
              '-flags',
              '+cgop',
            ] else ...[
              '-b:v',
              '${math.max(4000000, (source.info.width * source.info.height * math.max(30, source.fps) * 0.15).round())}',
            ],
            '-force_key_frames',
            'expr:gte(t,n_forced*${seconds.toStringAsFixed(6)})',
            '-c:a',
            'aac',
            '-b:a',
            '192k',
          ],
          '-threads',
          '2',
          // Preserve the common source clock, including AAC encoder priming.
          // An automatic global shift can otherwise skip the first copy cut.
          '-avoid_negative_ts',
          'disabled',
          '-f',
          'segment',
          '-segment_format',
          'mp4',
          '-segment_format_options',
          'movflags=+faststart:avoid_negative_ts=disabled',
          '-reset_timestamps',
          '1',
          if (plan.length > 1) ...[
            '-segment_times',
            plan.skip(1).map((s) => s.start.toStringAsFixed(6)).join(','),
          ] else ...[
            '-segment_time',
            '${source.info.duration + 1}',
          ],
          '-segment_list',
          listing,
          '-segment_list_type',
          'csv',
          p.join(workspace.path, 'segment_%06d.mp4'),
        ],
        token: token,
        onTime: (t) => progress(
          0.05 + 0.8 * (t / source.info.duration).clamp(0, 1),
          message,
        ),
      );
      token.check();
      final lines = (await File(
        listing,
      ).readAsLines()).where((l) => l.isNotEmpty).toList();
      if (lines.length != plan.length) {
        throw MediaFailure(
          'The source frame spacing could not produce ${plan.length} nonempty segments. Choose a longer or slightly different duration; all source footage was kept unchanged.',
        );
      }
      final files = <File>[], actual = <VideoSegment>[];
      final tolerance = math.max(
        0.15,
        source.fps > 0 ? 1 / source.fps + 0.05 : 0.25,
      );
      final notice = File('${source.file.path}.txt');
      for (var i = 0; i < lines.length; i++) {
        token.check();
        // Filenames are fixed internal ASCII names, never user CSV input.
        final row = lines[i].split(',');
        final file = File(
          p.join(workspace.path, 'segment_${i.toString().padLeft(6, '0')}.mp4'),
        );
        final start = double.parse(row[1]), end = double.parse(row[2]);
        final info = await engine.inspect(file.path);
        token.check();
        if (!info.hasVideo ||
            info.hasAudio != source.info.hasAudio ||
            !info.duration.isFinite ||
            info.duration <= 0 ||
            (start - plan[i].start).abs() > tolerance ||
            (end - plan[i].end).abs() > tolerance ||
            (info.duration - (end - start)).abs() > tolerance ||
            (i > 0 && (start - actual.last.end).abs() > 0.00001)) {
          throw MediaFailure(
            'Segment ${i + 1} failed timing/stream verification. Try another duration or convert the source to a constant-frame-rate MP4.',
          );
        }
        if (await notice.exists()) await notice.copy('${file.path}.txt');
        files.add(file);
        actual.add(
          VideoSegment(i, (start * 1000000).round(), (end * 1000000).round()),
        );
        progress(
          0.85 + 0.15 * (i + 1) / lines.length,
          'Verified segment ${i + 1} of ${lines.length}',
        );
      }
      token.check();
      return SegmentationResult(workspace, files, actual, copy);
    } catch (error) {
      if (workspace != null && await workspace.exists()) {
        await workspace.delete(recursive: true);
      }
      if (error is FileSystemException) {
        throw MediaFailure(
          'Cannot write segments. Check free storage and folder permissions. ${error.osError?.message ?? error.message}',
        );
      }
      if (error is MediaFailure &&
          RegExp(
            'no space left|disk full|insufficient storage',
            caseSensitive: false,
          ).hasMatch(error.message)) {
        throw MediaFailure(
          'Not enough storage for the MP4 segments. Free space in app storage and retry; incomplete files from this attempt were removed.',
        );
      }
      rethrow;
    }
  }
}
