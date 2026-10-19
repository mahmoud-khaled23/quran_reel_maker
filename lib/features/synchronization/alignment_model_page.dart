import 'package:flutter/material.dart';

import 'alignment_engine.dart';
import 'android_alignment_engine.dart';

class AlignmentModelPage extends StatefulWidget {
  const AlignmentModelPage({super.key, required this.store});
  final AlignmentModelStore store;
  @override
  State<AlignmentModelPage> createState() => _AlignmentModelPageState();
}

class _AlignmentModelPageState extends State<AlignmentModelPage> {
  AlignmentCancellation? token;
  bool busy = false;
  double progress = 0;
  String status = 'Checking local installation…';
  @override
  void initState() {
    super.initState();
    check();
  }

  Future<void> check() async {
    try {
      final installed = await widget.store.isInstalled();
      if (mounted && !busy) {
        setState(
          () => status = installed
              ? 'Model file is present. Its SHA-256 is verified before every alignment.'
              : 'Model not installed. Manual timing remains available.',
        );
      }
    } catch (_) {
      if (mounted && !busy) {
        setState(
          () => status = 'Cannot read the model installation. Check free storage and use Download / repair. Manual timing remains available.',
        );
      }
    }
  }

  @override
  void dispose() {
    token?.cancel();
    super.dispose();
  }

  Future<void> install() async {
    token = AlignmentCancellation();
    setState(() {
      busy = true;
      progress = 0;
      status = 'Starting model setup…';
    });
    try {
      await widget.store.install(
        cancellation: token!,
        onProgress: (value, message) {
          if (mounted) {
            setState(() {
              progress = value;
              status = message;
            });
          }
        },
      );
      if (mounted) {
        setState(
          () => status = 'Verified model ready. Inference works offline. Listen to and review the generated timings.',
        );
      }
    } catch (error) {
      if (mounted) setState(() => status = error.toString());
    } finally {
      if (mounted) setState(() => busy = false);
      token = null;
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Alignment model')),
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Text(
          'Quran CTC · offline Android candidate',
          style: TextStyle(fontSize: 22),
        ),
        const SizedBox(height: 12),
        const SelectableText(
          'Aligns your selected canonical Quran words to the recording. Requires a 64-bit Android installation. '
          'Download: 241.2 MB; allow at least 300 MB free storage plus space for your audio/video. '
          'Alignment needs at least 1,200 MiB available RAM to start; close other apps if Android reports memory pressure. '
          'Setup uses the internet. Alignment uses local CPU inference and does not upload audio.\n\n'
          'This candidate has not yet passed independently annotated word-accuracy or Galaxy A52s resource targets. '
          'Automatic times are drafts: review every boundary. Crop introductions and repeated passages, select the exact partial ayah, '
          'and use manual corrections for uncertain words.\n\n'
          'Model: mostafanewir70/quran-recitation-ctc-onnx, q4 revision '
          'f90650aac5d9dcff15230a19998c0027f45b33f1. Publisher declares Apache-2.0. '
          'Quran fine-tune: rabah2026/wav2vec2-large-xlsr-53-arabic-quran-v_final. '
          'Runtime: ONNX Runtime 1.23.2 (MIT). Full provenance and evaluation procedure are in docs/ANDROID_ALIGNMENT.md.',
        ),
        const SizedBox(height: 20),
        if (busy) LinearProgressIndicator(value: progress),
        const SizedBox(height: 12),
        SelectableText(status),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          children: [
            FilledButton.icon(
              onPressed: busy ? null : install,
              icon: const Icon(Icons.download),
              label: const Text('Download / repair'),
            ),
            if (busy)
              TextButton(
                onPressed: () => token?.cancel(),
                child: const Text('Cancel download'),
              ),
          ],
        ),
      ],
    ),
  );
}
