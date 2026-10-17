import '../../models/reel_project.dart';

class OverlaySpan {
  const OverlaySpan(this.startFrame, this.endFrame, this.cueIndex);
  final int startFrame, endFrame;
  final int? cueIndex;
  double get duration => (endFrame - startFrame) / 30;
}

/// Clip absolute cue times to the trim, rebase once, then quantize to 30 fps.
List<OverlaySpan> overlayTimeline(ReelProject project) {
  final total = (project.duration * 30).round();
  var cursor = 0;
  final spans = <OverlaySpan>[];
  for (var i = 0; i < project.cues.length; i++) {
    final cue = project.cues[i];
    final start = ((cue.start - project.trimStart) * 30).round().clamp(
      0,
      total,
    );
    final end = ((cue.end - project.trimStart) * 30).round().clamp(0, total);
    if (end <= start) continue;
    if (start > cursor) spans.add(OverlaySpan(cursor, start, null));
    spans.add(OverlaySpan(start, end, i));
    cursor = end;
  }
  if (cursor < total) spans.add(OverlaySpan(cursor, total, null));
  return spans;
}

List<String> exportArguments({
  required ReelProject project,
  required String audio,
  required String background,
  required String overlayList,
  required String output,
  required String encoder,
  String copyright = '',
}) {
  final cover = project.fit == BackgroundFit.cover;
  final fit = cover
      ? 'scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920:(iw-ow)*${project.cropX}:(ih-oh)*${project.cropY}'
      : 'scale=1080:1920:force_original_aspect_ratio=decrease,pad=1080:1920:(ow-iw)/2:(oh-ih)/2:color=black';
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
