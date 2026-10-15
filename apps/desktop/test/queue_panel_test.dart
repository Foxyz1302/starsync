import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:starsync/src/queue/queue_ui.dart';
import 'package:starsync/src/session/session_coordinator.dart';
import 'package:starsync/src/shell/library_link.dart' show LinkPreview;
import 'package:starsync/src/widgets/text_focus.dart';

import 'test_graph.dart';

/// This file's composition root (see test_graph.dart).
final _graph = testGraph();

void main() {
  testWidgets('Up next popover: holds the keys, Ctrl+V adds with a preview row, + Add link opens a field',
      (tester) async {
    final coord = SessionCoordinator();
    var clip = (files: const <String>[], text: 'look https://example.com/v' as String?);
    await tester.pumpWidget(scoped(_graph, MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: Center(
          child: QueuePanel(
            queue: coord.queue,
            onClose: () {},
            readClipboard: () async => clip,
            preview: (url) async => const LinkPreview(title: 'A video', subtitle: 'example.com'),
          ),
        ),
      ),
    )));
    await tester.pump();
    expect(textInputFocused(), isTrue, reason: 'the player keys rest while it is open');
    expect(find.byKey(const ValueKey('queue-add-field')), findsNothing);

    // Ctrl+V: the link goes in at once, as a row with its preview; not in
    // a server here, so it says why.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    await tester.pump();
    expect(find.text('A video'), findsOneWidget);
    expect(find.text('not in a server'), findsOneWidget);

    // Nothing to add on the clipboard.
    clip = (files: const <String>[], text: 'just words');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(find.byKey(const ValueKey('queue-add-error')), findsOneWidget);

    // + Add link: a small field with focus; Esc closes it, focus stays.
    await tester.tap(find.byKey(const ValueKey('queue-add-link')));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('queue-add-field')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byKey(const ValueKey('queue-add-field')), findsNothing);
    expect(textInputFocused(), isTrue);
  });
}
