import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';

class MediaFailure implements Exception {
  MediaFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

class ExportCancelled implements Exception {
  @override
  String toString() => 'Export cancelled.';
}

class CancellationToken {
  bool cancelled = false;
  void Function()? onCancel;
  void cancel() {
    cancelled = true;
    onCancel?.call();
  }

  void check() {
    if (cancelled) throw ExportCancelled();
  }
}

class MediaInfo {
  const MediaInfo({
    required this.duration,
    required this.hasAudio,
    required this.hasVideo,
    this.width = 0,
    this.height = 0,
  });
  final double duration;
  final bool hasAudio;
  final bool hasVideo;
  final int width, height;
}

abstract class MediaEngine {
  Future<String> run(
    List<String> arguments, {
    bool probe = false,
    CancellationToken? token,
    void Function(double seconds)? onTime,
  });
  Future<MediaInfo> inspect(String file) async {
    final output = await run([
      '-v',
      'error',
      '-show_format',
      '-show_streams',
      '-of',
      'json',
      file,
    ], probe: true);
    final json = jsonDecode(output) as Map<String, dynamic>;
    final streams = (json['streams'] as List? ?? [])
        .cast<Map<String, dynamic>>();
    final duration =
        double.tryParse('${(json['format'] as Map?)?['duration']}') ?? 0;
    final videos = streams.where(
      (s) =>
          s['codec_type'] == 'video' &&
          (s['disposition'] as Map?)?['attached_pic'] != 1,
    );
    final video = videos.isEmpty ? <String, dynamic>{} : videos.first;
    var width = (video['width'] as num?)?.toDouble() ?? 0;
    var height = (video['height'] as num?)?.toDouble() ?? 0;
    final sar = '${video['sample_aspect_ratio']}'
        .split(':')
        .map(double.tryParse)
        .toList();
    if (sar.length == 2 &&
        sar[0] != null &&
        sar[1] != null &&
        sar[0]! > 0 &&
        sar[1]! > 0) {
      width *= sar[0]! / sar[1]!;
    }
    var rotation =
        double.tryParse('${(video['tags'] as Map?)?['rotate']}') ?? 0;
    for (final side in video['side_data_list'] as List? ?? []) {
      if (side['rotation'] is num) {
        rotation = (side['rotation'] as num).toDouble();
      }
    }
    if (rotation.abs().round() % 180 == 90) {
      final old = width;
      width = height;
      height = old;
    }
    return MediaInfo(
      width: width.round(),
      height: height.round(),
      duration: duration,
      hasAudio: streams.any((s) => s['codec_type'] == 'audio'),
      hasVideo: videos.isNotEmpty,
    );
  }

  Future<String> encoder() async {
    final output = await run(['-hide_banner', '-encoders']);
    if (RegExp(r'\blibx264\b').hasMatch(output)) return 'libx264';
    if (RegExp(r'\blibopenh264\b').hasMatch(output)) return 'libopenh264';
    throw MediaFailure(
      'FFmpeg needs an H.264 encoder (libx264 or libopenh264). Install a compatible FFmpeg build.',
    );
  }

  Future<void> waveform(String audio, String output) async {
    await run([
      '-y',
      '-v',
      'error',
      '-i',
      audio,
      '-filter_complex',
      'aformat=channel_layouts=mono,aresample=500,showwavespic=s=1600x160:colors=0x82dfbb:scale=sqrt',
      '-frames:v',
      '1',
      '-threads',
      '1',
      output,
    ]);
  }
}

class ProcessMediaEngine extends MediaEngine {
  @override
  Future<String> run(
    List<String> arguments, {
    bool probe = false,
    CancellationToken? token,
    void Function(double seconds)? onTime,
  }) async {
    token?.check();
    Process process;
    try {
      process = await Process.start(probe ? 'ffprobe' : 'ffmpeg', [
        if (!probe) ...['-nostdin', '-progress', 'pipe:1', '-nostats'],
        ...arguments,
      ], runInShell: false);
    } on ProcessException {
      throw MediaFailure('Install FFmpeg and FFprobe and put them on PATH.');
    }
    Timer? killTimer;
    void cancel() {
      process.kill(ProcessSignal.sigterm);
      killTimer ??= Timer(
        const Duration(seconds: 3),
        () => process.kill(ProcessSignal.sigkill),
      );
    }

    token?.onCancel = cancel;
    if (token?.cancelled ?? false) cancel();
    var output = '';
    var errors = '';
    final stdoutDone = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          output += '$line\n';
          // Probe JSON remains complete; FFmpeg logs are bounded.
          if (!probe && output.length > 32000) {
            output = output.substring(output.length - 32000);
          }
          if (line.startsWith('out_time_us=')) {
            final micros = double.tryParse(line.substring(12));
            if (micros != null) onTime?.call(micros / 1000000);
          }
        })
        .asFuture<void>();
    final stderrDone = process.stderr.transform(utf8.decoder).listen((chunk) {
      errors += chunk;
      if (errors.length > 16000) {
        errors = errors.substring(errors.length - 16000);
      }
    }).asFuture<void>();
    final code = await process.exitCode;
    await Future.wait([stdoutDone, stderrDone]);
    killTimer?.cancel();
    token?.onCancel = null;
    token?.check();
    if (code != 0) throw MediaFailure('FFmpeg failed ($code).\n$errors');
    return probe ? output : '$output\n$errors';
  }
}

class AndroidMediaEngine extends MediaEngine {
  @override
  Future<String> run(
    List<String> arguments, {
    bool probe = false,
    CancellationToken? token,
    void Function(double seconds)? onTime,
  }) async {
    token?.check();
    if (probe) {
      final session = await FFprobeKit.executeWithArguments(arguments);
      final code = await session.getReturnCode();
      if (code?.getValue() != 0) {
        throw MediaFailure(await session.getOutput() ?? 'FFprobe failed.');
      }
      return await session.getOutput() ?? '';
    }
    final done = Completer<String>();
    final session = await FFmpegKit.executeWithArgumentsAsync(
      arguments,
      (session) async {
        try {
          token?.check();
          final code = await session.getReturnCode();
          final output = await session.getOutput() ?? '';
          if (code?.getValue() != 0) {
            throw MediaFailure(
              output.length > 16000
                  ? output.substring(output.length - 16000)
                  : output,
            );
          }
          done.complete(output);
        } catch (error, stack) {
          done.completeError(error, stack);
        }
      },
      null,
      (statistics) => onTime?.call(statistics.getTime() / 1000),
    );
    token?.onCancel = () {
      FFmpegKit.cancel(session.getSessionId());
    };
    if (token?.cancelled ?? false) token?.onCancel?.call();
    try {
      return await done.future;
    } finally {
      token?.onCancel = null;
    }
  }
}

MediaEngine createMediaEngine() =>
    Platform.isAndroid ? AndroidMediaEngine() : ProcessMediaEngine();
