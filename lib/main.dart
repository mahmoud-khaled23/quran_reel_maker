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
    });
    final services = AppServices(
      store: ProjectStore(Directory(p.join(root.path, 'projects'))),
      quran: quran,
      engine: createMediaEngine(),
      exports: Directory(p.join(root.path, 'exports')),
      playbackError: playbackError,
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
