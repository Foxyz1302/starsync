import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:starsync/src/widgets/text_focus.dart';

import 'test_graph.dart';

/// This file's composition root (see test_graph.dart).
final _graph = testGraph();

void main() {
  // Regression: the old FocusNode-parent walk never met EditableText, so
  // session shortcuts (Space, arrows, F) fired while typing in chat.
  testWidgets('text field focus is detected, buttons are not', (tester) async {
    final field = FocusNode();
    final button = FocusNode();
    await tester.pumpWidget(scoped(_graph, MaterialApp(
      home: Scaffold(
        body: Column(children: [
          TextField(focusNode: field),
          TextButton(focusNode: button, onPressed: () {}, child: const Text('b')),
        ]),
      ),
    )));
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

  testWidgets('focus under a KeyboardClaim counts as typing', (tester) async {
    final claimed = FocusNode();
    await tester.pumpWidget(scoped(_graph, MaterialApp(
      home: KeyboardClaim(child: Focus(focusNode: claimed, child: const SizedBox())),
    )));
    expect(textInputFocused(), isFalse);
    claimed.requestFocus();
    await tester.pump();
    expect(textInputFocused(), isTrue);
    claimed.dispose();
  });
}
