import 'package:flutter/material.dart';

String timeLabel(double seconds) {
  final milliseconds = (seconds * 1000).round();
  final minutes = milliseconds ~/ 60000;
  return '$minutes:${((milliseconds ~/ 1000) % 60).toString().padLeft(2, '0')}.'
      '${(milliseconds % 1000).toString().padLeft(3, '0')}';
}

class TimeField extends StatefulWidget {
  const TimeField({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
  });
  final String label;
  final double value;

  /// Returns false when the editor rejects a trim or cue boundary.
  final bool Function(double) onChanged;
  @override
  State<TimeField> createState() => _TimeFieldState();
}

class _TimeFieldState extends State<TimeField> {
  late final TextEditingController controller = TextEditingController(
    text: widget.value.toStringAsFixed(3),
  );
  String? error;
  @override
  void didUpdateWidget(TimeField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) {
      controller.text = widget.value.toStringAsFixed(3);
      error = null;
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void submit(String text) {
    // Display precision must not rewrite a valid, more precise cue on blur.
    if (text == widget.value.toStringAsFixed(3)) {
      setState(() => error = null);
      return;
    }
    final value = double.tryParse(text);
    if (value == null || !value.isFinite || value < 0) {
      setState(() => error = 'Enter seconds ≥ 0');
      return;
    }
    final accepted = widget.onChanged(value);
    setState(() => error = accepted ? null : 'Timing was not applied');
  }

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    keyboardType: const TextInputType.numberWithOptions(decimal: true),
    decoration: InputDecoration(
      labelText: widget.label,
      suffixText: 's',
      errorText: error,
    ),
    onSubmitted: submit,
    onTapOutside: (_) {
      submit(controller.text);
      FocusScope.of(context).unfocus();
    },
  );
}
