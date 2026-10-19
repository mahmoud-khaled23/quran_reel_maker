import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../media_engine/media_engine.dart';
import '../../models/reel_project.dart';
import '../quran_text/quran_repository.dart';
import '../quran_text/quran_words.dart';
import 'alignment_engine.dart';

/// One verified weight file outside the APK. Network is used only by install().
class AlignmentModelStore {
  AlignmentModelStore(this.directory, {HttpClient Function()? clientFactory})
    : clientFactory = clientFactory ?? HttpClient.new;
  final Directory directory;
  final HttpClient Function() clientFactory;
  static const bytes = 241230289;
  static const digest =
      '9b17e04fdc2aef54720e62216a7c7ae7f55d27911ee7cd55253baa231845a587';
  static final url = Uri.parse(
    'https://huggingface.co/mostafanewir70/quran-recitation-ctc-onnx/resolve/'
    '${ProcessAlignmentEngine.revision}/onnx/model_q4.onnx',
  );
  File get weights => File(p.join(directory.path, 'model_q4.onnx'));
  bool _installing = false;
  Future<bool> isInstalled() async =>
      await weights.exists() && await weights.length() == bytes;

  Future<void> install({
    required AlignmentCancellation cancellation,
    void Function(double, String)? onProgress,
  }) async {
    if (_installing) {
      throw const AlignmentFailure('Model setup is already running.');
    }
    _installing = true;
    final client = clientFactory()
      ..connectionTimeout = const Duration(seconds: 30);
    final temporary = File('${weights.path}.part');
    var finished = false;
    unawaited(
      cancellation.whenCancelled.then((_) {
        if (!finished) client.close(force: true);
      }),
    );
    void check() {
      if (cancellation.cancelled) {
        throw const AlignmentFailure(
          'Model setup cancelled. Retry when ready.',
        );
      }
    }

    Future<Digest> checksum(File file) => sha256
        .bind(
          file.openRead().map((chunk) {
            check();
            return chunk;
          }),
        )
        .first;

    try {
      check();
      await directory.create(recursive: true);
      if (await isInstalled()) {
        onProgress?.call(0, 'Verifying installed weights…');
        final existing = await checksum(weights);
        check();
        if (existing.toString() == digest) return;
      }
      final request = await client.getUrl(url);
      final response = await request.close().timeout(
        const Duration(seconds: 60),
      );
      if (response.statusCode != HttpStatus.ok) {
        throw AlignmentFailure(
          'Model download returned HTTP ${response.statusCode}. Check your connection and retry.',
        );
      }
      var received = 0;
      final target = await temporary.open(mode: FileMode.write);
      try {
        await for (final chunk in response.timeout(
          const Duration(seconds: 60),
        )) {
          check();
          received += chunk.length;
          if (received > bytes) {
            throw const AlignmentFailure(
              'Unexpected model size. Download rejected; retry setup.',
            );
          }
          // Await writes so full-storage errors are handled here, not as a late
          // unhandled IOSink error; buffering stays bounded on slow storage.
          await target.writeFrom(chunk);
          onProgress?.call(
            received / bytes * .95,
            'Downloading model: ${(received / 1000000).toStringAsFixed(1)} / 241.2 MB',
          );
        }
        await target.flush();
      } finally {
        await target.close();
      }
      check();
      onProgress?.call(.96, 'Checking model SHA-256…');
      if (received != bytes ||
          (await checksum(temporary)).toString() != digest) {
        throw const AlignmentFailure(
          'Model integrity check failed. The download was discarded. Retry setup.',
        );
      }
      check();
      await temporary.rename(weights.path);
      onProgress?.call(
        1,
        'Model installed. Alignment is now offline; review every boundary.',
      );
    } on AlignmentFailure {
      rethrow;
    } catch (error) {
      check();
      throw AlignmentFailure(
        'Model setup failed: $error. Check free storage (at least 300 MB), connection, then retry. Manual timing remains available.',
      );
    } finally {
      finished = true;
      client.close(force: true);
      _installing = false;
      if (await temporary.exists()) {
        try {
          await temporary.delete();
        } on FileSystemException {
          /* A later retry truncates only this known partial file. */
        }
      }
    }
  }
}

class AndroidAlignmentEngine implements AlignmentEngine {
  AndroidAlignmentEngine({
    required this.media,
    required this.model,
    required this.quran,
    this.channel = const MethodChannel('quran_reel/alignment'),
  });
  final MediaEngine media;
  final AlignmentModelStore model;
  final QuranRepository quran;
  final MethodChannel channel;
  bool _busy = false;
  Map<String, dynamic>? lastMetrics;

