// restructure: rewrite in step 2 (Status + Notifier): the "status" group
// (one computed level); the title block and overflow checks stay.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_relay_core/core.dart';
import 'package:starsync/src/controls/frame.dart';
import 'package:starsync/src/controls/minimal/style.dart';
import 'package:starsync/src/controls/minimal/timeline.dart';
import 'package:starsync/src/session/health.dart';
import 'package:starsync/src/session/now_playing.dart';
import 'package:starsync/src/shell/now_playing_title.dart';
import 'package:starsync/src/shell/player_status.dart';
import 'package:starsync/src/shell/session_player.dart';
import 'package:starsync/src/shell/start_banner.dart';
import 'package:starsync/src/state/session_state.dart';

// The player's title block, start card and status pill (never a media_kit
// `Video`).

/// A 1x1 transparent PNG.
final png = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, //
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
]);

MemberView mv(String id, String name,
        {bool ready = false, bool? inSet, double buffered = 30, bool stale = false, bool out = false}) =>
    MemberView(id: id, name: name, ready: ready, inSet: inSet ?? ready, buffered: buffered, stale: stale, out: out);

StateBroadcast held(List<MemberView> members, {String transport = 'held', double position = 0, int mediaId = 1}) =>
    StateBroadcast(
      eventId: 1,
      transport: transport,
      position: position,
      serverTime: DateTime.now().toUtc(),
      mediaId: mediaId,
      media: {'name': 'Movie.mkv', 'size': 1, 'duration': 0},
      members: members,
    );

const ok = HealthStatus(HealthSeverity.ok, 'connected');

