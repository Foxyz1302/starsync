import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_together/src/widgets/text_focus.dart';

void main() {
  // Regression: the old FocusNode-parent walk never met EditableText, so
  // session shortcuts (Space, arrows, F) fired while typing in chat.
  testWidgets('text field focus is detected, buttons are not', (tester) async {
    final field = FocusNode();
    final button = FocusNode();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(children: [
          TextField(focusNode: field),
          TextButton(focusNode: button, onPressed: () {}, child: const Text('b')),
        ]),
      ),
    ));
    expect(textInputFocused(), isFalse);

    field.requestFocus();
    await tester.pump();
    expect(field.hasPrimaryFocus, isTrue);
    expect(textInputFocused(), isTrue);

    button.requestFocus();
    await tester.pump();
    expect(textInputFocused(), isFalse);

    field.dispose();
    button.dispose();
  });
}
