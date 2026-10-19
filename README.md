# Quran Reel Maker

An offline Flutter editor for Fedora Linux and Android. Import a recitation,
trim it, add an image or looping video, select verified Quran text, review each
ayah/word timing, and export a 30 fps H.264/AAC MP4 at 144p, 240p, 360p,
480p, 720p or 1080p. Video can keep its original aspect ratio; quality sets the
short edge and source-video dimensions cap upscaling.

The independent **Video Trimmer** page splits ordinary videos into 30-, 60-,
90-second or custom fractional-duration MP4s. Preview boundaries, edit the project
and segment names, process, then save the batch to a chosen folder. After rendering
a reel, **Split completed reel…** opens the same page with the finished MP4,
including its Quran overlays and audio. Single-file export remains available.
See [video segmentation workflow and limitations](docs/VIDEO_TRIMMER.md).

**Linux automatic ayah/word alignment** uses an optional local Python/ONNX worker
and verified Quran text. Run `./scripts/setup-alignment.sh`, then choose
`scripts/alignment-worker.sh` in the editor. Setup explicitly downloads pinned,
SHA-256-verified weights; subsequent inference works offline without Docker.
Automatic timings require listening review. Android now has an optional native
CPU alignment candidate: open **Alignment model → Download / repair** for the
241.2 MB pinned weights, then align offline. Manual timing remains available.
Independent timing-accuracy acceptance is still pending; see the
[Android model comparison, resource targets and benchmark procedure](docs/ANDROID_ALIGNMENT.md).
See
[setup, model provenance and limitations](docs/ALIGNMENT.md) and
[executed checks](docs/VALIDATION.md). The [request acceptance audit](docs/ACCEPTANCE.md)
maps every feature group and all 15 acceptance criteria to implementation,
evidence and remaining device/manual checks.

## Start with Docker

Install Docker Engine and Docker Compose v2 or later. The development image
uses Ubuntu 24.04 pinned by digest, Flutter **3.47.7** at commit
`abaf9c523780a608bd46686fd5e53740a07077f8`, and its bundled Dart **3.13.5**.
It includes GTK 3, Clang 18, CMake 3.28, Ninja, FFmpeg, mpv, and Xvfb.
System packages receive updates within Ubuntu 24.04 repositories, so package
updates can change image bytes; SDK and Dart/package versions are locked.

```bash
mkdir -p output
# Set these if your host account is not UID/GID 1000:
export DEV_UID="$(id -u)" DEV_GID="$(id -g)"
docker compose build dev
docker compose run --rm dev flutter doctor -v
docker compose run --rm dev flutter pub get --enforce-lockfile
docker compose run --rm dev flutter analyze
docker compose run --rm dev flutter test
./scripts/docker-test.sh
./scripts/docker-build-linux.sh
```

`output/linux/` contains the **whole runnable bundle**, including `data/` and
`lib/`. Keep these together. Do not copy just the executable. `scripts/docker-dev.sh`
opens a development shell or forwards arguments, e.g.:

```bash
./scripts/docker-dev.sh flutter analyze
./scripts/docker-dev.sh bash
./scripts/docker-integration-test.sh
```

The last command runs the native editor in a **private Xvfb display**, exercising
import, trim, ayah timing, save/reopen and export. Its OS file chooser is replaced
with a deterministic fixture; actual native media and application services run.
No host display access, `xhost`, privileged container, or Docker socket mount is
used. Audible playback, physical devices and real OS dialogs require host tests.

The source is bind-mounted with a shared SELinux label (`:z`, suitable for
Fedora). Named volumes keep Pub/Flutter downloads, `.dart_tool`, Linux ephemeral
files, and container builds separate from host caches. A short root `cache-init`
service sets ownership of **only named volume roots**; development, checks and
builds run as the non-root `developer` account. Output is mounted at `/output`.
No environment file or credentials are required.

Run host and container Flutter builds **sequentially**: Flutter still regenerates
some shared plugin metadata and `android/local.properties`. Run `flutter pub get`
in the environment you are switching to before its next build. Do not delete
cache volumes unless you intend to download dependencies again. Docker's doctor
reports the absent Android SDK/browser and a detached SDK channel; these are
expected in this Linux development image.

