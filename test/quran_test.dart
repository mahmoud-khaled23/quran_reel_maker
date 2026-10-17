import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quran_reel_maker/features/quran_text/quran_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('bundled Quran has all 114 surahs and 6236 unmodified ayahs', () async {
    final quran = await QuranRepository.load();
    expect(quran.surahs.length, 114);
    expect(quran.surahs.fold(0, (n, s) => n + s.count), 6236);
    final source = await File('assets/quran/quran-uthmani.txt').readAsLines();
    for (final line in source.where((l) => l.contains('|'))) {
      final fields = line.split('|');
      expect(
        quran.verse(int.parse(fields[0]), int.parse(fields[1])),
        fields[2],
      );
    }
    expect(() => quran.verse(1, 8), throwsFormatException);
    expect(quran.copyright, contains('CHANGING IT IS NOT ALLOWED'));
  });
  test(
    'Amiri Quran font bytes match the attributed upstream release',
    () async {
      expect(
        sha256
            .convert(await File('assets/fonts/AmiriQuran.ttf').readAsBytes())
            .toString(),
        '5594121cfcd33d05ea4635b7908d15c0eced0c91aa06469a95354b3369ca2949',
      );
    },
  );
}
