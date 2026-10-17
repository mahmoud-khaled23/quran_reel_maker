import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quran_reel_maker/features/audio_editor/time_field.dart';

void main() {
  testWidgets('rejected timing stays marked until a valid edit is applied', (
    tester,
  ) async {
    var saved = 1.0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => TimeField(
              label: 'Start',
              value: saved,
              onChanged: (value) {
                if (value >= 3) return false;
                setState(() => saved = value);
                return true;
              },
            ),
          ),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), '4');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(saved, 1);
    expect(find.text('Timing was not applied'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '2');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(saved, 2);
    expect(find.text('Timing was not applied'), findsNothing);
  });

  testWidgets('unchanged display does not round precise source timestamps', (
    tester,
  ) async {
    var changes = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TimeField(
            label: 'Start',
            value: 1 / 3,
            onChanged: (_) {
              changes++;
              return true;
            },
          ),
        ),
      ),
    );
    await tester.showKeyboard(find.byType(TextField));
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(changes, 0);
    expect(find.text('0.333'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'NaN');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(changes, 0);
    expect(find.text('Enter seconds ≥ 0'), findsOneWidget);
  });
}
