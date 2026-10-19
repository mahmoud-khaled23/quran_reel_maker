import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quran_reel_maker/features/quran_text/quran_repository.dart';
import 'package:quran_reel_maker/features/synchronization/alignment_engine.dart';
import 'package:quran_reel_maker/features/synchronization/android_alignment_engine.dart';
import 'package:quran_reel_maker/media_engine/media_engine.dart';

class InstalledModel extends AlignmentModelStore {
  InstalledModel(super.directory);
  @override
  Future<bool> isInstalled() async => true;
}

class DecodeMedia extends MediaEngine {
  List<String>? arguments;
  @override
  Future<String> run(
    List<String> args, {
    bool probe = false,
    CancellationToken? token,
    void Function(double)? onTime,
  }) async {
    arguments = args;
    token?.check();
    await File(args.last).writeAsBytes([0, 0, 0, 0]);
    return '';
  }
}

class DownloadClient extends Fake implements HttpClient {
  DownloadClient(this.status);
  final int status;
  bool closed = false;
  @override
  set connectionTimeout(Duration? value) {}
  @override
  Future<HttpClientRequest> getUrl(Uri url) async => DownloadRequest(status);
  @override
  void close({bool force = false}) {
    closed = true;
  }
}

class DownloadRequest extends Fake implements HttpClientRequest {
  DownloadRequest(this.status);
  final int status;
  @override
  Future<HttpClientResponse> close() async => DownloadResponse(status);
}

