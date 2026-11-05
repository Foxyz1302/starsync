import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_relay_core/core.dart';
import 'package:starsync/src/platform/ports/ports.dart';
import 'package:starsync/src/screens/home/picked_media.dart' show LinkRelay;
import 'package:starsync/src/session/navigation.dart' show Place;
import 'package:starsync/src/shell/app_shell.dart';
import 'package:starsync/src/shell/handoff.dart';
import 'package:starsync/src/shell/library_link.dart' show RecentLinks;
import 'package:starsync/src/shell/session_player.dart' show PlayerMode;
import 'package:starsync/src/update/update_controller.dart';

import 'test_graph.dart';

// What a drop or a paste is: decided from paths and text alone (the file
// system stands behind a fake); the card that asks what to do with it.

/// yt-dlp's stand-in: every link is a playable file.
class _Links implements LinkResolver {
  @override
  Future<YtDlp> get ytDlp => throw UnimplementedError();
  @override
  void warmUp() {}
  @override
  bool get resolvesLinks => true;
  @override
  Future<LinkProbe> probe(String url, {Duration keep = Duration.zero, bool fresh = false}) async =>
      LinkProbe.file(Uri.parse(url), 1000);
  @override
  void release(String url) {}
}

final _window = FakeShell();

/// This file's composition root (see test_graph.dart).
final _graph = testGraph(shell: _window, links: _Links());