void main() {
  final coord = SessionState.instance.coordinator;

  tearDown(() {
    debugArtBytes = null;
    coord.serverState.value = null;
    coord.health.value = const HealthStatus(HealthSeverity.info, 'idle');
    coord.playback.alive.value = false;
  });

  group('status', () {
    final me = mv('me', 'Me', ready: true);

    test('problems first: reconnecting, health', () {
      var v = playerStatusFor(health: const HealthStatus(HealthSeverity.warn, 'connection lost — retrying…'),
          reconnecting: true);
      expect(v!.text, 'Reconnecting…');
      expect(v.action, StatusAction.cancel);
      v = playerStatusFor(health: const HealthStatus(HealthSeverity.warn, 'waiting for Bob to pass the video on'),
          state: held([me]), self: me);
      expect(v!.kind, StatusKind.problem);
      expect(v.text, 'Waiting for Bob to pass the video on');
      expect(v.tone, HealthSeverity.warn);
      expect(v.action, StatusAction.retry);
    });

    test('info never shows; connecting only once slow', () {
      expect(playerStatusFor(health: const HealthStatus(HealthSeverity.info, 'connected — waiting for host media…')),
          isNull);
      const connecting = HealthStatus(HealthSeverity.info, 'connecting…');
      expect(playerStatusFor(health: connecting), isNull);
      expect(playerStatusFor(health: connecting, slowConnect: true)!.text, 'Connecting…');
      expect(playerStatusFor(health: ok, state: held([me], transport: 'playing'), self: me), isNull);
      expect(playerStatusFor(health: ok, state: held([me]), self: me), isNull, reason: 'everyone ready');
    });

    test('finished, then whoever is loading', () {
      expect(playerStatusFor(health: ok, state: held([me], transport: 'finished'), self: me)!.text,
          'Finished · seek back or pick the next video');
      final slow = mv('b', 'Bob', ready: true, buffered: RelayConstants.minBufferSecs / 2);
      final v = playerStatusFor(health: ok, state: held([me, slow, mv('c', 'Cleo')]), self: me)!;
      expect(v.kind, StatusKind.loading);
      expect(v.text, 'Bob is loading…');
      expect(v.who.single.id, 'b');
      expect(v.progress, closeTo(0.5, 1e-9));
      final mine = mv('me', 'Me', ready: true, buffered: 0);
      expect(playerStatusFor(health: ok, state: held([mine]), self: mine)!.text, 'Loading the video…');
    });

    test('you, then the others with a ready count', () {
      final notMe = mv('me', 'Me');
      final v = playerStatusFor(health: ok, state: held([notMe, mv('b', 'Bob')]), self: notMe)!;
      expect(v.kind, StatusKind.you);
      expect(v.text, "Press Space when you're ready");
      expect(v.action, StatusAction.ready);
      expect(v.self, isTrue);
      final w = playerStatusFor(
          health: ok,
          state: held([me, mv('b', 'Bob'), mv('m', 'Mika'), mv('z', 'Zed', stale: true), mv('o', 'Ola', out: true)]),
          self: me)!;
      expect(w.kind, StatusKind.waiting);
      expect(w.text, 'Waiting for Bob and Mika', reason: 'nobody waits for who sits out');
      expect(w.detail, '1/3 ready');
      final outMe = mv('me', 'Me', out: true);
      expect(playerStatusFor(health: ok, state: held([outMe, mv('b', 'Bob')]), self: outMe), isNull,
          reason: 'sitting out: the join-back card speaks');
      expect(w.who.map((m) => m.name), ['Bob', 'Mika']);
    });

    test("can't play: yours with Retry (reload); others' instead of waiting", () {
      var v = playerStatusFor(health: ok, state: held([me]), self: me, playerError: 'Not allowed (403)')!;
      expect((v.kind, v.text, v.action), (StatusKind.problem, "Can't play this: Not allowed (403)", StatusAction.reload));
      final bob = MemberView(id: 'b', name: 'Bob', ready: false, inSet: false, buffered: 0, stale: false,
          error: 'Not allowed (403)');
      v = playerStatusFor(health: ok, state: held([me, bob, mv('m', 'Mika', ready: true)]), self: me)!;
      expect((v.kind, v.text, v.action), (StatusKind.cannotPlay, "Bob can't play this: Not allowed (403)", null));
      expect(v.who.single.id, 'b');
      final notMe = mv('me', 'Me');
      v = playerStatusFor(health: ok, state: held([notMe, bob]), self: notMe)!;
      expect((v.kind, v.action), (StatusKind.cannotPlay, StatusAction.ready));
    });

    test('names read as a sentence', () {
      expect(nameList(['Bob']), 'Bob');
      expect(nameList(['Bob', 'Mika']), 'Bob and Mika');
      expect(nameList(['Bob', 'Mika', 'Cleo']), 'Bob, Mika and Cleo');
      expect(nameList(['Bob', 'Mika', 'Cleo', 'Dan', 'Eve']), 'Bob, Mika and 3 others');
    });
  });

  group('title block', () {
    Widget host(Widget child, {double width = 400}) => MaterialApp(
          home: Scaffold(backgroundColor: Colors.black, body: Center(child: SizedBox(width: width, child: child))),
        );
    const now = NowPlaying(title: 'Frieren', episode: 'S1 E4 · The Land Where Souls Rest', posterHash: 'p');

    testWidgets('title, episode and a placeholder cover without art', (tester) async {
      await tester.pumpWidget(host(const NowPlayingBlock(now: now)));
      expect(find.text('Frieren'), findsOneWidget);
      expect(find.text('S1 E4 · The Land Where Souls Rest'), findsOneWidget);
      expect(find.byIcon(Icons.movie_outlined), findsOneWidget);
      expect(find.byType(Image), findsNothing);
      final cover = tester.getSize(find.byType(ArtCover));
      expect(cover, const Size(40, 60));
    });

    testWidgets('the cover image once its bytes are here', (tester) async {
      debugArtBytes = (hash) => hash == 'p' ? png : null;
      await tester.pumpWidget(host(const NowPlayingBlock(now: now)));
      final image = tester.widget<Image>(find.byType(Image));
      expect((image.image as MemoryImage).bytes, png);
      expect(image.gaplessPlayback, isTrue);
    });

    testWidgets('no cover, no episode: just the title; long titles ellipsize', (tester) async {
      await tester.pumpWidget(host(
          NowPlayingBlock(now: NowPlaying(title: 'A very long title ' * 10), cover: false, compact: true),
          width: 200));
      expect(find.byType(ArtCover), findsNothing);
      expect(find.byKey(const ValueKey('now-playing-episode')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('start banner: up before playback, fades on play, never back for that media', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox(width: 1280, height: 720, child: StartBanner())));
    final card = find.byKey(const ValueKey('start-card-title'));
    expect(card, findsNothing);
    coord.serverState.value = held([mv('a', 'Alex')]);
    await tester.pump();
    expect(card, findsOneWidget);
    expect(find.text(coord.nowPlaying.value!.title), findsWidgets);
    expect(tester.widget<AnimatedOpacity>(find.byKey(const ValueKey('start-banner'))).opacity, 1);
    coord.serverState.value = held([mv('a', 'Alex', ready: true)], transport: 'playing');
    await tester.pump();
    expect(tester.widget<AnimatedOpacity>(find.byKey(const ValueKey('start-banner'))).opacity, 0);
    await tester.pumpAndSettle();
    expect(card, findsNothing);
    // Paused back at the start: still gone.
    coord.serverState.value = held([mv('a', 'Alex')]);
    await tester.pumpAndSettle();
    expect(card, findsNothing);
    // The next media gets its own card.
    coord.serverState.value = held([mv('a', 'Alex')], mediaId: 2);
    await tester.pump();
    expect(card, findsOneWidget);
    // Joined mid-way: none.
    coord.serverState.value = held([mv('a', 'Alex')], mediaId: 3, position: 600);
    await tester.pumpAndSettle();
    expect(card, findsNothing);
  });

  group('no overflow', () {
    const sizes = [Size(900, 600), Size(2560, 1080)];
    final long = NowPlaying(title: 'An Extremely Long Series Title ' * 4, episode: 'S12 E104 · ${'Episode ' * 20}',
        posterHash: 'p', bannerHash: 'b');
    final crowd = [
      for (var i = 0; i < 9; i++) mv('$i', 'Someone With A Long Name $i'),
    ];

    Future<void> sized(WidgetTester tester, Size size, Widget child) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(), home: Scaffold(body: child)));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }

    for (final size in sizes) {
      testWidgets('session player, status pill: ${size.width.toInt()}', (tester) async {
        coord.playback.alive.value = true;
        coord.serverState.value = held(crowd);
        await sized(
          tester,
          size,
          SessionPlayer(
            mode: PlayerMode.full,
            fullscreen: false,
            onExpand: () {},
            onCollapse: () {},
            onClose: () {},
            onToggleFullscreen: () {},
            onToggleChat: () {},
            onChangeVideo: () {},
            onOpenIntegrations: () {},
            onLeave: () {},
            windowControls: false,
            videoBuilder: (context, controls) => const ColoredBox(color: Colors.black),
          ),
        );
        expect(find.byKey(const ValueKey('player-status')), findsOneWidget);
        expect(find.textContaining('Waiting for Someone With A Long Name 0'), findsOneWidget);
      });

      testWidgets('minimal top bar and start card: ${size.width.toInt()}', (tester) async {
        debugArtBytes = (hash) => png;
        await sized(
          tester,
          size,
          Stack(fit: StackFit.expand, children: [
            StartCard(now: long),
            ControlsFrame(
              builder: (context, visible) => Stack(children: [
                Positioned(
                  left: 16,
                  right: 10,
                  top: 0,
                  height: 72,
                  child: Row(children: [
                    Expanded(child: NowPlayingBlock(now: long)),
                    for (final i in [Icons.fullscreen, Icons.close])
                      MinimalButton(icon: i, tooltip: '', onPressed: () {}),
                  ]),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: MinimalTimeline(
                      position: Duration.zero,
                      duration: const Duration(minutes: 24),
                      expanded: visible,
                      onSeek: (_) {}),
                ),
              ]),
            ),
          ]),
        );
        expect(find.byType(ArtCover), findsNWidgets(2));
      });

      testWidgets('standard top bar row: ${size.width.toInt()}', (tester) async {
        await sized(
          tester,
          size,
          Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              height: 72,
              child: Row(children: [
                Expanded(child: NowPlayingBlock(now: long)),
                for (final i in [Icons.video_library_outlined, Icons.chat_bubble_outline, Icons.close_fullscreen])
                  IconButton(onPressed: () {}, icon: Icon(i)),
              ]),
            ),
          ),
        );
      });
    }
  });
}