## Native Fedora development

Use native execution for interactive desktop work. Install Flutter 3.47.7 and
put `flutter/bin` on PATH. Install the following from appropriate repositories:

```bash
sudo dnf install clang cmake ninja-build pkgconf-pkg-config gtk3-devel \
  xz-devel gcc-c++ mpv-libs mpv-devel ffmpeg
flutter doctor -v
flutter pub get --enforce-lockfile
flutter run -d linux
```

FFmpeg package availability/codecs vary with enabled Fedora repositories. Verify
`ffmpeg` and `ffprobe` are on PATH and `ffmpeg -encoders` lists `libx264` or
`libopenh264`. The app prefers x264 and supports OpenH264 when x264 is absent.
Fedora's installed FFmpeg build used OpenH264 in the media test. The Docker image
uses Ubuntu FFmpeg with x264. mpv must provide `libmpv.so.2`; if it is missing,
the app reports the playback dependency instead of crashing at bootstrap.

A Docker-built binary also needs compatible host GTK, GL, C++ and mpv runtime
libraries. Use `ldd output/linux/quran_reel_maker` and `ldd output/linux/lib/*.so`
to inspect dependencies. Docker builds are not a portable Flatpak/AppImage.

## Android

Docker supplies the shared development/check workflow. **Android builds use the
host SDK**; this image does not contain an SDK, emulator, USB passthrough or adb.

