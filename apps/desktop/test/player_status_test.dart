import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_relay_core/core.dart';
import 'package:starsync/src/controls/frame.dart';
import 'package:starsync/src/controls/minimal/style.dart';
import 'package:starsync/src/controls/minimal/timeline.dart';
import 'package:starsync/src/session/connection.dart';
import 'package:starsync/src/session/delivery.dart' show MemberNames;
import 'package:starsync/src/session/app_events.dart';
import 'package:starsync/src/session/status.dart';
import 'package:starsync/src/session/now_playing.dart';
import 'package:starsync/src/shell/now_playing_title.dart';
import 'package:starsync/src/shell/session_player.dart';
import 'package:starsync/src/shell/start_banner.dart';

import 'test_graph.dart';

/// This file's composition root (see test_graph.dart).
final _graph = testGraph();

// The one computed status (each input → text and level), the player's
// title block, start card and status pill (never a media_kit `Video`).

/// A 1x1 transparent PNG.
final png = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, //
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
]);

MemberView mv(String id, String name,
        {double buffered = 30, bool gone = false, Presence presence = Presence.watching, bool loading = false}) =>
    MemberView(id: id, name: name, buffered: buffered, gone: gone, presence: presence, loading: loading);

StateBroadcast held(List<MemberView> members,
        {String transport = 'held',
        double position = 0,
        int mediaId = 1,
        MediaRelay? relay,
        bool wants = false,
        HoldInfo? hold}) =>
    StateBroadcast(
      eventId: 1,
      transport: transport,
      position: position,
      serverTime: DateTime.now().toUtc(),
      mediaId: mediaId,
      media: {'name': 'Movie.mkv', 'size': 1, 'duration': 0, if (relay != null) 'relay': relay.toJson()},
      members: members,
      wantsPlay: wants,
      hold: hold,
    );

final _now = DateTime.utc(2026, 1, 1, 12);

/// The status of [state] as member [self] sees it, online unless [conn].
Status st(StateBroadcast? state,
        {MemberView? self,
        ConnState conn = const ConnOnline(),
        String playerError = '',
        String playerFault = '',
        bool ownPlan = false,
        int fetchFailedFor = -1,
        MemberNames? names,
        String? pausedBy,
        DateTime? now}) =>
    statusOf(StatusFacts(
      conn: conn,
      state: state,
      selfId: self?.id ?? '',
      playerError: playerError,
      playerFault: playerFault,
      ownPlan: ownPlan,
      fetchFailedFor: fetchFailedFor,
      names: names,
      pausedBy: pausedBy,
      now: now ?? _now,
    ));

StatusLine? line(StateBroadcast? state, {MemberView? self, ConnState conn = const ConnOnline(), String playerError = ''}) =>
    st(state, self: self, conn: conn, playerError: playerError).line;

