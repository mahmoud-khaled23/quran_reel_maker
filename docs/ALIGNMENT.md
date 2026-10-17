# Offline alignment boundary

Automatic recognition/alignment is **not implemented or accuracy-evaluated** in
this release. No suitable Quran-aware model, licensed weights, inference runtime,
or labeled evaluation recordings were installed in the starting environment.
No model is bundled or silently downloaded. A generic Arabic transcription is
not accepted as verified Quran text and equal spacing is not speech alignment.

`AlignmentEngine` accepts a local audio path, an absolute trim window, and a
user-selected surah/ayah range. A future adapter must:

1. Explicitly install/check a model manifest, source, license, and SHA-256 hashes.
2. Prepare mono audio at the model's required rate from exactly the trim window.
3. Use verified dataset references for recognition/forced alignment; never
   replace the source Quran text with ASR-generated text.
4. Return ordered `AyahCue` references and absolute source-audio seconds. Add
   `trimStart` once if the model returns segment-relative times.
5. Attach calibrated confidence in [0,1], flag omissions/repetitions/ta'awwudh,
   basmala and long silences, and require human review before export.
6. Support cancellation, bounded memory, and platform-specific model runtimes.

The supplied `UnavailableAlignmentEngine` fails explicitly. The UI exposes the
unavailable status and a usable manual workflow: select ayahs, create an evenly
spaced starting grid, listen, seek, mark/edit each start and end, review, export.
The grid has **null confidence**, and is never described as detection.

Before enabling an adapter, evaluate on separately licensed, held-out recordings
covering multiple reciters, slow/fast recitation, repetition and noisy input.
Report ayah identification error, median and 95th-percentile onset/offset error,
missed/repeated verses, and confidence calibration. No accuracy numbers are
claimed here. Desktop subprocess models and Android on-device runtimes require
separate validation; a desktop executable cannot be assumed to run on Android.
