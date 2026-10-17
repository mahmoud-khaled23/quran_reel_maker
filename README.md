# Quran Reel Maker

An offline Flutter editor for Fedora Linux and Android. Import a recitation,
trim it, add an image or looping video, select verified Quran text, review each
ayah's timing, and export a 1080 × 1920, 30 fps H.264/AAC MP4.

The essential manual workflow is implemented. **Automatic ayah recognition is
unavailable**: no validated model/weights are bundled. Equal-spacing is clearly
labeled as a manual starting grid, never recognition. See [alignment limitations](docs/ALIGNMENT.md)
and [executed checks](docs/VALIDATION.md) for the exact validation status.

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
./scripts/build-apk.sh
# APKs are copied to output/android/
adb devices -l
flutter run -d DEVICE_ID
flutter test integration_test/media_export_test.dart -d DEVICE_ID
flutter test integration_test/editor_flow_test.dart -d DEVICE_ID
```

The APK script deliberately runs `flutter build apk --release --split-per-abi`
without `--no-pub`. On the pinned Flutter version, the build's tooling phase must
regenerate the Android plugin registrant to exclude dev-only plugins. Skipping
that phase after `flutter pub get` can fail on `integration_test`; see
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

1. **Import audio** (MP3, WAV, M4A/AAC, FLAC, Ogg/Opus). The app checks for an audio
   stream and a usable duration, then copies the file into its local project.
   A full-source waveform is generated when FFmpeg can decode it.
2. Move the trim handles or enter **seconds** in the precise fields and press
   Enter/Done or click outside. Play/seek in the preview to inspect the segment.
   The playhead and cue timestamps always refer to the original source audio.
3. Import an image (PNG, JPEG, WebP) or video (MP4, MOV, MKV, WebM). Select **Fill &
   crop** with horizontal/vertical focus, or **Fit** with black letterboxing.
   Video starts at its beginning, loops as needed, and its soundtrack is muted.
4. Choose a surah and ayah range. **Create manual timings** replaces the cue list
   with an evenly spaced draft inside the selected trim. Listen and edit each
   start/end, or use **Mark start/end** at the playhead. Adjacent boundaries may
   require shortening one cue before extending its neighbor. Gaps are supported;
   overlaps, invalid ranges and non-finite times are rejected.
5. Check **I reviewed the ayahs and their timing** after checking text/recitation.
   Editing timing or trimming resets this review. This is human confirmation,
   not a model accuracy claim. Export without text is supported too.
6. **Save** stores the project; **Projects** reopens it. Creating/opening another
   project or exporting saves the current project first. Click Save before
   closing the application: other edits are not continuously autosaved.
7. **Export MP4** renders the current composition, shows progress, and supports
   cancellation. Once ready, **Save exported video…** opens a destination chooser.
   Android uses a Storage Access Framework document and streams the MP4 without
   loading the whole video into memory. Linux also copies the text-license sidecar.

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
Each ayah becomes a transparent PNG overlay with shaped Arabic and diacritics.
Long ayahs scale down to fit; they are not cut off or paraphrased. FFmpeg composites
these frames using a generated, safe concat timeline. Caption labels use bundled
Noto Sans. Output timing is quantized to 30 fps (up to half a frame rounding).
Absolute source timings are clipped/rebased once against the trim. Blank frames
clear text during gaps. The MP4 includes visible source credit and full Tanzil
copyright metadata; local exports also have a notice sidecar.

## Architecture and checks

`lib/features/` contains the editor, preview painter, Quran repository, manual
alignment boundary and export service. `ReelProject` is the versioned domain
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
invalid trims/cues, safe filenames, rebase/gaps, responsive layouts, real FFmpeg
H.264/AAC export, dimensions/rate/duration, exact audio trim by tone frequency,
text visibility/blank gaps, looping backgrounds, fast-start, and cancellation.
Fixtures are generated tones/color fields; no copyrighted recitation is bundled.
CI builds the Docker image, runs checks and produces a Linux release bundle.

See [docs/VALIDATION.md](docs/VALIDATION.md) for commands actually executed and
remaining limitations. Tests do not claim Quran alignment accuracy, real-device
Android playback, perfect preview clock synchronization, or universal codec
support. Export is the timing authority; independently review the final video.