void main() {
  final coord = _graph.coordinator;

  tearDown(() {
    debugArtBytes = null;
    coord.serverState.value = null;
    coord.playback.alive.value = false;
  });

  group('status', () {
    final me = mv('me', 'Me');
    final bob = mv('b', 'Bob', presence: Presence.brb);

    test('the connection first: reconnecting, unstable, refused, replaced, connecting', () {
      final r = held([me]);
      for (final (conn, text, level, action) in [
        (const ConnLost(), 'Reconnecting…', StatusLevel.warn, StatusAction.cancel),
        (const ConnReconnecting(2), 'Reconnecting…', StatusLevel.warn, StatusAction.cancel),
        (const ConnUnstable(), 'Connection unstable…', StatusLevel.warn, null),
        (const ConnRefused('secret', 'wrong password'), 'Wrong password', StatusLevel.error, StatusAction.retry),
        (const ConnReplaced(), replacedText, StatusLevel.error, StatusAction.retry),
        (const ConnConnecting(), 'Connecting…', StatusLevel.info, null),
      ]) {
        final v = line(r, self: me, conn: conn)!;
        expect((v.text, v.level, v.action), (text, level, action), reason: '$conn');
      }
      // Being out does not hide the connection.
      final out = mv('me', 'Me', presence: Presence.out);
      expect(line(held([out]), self: out, conn: const ConnLost())!.text, 'Reconnecting…');
    });

    test('the party line: connecting, reconnecting with the state kept, who stands where', () {
      expect(st(null, conn: const ConnConnecting()).party, 'connecting…');
      final r = held([me, bob, mv('c', 'Cleo', presence: Presence.out), mv('z', 'Zed', gone: true)]);
      expect(st(r, self: me, conn: const ConnLost()).party, 'reconnecting…');
      expect(st(r, self: me).party, '1 watching · 1 BRB · 1 out', reason: 'gone is not counted');
    });

    test('nothing to say: playing, about to play, nothing up', () {
      expect(line(held([me], transport: 'playing'), self: me), isNull);
      expect(line(held([me], wants: true), self: me), isNull, reason: 'it wants to play and waits for nobody');
      expect(line(null), isNull);
    });

    test('a plain pause says who paused', () {
      final r = held([me, mv('c', 'Cleo')]);
      expect(st(r, self: me).line!.text, 'Paused');
      expect(st(r, self: me, pausedBy: 'c').line!.text, 'Paused by Cleo');
      final mine = st(r, self: me, pausedBy: 'me').line!;
      expect((mine.kind, mine.text), (StatusKind.paused, 'Paused by you'));
      expect(mine.keys, isEmpty);
    });

    test('BRB: "Waiting for Bob" when it plays once they are back, "Paused · waiting for" when not; the keys', () {
      var v = line(held([me, bob], wants: true, hold: const HoldInfo(brb: ['b'])), self: me)!;
      expect((v.kind, v.text), (StatusKind.waiting, 'Waiting for Bob'));
      expect(v.keys, [('Space', 'BRB too'), ('Hold Space', 'continue without')]);
      expect(v.who.single.id, 'b');
      v = line(held([me, bob], hold: const HoldInfo(brb: ['b'])), self: me)!;
      expect(v.text, 'Paused · waiting for Bob');
      final many = [for (final n in ['Bob', 'Chiyo', 'Dan', 'Eve']) mv(n, n, presence: Presence.brb)];
      v = line(held([me, ...many], wants: true, hold: HoldInfo(brb: [for (final m in many) m.id])), self: me)!;
      expect(v.text, 'Waiting for Bob, Chiyo and 2 more');
    });

    test('you are BRB: "Waiting for you", Space brings you back (the pill too)', () {
      final brbMe = mv('me', 'Me', presence: Presence.brb);
      var v = line(held([brbMe, bob], wants: true, hold: const HoldInfo(brb: ['me', 'b'])), self: brbMe)!;
      expect((v.kind, v.text, v.self, v.action), (StatusKind.you, 'Waiting for you and Bob', true, StatusAction.back));
      expect(v.keys, [('Space', "I'm back"), ('Hold Space', 'continue without')]);
      expect(v.tappable, isTrue);
      v = line(held([brbMe, mv('b', 'Bob')], hold: const HoldInfo(brb: ['me'])), self: brbMe)!;
      expect(v.text, 'Paused · waiting for you');
      expect(v.keys, [('Space', "I'm back")]);
    });

    test('a video: whoever is loading, or yours', () {
      final slow = mv('b', 'Bob', buffered: RelayConstants.minBufferSecs / 2, loading: true);
      final v = line(held([me, slow, mv('c', 'Cleo')], wants: true, hold: const HoldInfo(video: ['b'])), self: me)!;
      expect((v.kind, v.text), (StatusKind.waiting, 'Waiting for Bob'));
      expect(v.who.single.id, 'b');
      expect(v.progress, closeTo(0.5, 1e-9));
      final mine = mv('me', 'Me', buffered: 0);
      expect(line(held([mine], wants: true, hold: const HoldInfo(video: ['me'])), self: mine)!.text,
          'Loading the video…');
      expect(line(held([me, slow], hold: const HoldInfo(video: ['b'])), self: me)!.text, 'Paused',
          reason: 'paused, nobody waits for a video');
    });

    test('out and AFK: said, and how to come back', () {
      final out = mv('me', 'Me', presence: Presence.out);
      var v = line(held([out, mv('b', 'Bob')], transport: 'playing'), self: out)!;
      expect((v.kind, v.text, v.action), (StatusKind.out, "You're out", StatusAction.join));
      expect(v.keys, [('Space', 'Join')]);
      final afk = mv('me', 'Me', presence: Presence.afk);
      v = line(held([afk, mv('b', 'Bob')]), self: afk)!;
      expect((v.kind, v.text), (StatusKind.afk, "You're AFK"));
      expect(v.keys, [('Any key', 'back')]);
    });

    test('finished', () {
      expect(line(held([me], transport: 'finished'), self: me)!.text, 'Finished · seek back or pick the next video');
    });

    test("can't play: yours with Reload, a broken player too; others' instead of a plain pause", () {
      var v = line(held([me]), self: me, playerError: 'Not allowed (403)')!;
      expect((v.kind, v.text, v.action, v.level),
          (StatusKind.problem, "Can't play this: Not allowed (403)", StatusAction.reload, StatusLevel.error));
      v = st(held([me]), self: me, playerFault: 'video reload failed: gone').line!;
      expect((v.text, v.action), ('Video reload failed: gone', StatusAction.reload));
      const bad = MemberView(id: 'b', name: 'Bob', buffered: 0, error: 'Not allowed (403)');
      v = line(held([me, bad, mv('m', 'Mika')]), self: me)!;
      expect((v.kind, v.text, v.action), (StatusKind.cannotPlay, "Bob can't play this: Not allowed (403)", null));
      expect(v.who.single.id, 'b');
    });

    group('the relay', () {
      final bob = mv('b', 'Bob');
      test('the server fetching, then failing', () {
        final r = held([me, bob], relay: const MediaRelay(fetch: true));
        expect((line(r, self: me)!.kind, line(r, self: me)!.text),
            (StatusKind.fetching, 'The server is getting the video…'));
        final failed = st(r, self: me, fetchFailedFor: 1).line!;
        expect((failed.text, failed.level), ("The server couldn't fetch this video", StatusLevel.error));
      });

      test('waiting for the member passing it on', () {
        final v = line(held([me, bob], relay: const MediaRelay(source: 'b')), self: me)!;
        expect((v.text, v.level), ('Waiting for Bob to pass the video on', StatusLevel.warn));
        expect(line(held([me, bob], wants: true, relay: const MediaRelay(source: 'b', live: true)), self: me), isNull);
      });

      test("the source's connection dropped: what the server has, and for how long; even while playing", () {
        const gone = MemberView(id: 'b', name: 'Bob', buffered: 30, gone: true);
        final since = _now.subtract(const Duration(seconds: 20));
        final r = held([me, gone],
            transport: 'playing',
            relay: MediaRelay(source: 'b', live: true, sourceGone: true, sourceGoneSince: since));
        final v = st(r, self: me);
        expect((v.line!.text, v.line!.level), ("Bob's connection dropped — playing what the server has", StatusLevel.warn));
        expect(v.source!.left, isFalse);
        expect(st(r, self: me, now: _now.add(const Duration(minutes: 2))).line!.text,
            "Bob's connection dropped — playing what the server has (2 min)");
        expect(v.delivery!.title, "Bob's connection dropped — playing what the server has");
        // With its own Jellyfin account this viewer does not read the relay.
        expect(st(r, self: me, ownPlan: true).line, isNull);
      });

      test('the source left: named from before', () {
        final names = MemberNames()..observe(held([me, bob]));
        final r = held([me], transport: 'playing', relay: const MediaRelay(source: 'b', sourceGone: true));
        final v = st(r, self: me, names: names);
        expect(v.line!.text, 'Bob left — playing what the server has');
        expect(v.source!.left, isTrue);
      });

      test('the source itself sees none of it', () {
        final r = held([me, bob], wants: true, relay: const MediaRelay(source: 'me'));
        expect(line(r, self: me), isNull);
      });
    });

    test('names read as a sentence', () {
      expect(nameList(['Bob']), 'Bob');
      expect(nameList(['Bob', 'Mika']), 'Bob and Mika');
      expect(nameList(['Bob', 'Mika', 'Cleo']), 'Bob, Mika and Cleo');
      expect(nameList(['Bob', 'Mika', 'Cleo', 'Dan', 'Eve']), 'Bob, Mika and 3 more');
    });
  });

  group('status transitions', () {
    final me = mv('me', 'Me');
    const gone = MemberView(id: 'b', name: 'Bob', buffered: 30, gone: true);

    test('the source gone a few seconds: one notice; left: another', () {
      final w = StatusWatch();
      final r = held([me, gone],
          transport: 'playing', relay: MediaRelay(source: 'b', live: true, sourceGone: true, sourceGoneSince: _now));
      expect(w.step(st(r, self: me), _now.add(const Duration(seconds: 2))), isEmpty, reason: 'a quick drop says nothing');
      final at = _now.add(sourceDropNotice);
      expect(w.step(st(r, self: me), at).single, isA<RelaySourceDropped>().having((e) => e.name, 'name', 'Bob'));
      expect(w.step(st(r, self: me), at.add(const Duration(seconds: 1))), isEmpty, reason: 'once');
      final names = MemberNames()..observe(r);
      final left = held([me], transport: 'playing', relay: const MediaRelay(source: 'b', sourceGone: true));
      expect(w.step(st(left, self: me, names: names), at).single,
          isA<RelaySourceDropped>().having((e) => e.left, 'left', isTrue));
    });

    test('starting now: the first start of a media seen held, not a resume or a join mid-way', () {
      final w = StatusWatch();
      expect(w.step(st(held([me], transport: 'playing', mediaId: 7), self: me), _now), isEmpty,
          reason: 'joined while it played');
      w.step(st(held([me]), self: me), _now);
      final started = w.step(st(held([me], transport: 'playing'), self: me), _now);
      expect(started.single, isA<PlaybackStarted>().having((e) => e.title, 'title', isNotEmpty));
      w.step(st(held([me]), self: me), _now);
      expect(w.step(st(held([me], transport: 'playing'), self: me), _now), isEmpty, reason: 'a resume');
    });

    test('replaced and a restarted server, once each', () {
      final w = StatusWatch();
      w.step(statusOf(StatusFacts(conn: const ConnOnline(), now: _now)), _now);
      expect(w.step(statusOf(StatusFacts(conn: const ConnReplaced(), now: _now)), _now).single, isA<Replaced>());
      expect(w.step(statusOf(StatusFacts(conn: const ConnReplaced(), now: _now)), _now), isEmpty);
      expect(w.step(statusOf(StatusFacts(conn: const ConnOnline(), restarts: 1, now: _now)), _now).single,
          isA<ServerRestarted>());
      expect(w.step(statusOf(StatusFacts(conn: const ConnOnline(), restarts: 1, now: _now)), _now), isEmpty);
    });
  });

  group('title block', () {
    Widget host(Widget child, {double width = 400}) => MaterialApp(
          home: Scaffold(backgroundColor: Colors.black, body: Center(child: SizedBox(width: width, child: child))),
        );
    const now = NowPlaying(title: 'Frieren', episode: 'S1 E4 · The Land Where Souls Rest', posterHash: 'p');

    testWidgets('title, episode and a placeholder cover without art', (tester) async {
      await tester.pumpWidget(scoped(_graph, host(const NowPlayingBlock(now: now))));
      expect(find.text('Frieren'), findsOneWidget);
      expect(find.text('S1 E4 · The Land Where Souls Rest'), findsOneWidget);
      expect(find.byIcon(Icons.movie_outlined), findsOneWidget);
      expect(find.byType(Image), findsNothing);
      final cover = tester.getSize(find.byType(ArtCover));
      expect(cover, const Size(40, 60));
    });

    testWidgets('the cover image once its bytes are here', (tester) async {
      debugArtBytes = (hash) => hash == 'p' ? png : null;
      await tester.pumpWidget(scoped(_graph, host(const NowPlayingBlock(now: now))));
      final image = tester.widget<Image>(find.byType(Image));
      expect((image.image as MemoryImage).bytes, png);
      expect(image.gaplessPlayback, isTrue);
    });

    testWidgets('no cover, no episode: just the title; long titles ellipsize', (tester) async {
      await tester.pumpWidget(scoped(_graph, host(
          NowPlayingBlock(now: NowPlaying(title: 'A very long title ' * 10), cover: false, compact: true),
          width: 200)));
      expect(find.byType(ArtCover), findsNothing);
      expect(find.byKey(const ValueKey('now-playing-episode')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('start banner: up before playback, fades on play, never back for that media', (tester) async {
    await tester.pumpWidget(scoped(_graph, const MaterialApp(home: SizedBox(width: 1280, height: 720, child: StartBanner()))));
    final card = find.byKey(const ValueKey('start-card-title'));
    expect(card, findsNothing);
    coord.serverState.value = held([mv('a', 'Alex')]);
    await tester.pump();
    expect(card, findsOneWidget);
    expect(find.text(coord.nowPlaying.value!.title), findsWidgets);
    expect(tester.widget<AnimatedOpacity>(find.byKey(const ValueKey('start-banner'))).opacity, 1);
    coord.serverState.value = held([mv('a', 'Alex')], transport: 'playing');
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
      await tester.pumpWidget(scoped(_graph, MaterialApp(theme: ThemeData.dark(), home: Scaffold(body: child))));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }

    for (final size in sizes) {
      testWidgets('session player, status pill: ${size.width.toInt()}', (tester) async {
        coord.playback.alive.value = true;
        coord.serverState.value = held(crowd, wants: true, hold: HoldInfo(brb: [for (final m in crowd) m.id]));
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
            onOpenAccounts: () {},
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
