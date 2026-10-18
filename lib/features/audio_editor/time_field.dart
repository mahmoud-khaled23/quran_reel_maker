import 'package:flutter/material.dart';

import 'time_format.dart';
export 'time_format.dart';

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
    text: timeLabel(widget.value),
  );
  String? error;
  @override
  void didUpdateWidget(TimeField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) {
      controller.text = timeLabel(widget.value);
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
    if (text == timeLabel(widget.value)) {
      setState(() => error = null);
      return;
    }
    final value = parseTime(text);
    if (value == null || !value.isFinite || value < 0) {
      setState(() => error = 'Use HH:MM:SS:FFF');
      return;
    }
    final accepted = widget.onChanged(value);
    setState(() => error = accepted ? null : 'Timing was not applied');
  }

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    keyboardType: TextInputType.datetime,
    decoration: InputDecoration(
      labelText: widget.label,
      hintText: 'HH:MM:SS:FFF',
      errorText: error,
    ),
    onSubmitted: submit,
    onTapOutside: (_) {
      submit(controller.text);
      FocusScope.of(context).unfocus();
    },
  );
}