void main() {
  const fs = {
    '/v/a.mkv': FileSystemEntityType.file,
    '/v/b.MP4': FileSystemEntityType.file,
    '/v/notes.txt': FileSystemEntityType.file,
    '/v/cover.jpg': FileSystemEntityType.file,
    '/v/Season 1': FileSystemEntityType.directory,
    '/v/folder.mkv': FileSystemEntityType.directory,
    r'C:\Videos\c.mkv': FileSystemEntityType.file,
  };
  Handoff of({List<String> paths = const [], String? text}) =>
      classifyHandoff(paths: paths, text: text, typeOf: (p) => fs[p] ?? FileSystemEntityType.notFound);

  test('videos by extension, in order; others dropped with them are left out', () {
    final h = of(paths: ['/v/notes.txt', '/v/b.MP4', '/v/Season 1', '/v/a.mkv']);
    expect((h as HandoffVideos).paths, ['/v/b.MP4', '/v/a.mkv']);
  });

  test('a folder (even one named like a video), else an image, else nothing', () {
    expect((of(paths: ['/v/notes.txt', '/v/folder.mkv']) as HandoffFolder).path, '/v/folder.mkv');
    expect((of(paths: ['/v/cover.jpg']) as HandoffImage).path, '/v/cover.jpg');
    expect(of(paths: ['/v/notes.txt']), isA<HandoffNothing>());
    expect(of(paths: ['/gone/x.mkv']), isA<HandoffNothing>());
    expect(of(), isA<HandoffNothing>());
  });

  test('pasted text: a link, absolute paths or file URIs; files win over text', () {
    expect(of(text: '  https://cdn.example/a b'), isA<HandoffNothing>());
    expect((of(text: ' https://youtu.be/x?t=1 \n') as HandoffLink).url, 'https://youtu.be/x?t=1');
    expect((of(text: 'HTTP://x.example/v.mp4') as HandoffLink).url, 'HTTP://x.example/v.mp4');
    expect((of(text: '/v/a.mkv\n/v/b.MP4') as HandoffVideos).paths, ['/v/a.mkv', '/v/b.MP4']);
    expect((of(text: 'file:///v/Season%201') as HandoffFolder).path, '/v/Season 1');
    expect((of(text: r'C:\Videos\c.mkv') as HandoffVideos).paths, [r'C:\Videos\c.mkv']);
    expect(of(text: 'v/a.mkv'), isA<HandoffNothing>(), reason: 'relative');
    expect(of(text: 'hello'), isA<HandoffNothing>());
    expect((of(paths: ['/v/Season 1'], text: 'https://x.example') as HandoffFolder).path, '/v/Season 1');
  });

  test('handoffName: a link by its site, a file by its name', () {
    expect(handoffName('https://www.youtube.com/watch?v=x'), 'youtube.com');
    expect(handoffName('https://x.com/a/status/1'), 'x.com');
    expect(handoffName('/home/a/Videos/Ep 01.mkv'), 'Ep 01.mkv');
    expect(handoffName('file:///home/a/b.mp4'), 'b.mp4');
  });

  group('the card', () {
    Future<HandoffAction?> show(WidgetTester tester, Widget card, {String? tap}) async {
      HandoffAction? picked;
      // A fresh app: no card left open from before.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async => picked = await showDialog<HandoffAction>(context: context, builder: (_) => card),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      if (tap != null) {
        await tester.tap(find.byKey(ValueKey('handoff-$tap')));
        await tester.pumpAndSettle();
      }
      return picked;
    }

    bool filled(WidgetTester tester, String action) =>
        tester.widget(find.byKey(ValueKey('handoff-$action'))) is FilledButton;

    double left(WidgetTester tester, String action) => tester.getTopLeft(find.byKey(ValueKey('handoff-$action'))).dx;

    // P41: a pasted link took "Put it up as a link…" and then Put it up on
    // the Link page, against one click for Add to queue.
    testWidgets('a link goes up in one click, in the Link page\'s way, first and filled', (tester) async {
      const card = HandoffCard(
          item: HandoffLink('https://cdn.example/b.mkv'), alone: false, queue: true, linkWay: LinkRelay.direct);
      expect(await show(tester, card, tap: 'putUp'), HandoffAction.putUp);
      await show(tester, card);
      expect(find.text('Put it up'), findsOneWidget);
      expect(filled(tester, 'putUp'), isTrue);
      expect(filled(tester, 'queue'), isFalse);
      expect(left(tester, 'putUp'), lessThan(left(tester, 'queue')));
      expect(find.text('Everyone fetches it · other ways on the Link page'), findsOneWidget);
      expect(find.text('Other ways…'), findsOneWidget, reason: 'the Link page, to pick another way');
    });

    testWidgets('while others watch something, Up next leads and putting up says "now"', (tester) async {
      const link = HandoffCard(item: HandoffLink('https://cdn.example/b.mkv'), alone: false, queue: true, replaces: true);
      expect(await show(tester, link, tap: 'putUp'), HandoffAction.putUp, reason: 'still one click');
      await show(tester, link);
      expect(find.text('Put it up now'), findsOneWidget);
      expect(filled(tester, 'putUp'), isFalse);
      expect(filled(tester, 'queue'), isTrue);
      expect(left(tester, 'queue'), lessThan(left(tester, 'putUp')));
      expect(find.text('Through you · other ways on the Link page'), findsOneWidget);

      const video = HandoffCard(item: HandoffVideos(['/v/a.mkv']), alone: false, queue: true, replaces: true);
      await show(tester, video);
      expect(find.text('Put it up now'), findsOneWidget);
      expect(filled(tester, 'queue'), isTrue);
    });

    testWidgets('alone: Play at once (straight from the site), Open in Link to see it first', (tester) async {
      const card = HandoffCard(item: HandoffLink('https://cdn.example/b.mkv'), alone: true, queue: true, replaces: true);
      expect(await show(tester, card, tap: 'putUp'), HandoffAction.putUp);
      await show(tester, card);
      expect(find.text('Play'), findsOneWidget);
      expect(filled(tester, 'putUp'), isTrue, reason: 'nobody else watches: nothing to replace for others');
      expect(find.text('Open in Link'), findsOneWidget);
      expect(find.text('Plays straight from the site'), findsOneWidget);
    });
  });

  testWidgets('Ctrl+V of a link, Put it up: it goes up at once and joins Recent', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final coord = _graph.coordinator;
    addTearDown(() {
      _graph.navigation.place.value = Place.none;
      coord.serverState.value = null;
      _graph.notifier.clear();
    });
    final recents = RecentLinks(read: () async => null, write: (_) async {});
    await tester.pumpWidget(scoped(_graph, MaterialApp(
      theme: ThemeData.dark(),
      home: AppShell(
        updates: UpdateController(currentVersion: '0.0.0-dev'),
        autoUpdateCheck: false,
        windowControls: false,
        videoBuilder: (context, controls) => const SizedBox(),
        linkProbe: (url) async => LinkProbe.file(Uri.parse(url), 1000),
        recentLinks: recents,
      ),
    )));
    // A friend's server, others there, nothing on yet.
    coord.serverState.value = StateBroadcast(
      eventId: 1,
      transport: 'held',
      position: 0,
      serverTime: DateTime.now().toUtc(),
      mediaId: 0,
      members: [
        MemberView(id: 'a', name: 'Alex', ready: false, inSet: false, buffered: 0),
        MemberView(id: 'b', name: 'Bob', ready: false, inSet: false, buffered: 0),
      ],
    );
    _graph.navigation.place.value = Place.friend;
    await tester.pumpAndSettle();
    // Everyone fetches it (a link through you needs a real yt-dlp).
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('media-source')), matching: find.text('Link')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('link-other-ways')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('link-mode-direct')));
    await tester.pumpAndSettle();

    const url = 'https://cdn.example/b.mkv';
    _window.paste = (files: const <String>[], text: url);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('handoff-card')), findsOneWidget);
    expect(find.text('Everyone fetches it · other ways on the Link page'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('handoff-putUp')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('handoff-card')), findsNothing);
    // Gone up (no server behind this test: the swap itself says reconnecting).
    expect(tester.state<AppShellState>(find.byType(AppShell)).mode, PlayerMode.full);
    expect(recents.links.value.map((l) => l.url), [url]);
    expect(tester.takeException(), isNull);
    // Let the toasts' timers run out.
    await tester.pump(const Duration(seconds: 10));
  });
}
