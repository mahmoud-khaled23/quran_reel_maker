import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:xml/xml.dart';

class Surah {
  const Surah(this.number, this.name, this.arabic, this.count);
  final int number;
  final String name;
  final String arabic;
  final int count;
}

class QuranRepository {
  QuranRepository._(this.surahs, this._verses, this.copyright);
  final List<Surah> surahs;
  final Map<String, String> _verses;
  final String copyright;
  static const textDigest =
      '6933e133dd56db778c801bf738848454e43648105a151e8d84d86a7cae39ec5f';
  static const metadataDigest =
      '8867c1d88191472adec9db694b3cd9f135b1a2ef580574d32cf888dcb22c5c7a';
  static Future<QuranRepository> load() async {
    final text = await rootBundle.load('assets/quran/quran-uthmani.txt');
    final metadata = await rootBundle.load('assets/quran/quran-data.xml');
    final bytes = text.buffer.asUint8List(
      text.offsetInBytes,
      text.lengthInBytes,
    );
    final metaBytes = metadata.buffer.asUint8List(
      metadata.offsetInBytes,
      metadata.lengthInBytes,
    );
    if (sha256.convert(bytes).toString() != textDigest ||
        sha256.convert(metaBytes).toString() != metadataDigest) {
      throw const FormatException(
        'Quran asset integrity check failed. Reinstall the verified assets.',
      );
    }
    final source = utf8.decode(bytes);
    final verses = <String, String>{};
    for (final line in const LineSplitter().convert(source)) {
      if (line.isEmpty || line.startsWith('#')) continue;
      final fields = line.split('|');
      if (fields.length != 3) {
        throw const FormatException('Malformed Quran dataset.');
      }
      final key = '${fields[0]}:${fields[1]}';
      if (verses.containsKey(key)) {
        throw const FormatException('Duplicate ayah.');
      }
      verses[key] =
          fields[2]; // No normalization or modification of Quran text.
    }
    final surahs = XmlDocument.parse(utf8.decode(metaBytes))
        .findAllElements('sura')
        .map(
          (e) => Surah(
            int.parse(e.getAttribute('index')!),
            e.getAttribute('tname')!,
            e.getAttribute('name')!,
            int.parse(e.getAttribute('ayas')!),
          ),
        )
        .toList();
    if (surahs.length != 114 || verses.length != 6236) {
      throw const FormatException('Incomplete Quran dataset.');
    }
    for (final surah in surahs) {
      for (var ayah = 1; ayah <= surah.count; ayah++) {
        if (!verses.containsKey('${surah.number}:$ayah')) {
          throw const FormatException('Missing ayah.');
        }
      }
    }
    return QuranRepository._(
      List.unmodifiable(surahs),
      Map.unmodifiable(verses),
      source.substring(source.indexOf('# PLEASE')),
    );
  }

  String verse(int surah, int ayah) {
    final value = _verses['$surah:$ayah'];
    if (value == null) throw FormatException('Unknown ayah $surah:$ayah.');
    return value;
  }
}
