// One device installation runs the existing real FFmpeg/export/segmentation and
// editor workflows. Use the isolated benchmark application ID (see README).
import 'enhanced_media_export_test.dart' as media;
import 'video_segmentation_test.dart' as segmentation;
import 'editor_flow_test.dart' as editor;

void main() {
  media.main();
  segmentation.main();
  editor.main();
}