  @override
  Future<List<AyahCue>> align(
    AlignmentRequest request, {
    AlignmentCancellation? cancellation,
    void Function(double, String)? onProgress,
  }) async {
    if (_busy) throw const AlignmentFailure('Alignment is already running.');
    _busy = true;
    final token = cancellation ?? AlignmentCancellation();
    final decodeToken = CancellationToken();
    Directory? temporary;
    var finished = false, nativeStarted = false, timedOut = false;
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    Future<void> stop() async {
      if (finished) return;
      decodeToken.cancel();
      if (nativeStarted) {
        try {
          await channel.invokeMethod<void>('cancel');
        } catch (_) {
          /* Preserve the job's original diagnostic. */
        }
      }
    }

    unawaited(token.whenCancelled.then((_) => stop()));
    final deadline = Timer(const Duration(minutes: 10), () {
      timedOut = true;
      unawaited(stop());
    });
    void check() {
      if (timedOut) {
        throw const AlignmentFailure(
          'Alignment timed out. Select a shorter clip or use manual timing.',
        );
      }
      if (token.cancelled) {
        throw const AlignmentFailure(
          'Alignment cancelled. Existing timings were kept.',
        );
      }
    }

    try {
      check();
      lastMetrics = null;
      if (!request.trimStart.isFinite ||
          !request.trimEnd.isFinite ||
          request.trimStart < 0 ||
          request.trimEnd - request.trimStart < .5 ||
          request.trimEnd - request.trimStart > 180) {
        throw const AlignmentFailure(
          'Select 0.5–180 seconds of matching recitation.',
        );
      }
      if (!await model.isInstalled()) {
        throw const AlignmentFailure(
          'No Android alignment model is installed. Open Alignment model → Download / repair (241.2 MB). After setup, inference is offline. Manual timing remains available.',
        );
      }
      await model.directory.create(recursive: true);
      temporary = await model.directory.createTemp('audio_');
      final pcm = p.join(temporary.path, 'selected.f32');
      onProgress?.call(.02, 'Decoding selected audio locally…');
      await media.run([
        '-v',
        'error',
        '-protocol_whitelist',
        'file,pipe',
        '-ss',
        '${request.trimStart}',
        '-i',
        request.audioPath,
        '-t',
        '${request.trimEnd - request.trimStart}',
        '-vn',
        '-ac',
        '1',
        '-ar',
        '16000',
        '-f',
        'f32le',
        pcm,
      ], token: decodeToken);
      check();
      channel.setMethodCallHandler((call) async {
        if (call.method != 'progress') return;
        final event = Map<String, dynamic>.from(call.arguments as Map);
        if (event['id'] != id || finished) return;
        final value = (event['value'] as num).toDouble();
        if (value.isFinite && value >= 0 && value <= 1) {
          onProgress?.call(value, event['message'] as String);
        }
      });
      nativeStarted = true;
      final raw = await channel.invokeMethod<String>('align', {
        'id': id,
        'request': jsonEncode(request.toJson()),
        'modelPath': model.weights.path,
        'pcmPath': pcm,
      });
      check();
      final result = jsonDecode(raw!) as Map<String, dynamic>;
      final cues = validateAlignmentResult(result, request);
      validateCanonicalCoverage(cues, quran, request: request);
      lastMetrics = (result['metrics'] as Map?)?.cast<String, dynamic>();
      return cues;
    } on PlatformException catch (error) {
      lastMetrics = (error.details as Map?)?.cast<String, dynamic>();
      check();
      final message = error.message ?? error.code;
      throw AlignmentFailure(
        message.toLowerCase().contains('timings were kept')
            ? message
            : '$message Existing timings were kept.',
      );
    } on AlignmentFailure {
      rethrow;
    } catch (error) {
      check();
      throw AlignmentFailure(
        'Local alignment failed: $error. Retry setup or use manual timing.',
      );
    } finally {
      finished = true;
      deadline.cancel();
      channel.setMethodCallHandler(null);
      _busy = false;
      if (temporary != null && await temporary.exists()) {
        try {
          await temporary.delete(recursive: true);
        } on FileSystemException {
          /* Private scratch only; keep the original result/diagnostic. */
        }
      }
    }
  }
}

/// Reject missing/extra spoken words, including partial selections and pause marks.
void validateCanonicalCoverage(
  List<AyahCue> cues,
  QuranRepository quran, {
  required AlignmentRequest request,
}) {
  for (var c = 0; c < cues.length; c++) {
    final cue = cues[c];
    final words = quran.verse(cue.surah, cue.ayah).split(RegExp(r'\s+'));
    final last = cue.lastWord ?? words.length - 1;
    final expectedFirst = c == 0 ? request.firstWord : 0;
    final expectedLast = c == cues.length - 1
        ? (request.lastWord ?? words.length - 1)
        : words.length - 1;
    if (cue.firstWord != expectedFirst || last != expectedLast) {
      throw const FormatException(
        'Worker changed the requested canonical excerpt.',
      );
    }
    if (cue.firstWord < 0 || last >= words.length || last < cue.firstWord) {
      throw const FormatException('Invalid canonical word selection.');
    }
    final expected = [
      for (var i = cue.firstWord; i <= last; i++)
        if (isSpokenToken(words[i])) i,
    ];
    final actual = cue.words.map((w) => w.index).toList();
    if (expected.length != actual.length ||
        [for (var i = 0; i < expected.length; i++) expected[i] == actual[i]]
            .contains(false)) {
      throw const FormatException(
        'Incomplete or incorrect canonical word coverage. Existing timings were kept.',
      );
    }
  }
}