class DownloadResponse extends Stream<List<int>> implements HttpClientResponse {
  DownloadResponse(this.statusCode);
  @override
  final int statusCode;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) =>
      Stream<List<int>>.fromIterable([
        [1, 2, 3],
      ]).listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const selected = AlignmentRequest(
  audioPath: '/private/audio.ogg',
  trimStart: 14,
  trimEnd: 27,
  surah: 1,
  firstAyah: 2,
  lastAyah: 2,
);
Map<String, dynamic> nativeResult() => {
  'timeline': 'source',
  'model': ProcessAlignmentEngine.model,
  'revision': ProcessAlignmentEngine.revision,
  'quranSha256': QuranRepository.textDigest,
  'cues': [
    {
      'surah': 1,
      'ayah': 2,
      'firstWord': 0,
      'lastWord': 3,
      'start': 15.0,
      'end': 22.0,
      'timingSource': 'automatic',
      'alignmentModel': ProcessAlignmentEngine.model,
      'alignmentScore': .7,
      'warnings': ['Automatic draft.'],
      'words': [
        for (var i = 0; i < 4; i++)
          {'index': i, 'start': 15.0 + i * 2, 'end': 16.0 + i * 2, 'score': .7},
      ],
    },
  ],
  'metrics': {'inferenceMs': 123},
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('quran_reel/alignment-test');
  late Directory root;
  late QuranRepository quran;
  late DecodeMedia media;
  late AndroidAlignmentEngine engine;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('android-alignment-test');
    quran = await QuranRepository.load();
    media = DecodeMedia();
    engine = AndroidAlignmentEngine(
      media: media,
      model: InstalledModel(root),
      quran: quran,
      channel: channel,
    );
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await root.delete(recursive: true);
  });
  test('Android bridge decodes trim once, validates canonical coverage and cleans scratch', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'align');
          final args = call.arguments as Map;
          expect(jsonDecode(args['request'] as String)['trimStart'], 14);
          expect(await File(args['pcmPath'] as String).exists(), isTrue);
          return jsonEncode(nativeResult());
        });
    final cues = await engine.align(selected);
    expect(cues.single.words.first.start, 15);
    expect(cues.single.words.map((w) => w.index), [0, 1, 2, 3]);
    expect(engine.lastMetrics?['inferenceMs'], 123);
    expect(
      media.arguments,
      containsAllInOrder([
        '-ss',
        '14.0',
        '-i',
        '/private/audio.ogg',
        '-t',
        '13.0',
      ]),
    );
    expect(await root.list().toList(), isEmpty);
  });
  test('missing/extra words, changed excerpts, wrong timeline and out-of-order timings rejected', () async {
    for (final change in <void Function(Map<String, dynamic>)>[
      (r) => (r['cues'][0]['words'] as List).removeAt(1),
      (r) => r['cues'][0]['words'][2]['index'] = 8,
      (r) => r['cues'][0]['firstWord'] = 1,
      (r) => r['cues'][0]['lastWord'] = 2,
      (r) => r['timeline'] = 'trim-relative',
      (r) => r['cues'][0]['words'][1]['start'] = 14.5,
    ]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            final result = nativeResult();
            change(result);
            return jsonEncode(result);
          });
      await expectLater(
        engine.align(selected),
        throwsA(isA<AlignmentFailure>()),
      );
      expect(await root.list().toList(), isEmpty);
    }
  });
  test('native resource failures retain diagnostic and metrics, clean up, and allow retry', () async {
    var attempts = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (attempts++ == 0) {
            throw PlatformException(
              code: 'alignment',
              message: 'Android requested memory relief. Existing timings were kept.',
              details: {'processPeakRssKiB': 800000, 'processCpuMs': 2500},
            );
          }
          return jsonEncode(nativeResult());
        });
    await expectLater(
      engine.align(selected),
      throwsA(
        isA<AlignmentFailure>().having(
          (e) => e.message,
          'diagnostic',
          'Android requested memory relief. Existing timings were kept.',
        ),
      ),
    );
    expect(engine.lastMetrics?['processPeakRssKiB'], 800000);
    expect(await root.list().toList(), isEmpty);
    expect((await engine.align(selected)).single.words.length, 4);
    expect(engine.lastMetrics?['processPeakRssKiB'], isNull);
  });
  test('partial words retain canonical indices and missing model gives setup remedy', () async {
    const partial = AlignmentRequest(
      audioPath: '/private/audio.ogg',
      trimStart: 14,
      trimEnd: 27,
      surah: 1,
      firstAyah: 2,
      lastAyah: 2,
      firstWord: 1,
      lastWord: 2,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          final result = nativeResult();
          final cue = result['cues'][0] as Map;
          cue['words'] = (cue['words'] as List).sublist(1, 3);
          cue['firstWord'] = 1;
          cue['lastWord'] = 2;
          cue['start'] = 17.0;
          cue['end'] = 20.0;
          return jsonEncode(result);
        });
    expect((await engine.align(partial)).single.words.map((w) => w.index), [
      1,
      2,
    ]);
    final missing = AndroidAlignmentEngine(
      media: media,
      model: AlignmentModelStore(root),
      quran: quran,
      channel: channel,
    );
    await expectLater(
      missing.align(selected),
      throwsA(
        isA<AlignmentFailure>().having(
          (e) => e.message,
          'remedy',
          contains('Download / repair'),
        ),
      ),
    );
  });
  test(
    'cancellation reaches native job and never publishes a late result',
    () async {
      final entered = Completer<void>(), result = Completer<String>();
      var cancelled = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'cancel') {
              cancelled = true;
              result.complete(jsonEncode(nativeResult()));
              return null;
            }
            entered.complete();
            return result.future;
          });
      final token = AlignmentCancellation();
      final running = engine.align(selected, cancellation: token);
      final assertion = expectLater(
        running,
        throwsA(
          isA<AlignmentFailure>().having(
            (e) => e.message,
            'cancel',
            contains('cancelled'),
          ),
        ),
      );
      await entered.future;
      token.cancel();
      await assertion;
      expect(cancelled, isTrue);
      expect(await root.list().toList(), isEmpty);
    },
  );
  test('model setup rejects corrupt/truncated and HTTP failure downloads, removes partials, permits retry', () async {
    for (final status in [200, 503]) {
      final client = DownloadClient(status);
      final store = AlignmentModelStore(root, clientFactory: () => client);
      await expectLater(
        store.install(cancellation: AlignmentCancellation()),
        throwsA(isA<AlignmentFailure>()),
      );
      expect(client.closed, isTrue);
      expect(await root.list().toList(), isEmpty);
      await expectLater(
        store.install(cancellation: AlignmentCancellation()..cancel()),
        throwsA(
          isA<AlignmentFailure>().having(
            (e) => e.message,
            'cancel',
            contains('cancelled'),
          ),
        ),
      );
    }
    final manifest = jsonDecode(
      await File('assets/models/quran-ctc-manifest.json').readAsString(),
    ) as Map;
    expect(
      manifest,
      jsonDecode(
        await File('alignment_worker/model_manifest.json').readAsString(),
      ),
    );
    expect(
      manifest['files']['onnx/model_q4.onnx']['sha256'],
      AlignmentModelStore.digest,
    );
    expect(
      manifest['files']['onnx/model_q4.onnx']['size'],
      AlignmentModelStore.bytes,
    );
  });
}
