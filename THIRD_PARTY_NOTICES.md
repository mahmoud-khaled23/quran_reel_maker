# Third-party assets and media libraries

The optional model `mostafanewir70/quran-recitation-ctc-onnx`, pinned revision
`f90650aac5d9dcff15230a19998c0027f45b33f1`, and its declared upstream
`rabah2026/wav2vec2-large-xlsr-53-arabic-quran-v_final` declare Apache-2.0 in their
cards. Weights are explicitly downloaded, not bundled; preserve upstream notices
when redistributing them. See [model provenance](docs/ALIGNMENT.md).
ONNX Runtime uses MIT; NumPy uses BSD-3-Clause. Dependency distributions retain
their licenses; `alignment_worker/requirements.lock` pins versions and hashes.

`test/fixtures/alignment/fatiha-cc0.ogg` is own work by Ibrahimmusa4, released under
CC0 1.0 on Commons. See [source, license and checksum](test/fixtures/alignment/README.md).

- Quran text: Tanzil Project, Uthmani 1.1, CC BY 3.0 plus the publisher's
  verbatim-copy terms. See assets/quran/README.md and the preserved copyright
  block in quran-uthmani.txt. Source: https://tanzil.net/.
- Surah metadata: Tanzil metadata 1.0, CC-BY as declared in the original XML.
- Amiri Quran 1.003: Khaled Hosny and contributors, SIL OFL 1.1. The full license
  is assets/fonts/OFL.txt. https://github.com/aliftype/amiri/tree/1.003.
- Noto Sans: Noto Project contributors, SIL OFL 1.1. See assets/fonts/README.md
  and NotoSans-OFL.txt for the pinned source and full license.
- Flutter/Dart and Flutter plugins: preserve their individual notices; Flutter's
  in-app licenses screen includes registered package notices.
- media_kit Dart packages: MIT; native mpv and linked codec libraries have their
  own licenses, potentially GPL depending on the build. Inspect the exact native
  artifacts resolved by pubspec.lock, not just the Dart wrapper license.
- Android ffmpeg_kit_flutter_new 4.5.3: full-GPL package with x264 and other GPL
  components. Upstream: https://github.com/sk3llo/ffmpeg_kit_flutter.
  Its LGPL wrapper license does not remove GPL obligations of its native bundle.
  See the pinned package README/license and its Android Gradle dependency.
- Linux: this app executes the user's FFmpeg/FFprobe and loads the user's mpv.
  Docker uses Ubuntu's packages. A container FFmpeg is not an Android dependency.

FFmpeg's official license guidance: https://ffmpeg.org/legal.html. FFmpeg's
license depends on compile-time components; GPL and nonfree builds must not be
represented as a plain LGPL distribution. Inspect `ffmpeg -buildconf` and
`ffmpeg -L` for the binaries you actually ship. H.264/AAC patent considerations
are separate from copyright licensing and depend on distribution/jurisdiction.

This is a development project, not a cleared binary distribution. Before
publishing an APK or desktop package, select an application license compatible
with the linked GPL components, retain notices, provide corresponding source
and build scripts for the exact shipped native libraries, and review all native
transitive dependencies. No proprietary distribution clearance is claimed.

The app keeps full Tanzil notices in the installed assets and an export sidecar.
Desktop Save Copy copies the sidecar too. Android's video-only document picker
copies the MP4; its visible credit and full copyright notice in MP4 metadata travel with it.
The full notice also remains in app assets/local export storage. Reproduce the full notice appropriately
when redistributing substantial Quran text or a collection of exports.
