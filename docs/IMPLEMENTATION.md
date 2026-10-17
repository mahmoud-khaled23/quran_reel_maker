# Implementation record

Initial inspection: an unchanged Flutter counter starter with Linux and Android
runners. Fedora 42; Flutter 3.47.7 / Dart 3.13.5; Docker 29.5.3 / Compose 5.1.4;
FFmpeg 7.1.4; Android SDK 36.0.0. No connected Android device.

Execution plan:
1. Preserve platform runners, establish a pinned Docker environment, test starter.
2. Implement media import, waveform, playback, precise trim, and basic MP4 export.
3. Bundle attributed Quran text/font, add manual cues and shared Arabic rendering.
4. Persist portable projects and implement synchronized composition preview.
5. Define offline alignment boundary with honest unavailable-model fallback.
6. Validate video backgrounds, export cancellation, Docker checks, Linux and APK.

See VALIDATION.md for final commands and observed results.
