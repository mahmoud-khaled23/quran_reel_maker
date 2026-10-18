// Runs the same real FFmpeg regression against Android FFmpegKit on a device.
import '../test/enhanced_media_test.dart' as media;

import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  media.main();
}
