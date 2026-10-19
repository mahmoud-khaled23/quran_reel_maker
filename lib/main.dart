import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app.dart';
import 'core/app_services.dart';
import 'features/quran_text/quran_repository.dart';
import 'features/synchronization/alignment_engine.dart';
import 'features/synchronization/android_alignment_engine.dart';
import 'media_engine/media_engine.dart';
import 'services/project_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    String? playbackError;
    try {
      MediaKit.ensureInitialized();
    } catch (_) {
      playbackError = 'Playback needs libmpv. Install mpv-libs on Fedora, then restart the app.';
    }
    final root = await getApplicationSupportDirectory();
    final quran = await QuranRepository.load();
    LicenseRegistry.addLicense(() async* {
      yield LicenseEntryWithLineBreaks(['Tanzil Quran text'], quran.copyright);
      yield LicenseEntryWithLineBreaks([
        'Amiri Quran',
      ], await rootBundle.loadString('assets/fonts/OFL.txt'));
      yield LicenseEntryWithLineBreaks([
        'Noto Sans',
      ], await rootBundle.loadString('assets/fonts/NotoSans-OFL.txt'));
      yield LicenseEntryWithLineBreaks([
        'ONNX Runtime 1.23.2',
      ], await rootBundle.loadString('assets/models/ONNX-RUNTIME-LICENSE.txt'));
      yield LicenseEntryWithLineBreaks(
        ['ONNX Runtime third-party components'],
        await rootBundle.loadString(
          'assets/models/ONNX-RUNTIME-ThirdPartyNotices.txt',
        ),
      );
    });
    final mediaEngine = createMediaEngine();
    final services = AppServices(
      store: ProjectStore(Directory(p.join(root.path, 'projects'))),
      quran: quran,
      engine: mediaEngine,
      exports: Directory(p.join(root.path, 'exports')),
      playbackError: playbackError,
      alignment: Platform.isAndroid
          ? AndroidAlignmentEngine(
              media: mediaEngine,
              quran: quran,
              model: AlignmentModelStore(
                Directory(
                  p.join(
                    root.path,
                    'alignment-models',
                    ProcessAlignmentEngine.model,
                  ),
                ),
              ),
            )
          : const ProcessAlignmentEngine(),
    );
    runApp(
      ProviderScope(
        overrides: [servicesProvider.overrideWithValue(services)],
        child: const QuranReelApp(),
      ),
    );
  } catch (error) {
    runApp(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: SelectableText(
                'Unable to start Quran Reel Maker.\n$error',
              ),
            ),
          ),
        ),
      ),
    );
  }
}
