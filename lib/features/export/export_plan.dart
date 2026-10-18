import '../../models/reel_project.dart';

import '../preview/overlay_state.dart';
import 'export_settings.dart';

class OverlaySpan {
  const OverlaySpan(
    this.startFrame,
    this.endFrame,
    this.cueIndex, [
    this.state,
  ]);
  final int startFrame, endFrame;
  final int? cueIndex;
  final OverlayState? state;
  String get key => state?.key ?? 'blank';
  double get duration => (endFrame - startFrame) / 30;
}

List<OverlaySpan> overlayTimeline(ReelProject project) {
  final total = (project.duration * 30).ceil();
  final points = <int>{0, total};
  void event(double time) => points.add(
    ((time - project.trimStart) * 30 - 1e-7).ceil().clamp(0, total),
  );
  for (final cue in project.cues) {
    event(cue.start);
    event(cue.end);
    for (final word in cue.words) {
      event(word.start);
      event(word.end);
    }
  }
  final sorted = points.toList()..sort();
  final spans = <OverlaySpan>[];
  for (var i = 0; i < sorted.length - 1; i++) {
    final state = overlayAt(project, project.trimStart + sorted[i] / 30);
    if (spans.isNotEmpty && spans.last.state?.key == state?.key) {
      final old = spans.removeLast();
      spans.add(
        OverlaySpan(old.startFrame, sorted[i + 1], state?.cueIndex, state),
      );
    } else {
      spans.add(OverlaySpan(sorted[i], sorted[i + 1], state?.cueIndex, state));
    }
  }
  return spans;
}

String backgroundFilter(ReelProject project) {
  final size = exportSize(project);
  final w = size.width, h = size.height;
  // Normalize non-square pixels before aspect fitting; FFmpeg autorotates input.
  const square = 'scale=iw*sar:ih,setsar=1';
  return project.fit == BackgroundFit.cover
      ? '$square,scale=$w:$h:force_original_aspect_ratio=increase,crop=$w:$h:(iw-ow)*${project.cropX}:(ih-oh)*${project.cropY}'
      : '$square,scale=$w:$h:force_original_aspect_ratio=decrease,pad=$w:$h:(ow-iw)/2:(oh-ih)/2:color=black';
}

/// Decode exactly the chosen video range, then loop this bounded temporary clip.
/// Input seeking with transcoding discards frames before the requested boundary.
List<String> videoTrimArguments(
  ReelProject project,
  String input,
  String output,
  String encoder,
) => [
  '-y',
  '-hide_banner',
  '-loglevel',
  'warning',
  '-filter_threads',
  '1',
  '-ss',
  project.videoTrimStart.toStringAsFixed(6),
  '-i',
  input,
  '-t',
  project.videoSegmentDuration.toStringAsFixed(6),
  '-map',
  '0:v:0',
  '-an',
  '-vf',
  '${backgroundFilter(project)},setpts=PTS-STARTPTS,fps=30,format=yuv420p',
  '-c:v',
  encoder,
  if (encoder == 'libx264') ...[
    '-preset',
    'veryfast',
    '-crf',
    '18',
  ] else ...[
    '-b:v',
    '6M',
  ],
  '-threads',
  '2',
  output,
];

List<String> exportArguments({
  required ReelProject project,
  required String audio,
  required String background,
  required String overlayList,
  required String output,
  required String encoder,
  String copyright = '',
}) {
  final fit = backgroundFilter(project);
  final duration = project.duration.toStringAsFixed(6);
  return [
    '-y',
    '-hide_banner',
    '-loglevel',
    'warning',
    '-filter_complex_threads',
    '1',
    if (project.videoBackground) ...[
      '-stream_loop',
      '-1',
    ] else ...[
      '-loop',
      '1',
      '-framerate',
      '30',
    ],
    '-i',
    background,
    '-ss',
    project.trimStart.toStringAsFixed(6),
    '-i',
    audio,
    '-f',
    'concat',
    '-safe',
    '0',
    '-i',
    overlayList,
    '-filter_complex',
    '[0:v]setpts=PTS-STARTPTS,$fit,setsar=1,fps=30[bg];'
        '[2:v]setpts=PTS-STARTPTS,format=rgba,fps=30[text];'
        '[bg][text]overlay=0:0:eof_action=repeat:format=auto,format=yuv420p[v];'
        '[1:a]atrim=duration=$duration,asetpts=PTS-STARTPTS[a]',
    '-map',
    '[v]',
    '-map',
    '[a]',
    '-t',
    duration,
    '-r',
    '30',
    '-c:v',
    encoder,
    if (encoder == 'libx264') ...[
      '-preset',
      'veryfast',
      '-crf',
      '20',
    ] else ...[
      '-b:v',
      '6M',
    ],
    '-threads',
    '2',
    '-c:a',
    'aac',
    '-b:a',
    '192k',
    '-ar',
    '48000',
    '-movflags',
    '+faststart',
    '-metadata',
    'comment=Quran text: Tanzil.net, Uthmani 1.1, CC BY 3.0; font: Amiri Quran (OFL 1.1)',
    '-metadata',
    'copyright=$copyright',
    output,
  ];
}
