# Video Trimmer

Open **Video Trimmer** in the editor's top navigation. It does not require audio
import, Quran text, alignment or an existing reel. Select a readable video,
preview it with play/pause and the seek slider, and edit its project name.
The initial name is the source filename without its extension; the original
file is never renamed or modified.

Choose **30 seconds**, **60 seconds**, **90 seconds**, or **Custom seconds**.
Positive fractional values such as `12.5` are supported. The page shows the
expected count, a tappable boundary strip, and chronological segments with
start/end/duration and filenames. Use **Preview** to inspect a proposed interval.
**Process segments** creates MP4s in private temporary storage. Preview the
generated files, rename individual segments if needed, then **Save all segments…**
and choose a destination folder. Existing files receive numbered suffixes, and
the completion message lists the actual saved names/paths.

Names use `project_001.mp4`, `project_002.mp4`, etc. Editing the project name updates
automatic names; manually renamed segments keep their names and positions.
**Use automatic name** resets an individual override. Names retain Unicode but
sanitize filesystem control/reserved characters and cap UTF-8 length. Duplicate
names within a batch are disambiguated case-insensitively. Linux destinations
are reserved atomically; Android uses newly created SAF documents.

**Change split settings** discards the generated temporary batch after confirmation
if unsaved, and lets you calculate/process another split. Leaving an unsaved batch
also asks before discarding it. Saved destination files survive these actions.
Trimmer sessions are not persistent projects; save the MP4s before leaving. Source
files must remain available until processing completes. Keep Android in the
foreground while processing/saving.

## Completed reels

Render normally with **Export MP4**. **Save exported video…** still saves the
single completed MP4. The optional **Split completed reel…** action passes that
exact completed export to the trimmer, not the background or an intermediate
clip. Burned-in Quran overlays, existing synchronization and attribution metadata
remain in the segmented video. Existing `.mp4.txt` notices are copied alongside
each segment. The completed single-file reel is kept.

## Implementation and cut precision

- `segment_plan.dart` calculates contiguous boundaries using integer microseconds,
  retaining the complete remainder. A 120-second input gives `30+30+30+30`,
  `60+60`, or `90+30`. Batches are limited to 1000 nonempty segments; durations
  shorter than a known source frame are rejected with an actionable message.
- `segmentation_service.dart` reuses `MediaEngine`: FFmpeg/FFprobe subprocesses on
  Linux, FFmpegKit/FFprobeKit on Android. No shell scripts, Python, network, model
  weights or Docker are needed for end-user segmentation.
- Compatible H.264/yuv420p/AAC sources use stream copy when all desired cut points
  have verified keyframe timestamps, no B-frame reordering and a zero-origin clock.
  A single compatible segment can be remuxed directly. Other cuts use one H.264/AAC
  encode with forced keyframes. x264 uses CRF 18; the existing OpenH264 fallback
  uses a resolution/rate-based bitrate. Encoding costs time and can change quality.
- One FFmpeg segment-muxer pass distributes packets across outputs. It does not
  independently seek/re-encode each interval. Frame-rate passthrough avoids
  deliberately adding or dropping frames. Video orientation/aspect ratio and all
  audio streams are retained; odd pixel dimensions are rounded up to even with
  the sample aspect adjusted by FFmpeg. Extra video angles, subtitle/data streams
  and chapters are not exported.
- Requested boundaries are estimates until processing. Fractional cuts occur at
  the first eligible source frame, so exact sub-frame cuts are impossible. Audio
  packet durations/codec priming may cause small start/end offsets; separate MP4s
  do not promise sample-perfect gapless playback when joined in another player.
  Source audio/video offsets share the same clock rather than being independently
  reset. Global negative-timestamp shifting is disabled to avoid moving cuts.
- The CSV segment manifest supplies measured boundaries displayed after processing.
  Each output is probed for playable streams, duration, expected count and contiguous
  intervals. A failed check rejects the batch and explains the remedy. Highly
  irregular variable-frame-rate footage, very short remnants without a video frame,
  damaged timestamps, or substantially different audio/video lengths can need a
  constant-frame-rate conversion or a different duration. No timestamps are invented
  to conceal a failed verification.
- HDR sources needing re-encoding are rejected with a tone-mapping diagnostic;
  this feature does not silently convert HDR to SDR. Stream-copy compatibility is
  deliberately conservative. Codec/container support depends on the installed
  FFmpeg build.

See the official [FFmpeg segment muxer](https://ffmpeg.org/ffmpeg-formats.html#segment_002c-stream_005fsegment_002c-ssegment),
[keyframe and rotation options](https://ffmpeg.org/ffmpeg.html), and
[Android document-tree access](https://developer.android.com/training/data-storage/shared/documents-files).

## Storage and cancellation

Processing is asynchronous with progress and cancellation. Generated MP4s live in
a unique `exports/trimmer_*` directory until saved/discarded. Saving streams bytes
to the selected folder rather than loading complete videos into memory. Allow
space for both this temporary batch and destination copies; encoded files can be
larger than the source. Write failures report storage/permission remedies and
remove files from the failed attempt. A cancelled save preserves the generated
batch for retry and rolls back only newly created destination files.

Android uses `ACTION_OPEN_DOCUMENT_TREE` and `DocumentsContract`, including
per-file collision avoidance and progress/cancellation over the existing
`quran_reel/files` channel. Provider deletion failures are reported with the number
of new files requiring manual inspection. Android may restrict selectable folders
(for example, the Downloads root); choose an allowed subfolder. Abrupt process
termination, device power loss or provider failure can leave temporary/partial
files; normal cancellation and error cleanup cannot guarantee recovery from these.

## Checks and acceptance coverage

| Acceptance criteria | Automated evidence |
| --- | --- |
| Navigation; independent workflow (1–2) | Desktop/mobile widget tests; native standalone import/play/split/save with unchanged reel state |
| 120-second presets and remainder (3–6) | Integer boundary tests; real 120-second H.264/AAC preset exports; 3.7-second fractional footage test |
| Project/default/custom names and ordering (7–11) | Widget interactions and `segment_plan_test.dart`; duplicate/case collision and existing-file reservation checks |
| Footage and audio (12) | 37 distinguishable source frames retained exactly once/in order; changing-tone timing; aspect/portrait, copy/encode and cancellation checks |
| Completed reel and single-file export (13–14) | Native post-export navigation; real progressive Arabic overlay frames/audio/notices in split outputs; full MP4 still exists |
| Analysis/tests/builds (15) | Executed commands and platform limits recorded in [VALIDATION.md](VALIDATION.md) |

All new audio/video fixtures are mathematical tones and generated frames, with
no third-party recording dependency. Run:

```bash
flutter test
docker compose run --rm dev bash scripts/check-trimmer-ui.sh
docker compose run --rm dev bash scripts/check-editor-ui.sh
# On a connected Android device (real FFmpegKit segmentation):
flutter test integration_test/video_segmentation_test.dart -d DEVICE_ID
```

The standalone native Linux test replaces only the OS file/folder chooser. Device
execution is still required to validate Android playback, the SAF folder dialog
and provider behavior; APK builds alone do not establish these results. No new
runtime dependencies were needed, so existing Docker images remain applicable.
CI now also runs the standalone native trimmer workflow in private Xvfb.