Install Android Studio with SDK platforms 35 and 36, build-tools 36.0.0, platform-tools,
command-line tools and NDK 28.2.13676358 requested by the pinned Flutter SDK. The Android
runner pins Gradle 9.3.1 and AGP 9.1.0. Use a compatible JDK (17+ for these
plugins; the inspected host uses Android Studio's JDK 25). Set `ANDROID_HOME` and
accept SDK licenses interactively if they have not already been accepted:

```bash
export ANDROID_HOME="$HOME/Android/Sdk"
export PATH="$ANDROID_HOME/platform-tools:$ANDROID_HOME/cmdline-tools/latest/bin:$PATH"
./scripts/setup-android.sh
flutter doctor --android-licenses
flutter pub get --enforce-lockfile
flutter build apk --debug
./scripts/build-apk.sh
# APKs are copied to output/android/
adb devices -l
# Choose the matching ABI; ARM64 example. Direct update stops on install failure.
adb -s DEVICE_ID install -r output/android/app-arm64-v8a-release.apk
adb -s DEVICE_ID shell am start -n com.example.quran_reel_maker/com.example.quran_reel_maker.MainActivity
flutter test integration_test/media_export_test.dart -d DEVICE_ID --no-uninstall --dart-define=QRM_ALIGNMENT_BENCHMARK=true
flutter test integration_test/enhanced_media_export_test.dart -d DEVICE_ID --no-uninstall --dart-define=QRM_ALIGNMENT_BENCHMARK=true
flutter test integration_test/video_segmentation_test.dart -d DEVICE_ID --no-uninstall --dart-define=QRM_ALIGNMENT_BENCHMARK=true
flutter test integration_test/editor_flow_test.dart -d DEVICE_ID --no-uninstall --dart-define=QRM_ALIGNMENT_BENCHMARK=true
```

Use the isolated benchmark ID for device tests. `--no-uninstall` preserves test
data at teardown, but Flutter may still uninstall/retry after an installation
failure. Do not use that retry path to downgrade a normal release installation
for debugging; private projects can be removed. Benchmark builds keep matching
debug/release version codes so they can be updated without uninstalling.

The APK script explicitly runs `flutter build apk --release --config-only`
after dependency resolution, then builds with `--no-pub`. On the pinned Flutter
version, release configuration must regenerate the Android plugin registrant to
exclude development-only plugins; simply retaining the build's Pub phase proved
insufficient after integration tests. See
[Flutter issue 169336](https://github.com/flutter/flutter/issues/169336).

Android minimum API is **24**. FFmpeg is supplied by pinned
`ffmpeg_kit_flutter_new 4.5.3` / native `com.antonkarpenko:ffmpeg-kit-full-gpl:2.2.1`;
Android never attempts to run the container's `ffmpeg` executable. Native mpv
libraries are packaged by media_kit. First-time builds download these dependencies;
normal editing/export is local after installation. Keep the app in the foreground during export;
background rendering is not implemented as an Android foreground service. Native libraries increase APK
size. Build split-per-ABI APKs rather than one universal APK.

Release builds currently use the template's **development signing key**. Set
an application ID and production signing configuration before distribution;
keep keystores and signing properties outside source control. Review
[third-party distribution requirements](THIRD_PARTY_NOTICES.md), including GPL
components and corresponding-source obligations, before publishing.

A physical device needs USB debugging and explicit device authorization. An
emulator runs separately on the host and requires suitable virtualization/GPU
support. Container USB access and host adb/emulator networking are not configured
or assumed. No connected Android device was present during initial inspection.

## Editing a reel

1. **Import audio** (MP3, WAV, M4A/AAC, FLAC, Ogg/Opus). Preview with play/pause,
   seek, and trim handles before **Use selection** copies the source once into
   the project. Trimming is non-destructive; source files are preserved.
2. All time displays and inputs use **HH:MM:SS:FFF**, including hours and exactly
   three millisecond digits: `00:01:23:045`. Enter/Done or clicking outside applies
   an edit. The playhead and cue times refer to the original source audio.
   **Preview & trim audio** reopens the selection player; a full-source waveform
   is available in the editor. Changing trims requires another timing review.
3. Import an image (PNG/JPEG/WebP) or video (MP4/MOV/MKV/WebM). Video opens its own
   preview/trim dialog. Only the selected segment loops during composition and
   export; background sound is muted. **Keep original aspect ratio** defaults on
   for newly imported videos. Turn it off for a portrait 9:16 reel, then choose
   **Fit** (letterboxing) or **Fill & crop** with horizontal/vertical crop focus.
4. Choose the matching surah, ayahs, and **first/last recited words**. Boundary
   word selectors support partial first/last ayahs. On Linux, **Align automatically**
   uses the optional installed worker. Inspect warnings and tap word boundaries
   to seek. **Rerun alignment** uses the current selection and trim; failure or
   cancellation preserves existing cues. Automatic drafts require review.
5. Word-timed overlays reveal the recited prefix at word onsets, clear long pauses
   and ayah ends, and exclude words before the audio trim. **Edit recited words &
   timing** changes the excerpt or individual times. On Android or without a
   model, **Create manual timings** creates an explicitly approximate ayah grid.
   Listen, edit, or use **Mark start/end**. The **Use passage timing** fallback
   displays only your selected excerpt for the ayah interval and makes no exact
   word-sync claim. Manual progressive mode requires entered times for every
   spoken word; it never invents a word grid.
6. Drag on the composition preview or expand **Text position & color** for sliders,
   a font-color palette and optional text background. Settings are saved per project
   and shared by preview and export. The text block stays within the canvas.
7. Check **I reviewed the ayahs and their timing** after listening. **Save** stores
   the project; **Projects** reopens it. Creating/opening a project or exporting
   saves first. Click Save before closing; edits are not continuously autosaved.
8. **Export MP4** opens a resolution selector and shows the actual output dimensions
   and filename. `Surah Al Rahman` produces `Surah Al Rahman.mp4`; invalid filename
   characters are sanitized and existing files receive `(2)`, `(3)`, etc. No
   silent overwrite occurs. Export shows progress, supports cancellation, and
   verifies encoded streams/duration. Once ready, **Save exported video…** uses
   Android's Storage Access Framework or a Linux destination chooser. Linux also
   saves the license sidecar. Export failures suggest storage/codec remedies.

Projects live under the platform's application-support directory in `projects/`;
exports are in the sibling `exports/`. Each project has versioned `project.json`
and its own `media/` folder. Imported files remain editable if originals move.
Back up the complete project folder, not just its JSON. The current UI reopens
its local project library; it does not implement cross-device archive import.
Old replaced media is retained in the project folder; remove unused projects
manually from storage if space is needed. Android app-private files are removed
when uninstalling; save important exports to your chosen document location.

## Quran text and rendering

The full **Tanzil Uthmani 1.1** dataset, its original notice, metadata and hash
checks are included. See [dataset provenance](assets/quran/README.md).
The app never generates or edits Quran text. Project files store references and
timestamps, separate from any rendering assets. Font provenance and licenses are
in [assets/fonts/README.md](assets/fonts/README.md).

Preview and export share Flutter's RTL `TextPainter` and bundled Amiri Quran font.
Each distinct visible word prefix becomes a transparent PNG overlay with shaped
Arabic and diacritics; manual passage timing uses a single excerpt overlay.
Long ayahs scale down to fit; they are not cut off or paraphrased. FFmpeg composites
these frames using a generated, safe concat timeline. Caption labels use bundled
Noto Sans. Output and preview timing share a 30 fps clock. Word onsets round forward to the
next frame (less than one frame delay), never earlier than their timestamps.
Absolute source timings are clipped/rebased once against the trim. Blank frames
clear text during ayah gaps, after the last word, and throughout inter-word gaps
longer than 750 ms. Shorter pauses hold the recited prefix. These are display
heuristics, not silence detection; review approximate acoustic boundaries. The MP4 includes visible source credit and full Tanzil
copyright metadata; local exports also have a notice sidecar.

## Launcher artwork and Linux desktop integration

The supplied `assets/icons/Emerald Quran Media Icon.png` is preserved unchanged.
Android includes launcher densities and an API 26+ adaptive foreground/background;
Linux bundles a native window icon and desktop entry. To regenerate derivatives
with ImageMagick (build-time only), run `./scripts/generate-icons.sh`.

```bash
# Install the launcher after placing the entire bundle at a persistent location:
python3 scripts/install-linux-desktop.py /absolute/path/to/output/linux
```

The installer writes to `$XDG_DATA_HOME` (default `~/.local/share`), quotes the
executable path, and installs hicolor icons. Re-run it after moving the bundle.
It does not install runtime libraries or the optional alignment worker; choose the
worker's relocated `scripts/alignment-worker.sh` path in the app if needed.
See [artwork provenance and regeneration](assets/icons/README.md).

## Architecture and checks

`lib/features/` contains the editor, preview painter, Quran repository, local
alignment adapter and export service. `alignment_worker/` implements offline
CTC alignment with an NDJSON process interface. `ReelProject` is the versioned domain
model. Riverpod owns the editing state and injectable service dependencies.
`ProjectStore` owns local media copies and atomic JSON saves. `MediaEngine` is the
platform boundary: argument-list subprocesses on Linux, FFmpegKit on Android.
There is no backend or database server. UI file selection is the only OS dialog
substituted in native workflow tests.

```bash
dart format --output=none --set-exit-if-changed lib test integration_test
flutter analyze
flutter test
# Keep a small synthetic MP4 and visual evidence outside version control:
flutter test --dart-define=MEDIA_EVIDENCE=output/evidence
```

Tests cover Quran/font integrity, all ayah references, project persistence,
invalid trims/cues, hour/millisecond parsing, collision-safe filenames, partial
word prefixes, style persistence, source-size limits, rebase/gaps, responsive layouts, real FFmpeg
H.264/AAC export, dimensions/rate/duration, exact audio trim by tone frequency,
progressive text/color/blank gaps, actual trimmed-video loops, fast-start, and cancellation.
Exports prepare a temporary video segment before looping; this avoids retaining
unbounded decoded frames in RAM. Temporary overlays/clips are removed on success,
failure and cancellation. Allow free space for that clip, overlays and the final MP4.
Fixtures include generated tones/color fields and an attributed CC0 Al-Fatiha
recording for opt-in real-model tests. See [fixture provenance](test/fixtures/alignment/README.md).
CI builds the Docker image, runs checks and produces a Linux release bundle.

See [docs/VALIDATION.md](docs/VALIDATION.md) for commands actually executed and
remaining limitations. The A52s has measured debug/release offline inference and
native media regressions; real document-provider interactions and audible speaker
output still need manual review. Tests do not establish independent Quran timing
accuracy, perfect preview clock synchronization, or universal codec support.
Export is the timing authority; independently review the final video.
