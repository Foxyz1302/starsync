import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit_video/media_kit_video.dart' show VideoState;
import 'package:sync_relay_core/core.dart';
import 'package:starsync/src/controls/frame.dart' show ControlsFrame, ControlsFrameState;
import 'package:starsync/src/controls/model/controls_prefs.dart';
import 'package:starsync/src/controls/session_controls.dart' show SessionControls, controlsBottomHeight;
import 'package:starsync/src/session/app_events.dart' show ChatPosted;
import 'package:starsync/src/session/notifier.dart' show Copied;
import 'package:starsync/src/session/identity.dart';
import 'package:starsync/src/shell/app_shell.dart';
import 'package:starsync/src/shell/avatar.dart';
import 'package:starsync/src/shell/motion.dart';
import 'package:starsync/src/shell/party_strip.dart';
import 'package:starsync/src/shell/profile_card.dart';
import 'package:starsync/src/shell/session_player.dart';
import 'package:starsync/src/shell/settings_tab.dart' show SettingsTab;
import 'package:starsync/src/shell/toasts.dart';
import 'package:starsync/src/session/session_coordinator.dart' show ToastItem;
import 'package:starsync/src/state/settings.dart';
import 'package:starsync/src/update/update_controller.dart';
import 'package:starsync/src/update/whats_new.dart';

import 'package:starsync/src/session/invite.dart' show Invite;
import 'package:starsync/src/session/navigation.dart' show Place;

import 'test_graph.dart';

/// A 1x1 PNG.
final _png = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==');

/// This file's composition root (see test_graph.dart).
final _graph = testGraph();

/// Stands in for media_kit's `Video` (which hangs flutter_test) and
/// counts how often one is created.
class FakeVideo extends StatefulWidget {
  static int created = 0;
  const FakeVideo({super.key});

  @override
  State<FakeVideo> createState() => _FakeVideoState();
}

class _FakeVideoState extends State<FakeVideo> {
  @override
  void initState() {
    super.initState();
    FakeVideo.created++;
  }

  @override
  Widget build(BuildContext context) => const ColoredBox(color: Colors.black);
}

MemberView member(String id, String name,
        {Presence presence = Presence.watching, bool gone = false, String app = '', String avatarHash = ''}) =>
    MemberView(
        id: id,
        name: name,
        avatarHash: avatarHash,
        buffered: 30,
        app: app,
        presence: presence,
        gone: gone);

void main() {
  final session = _graph;
  final coord = session.coordinator;

  void online(List<MemberView> members,
      {bool media = true, String transport = 'held', bool wants = false, HoldInfo? hold}) {
    coord.serverState.value = StateBroadcast(
      eventId: 1,
      transport: transport,
      position: 0,
      serverTime: DateTime.now().toUtc(),
      mediaId: media ? 1 : 0,
      media: media ? {'name': 'Movie.mkv', 'size': 1, 'duration': 0} : null,
      members: members,
      wantsPlay: wants,
      hold: hold,
    );
    session.navigation.place.value = Place.friend;
  }

  setUp(() {
    FakeVideo.created = 0;
    session.forms.recents.value = const [];
  });

  tearDown(() {
    session.navigation.place.value = Place.none;
    coord.serverState.value = null;
    coord.playback.alive.value = false;
    session.notifier.clear();
  });

  Future<void> pumpShell(WidgetTester tester, Size size,
      {UpdateController? updates, VideoViewBuilder? video, WhatsNew? whatsNew}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(scoped(_graph, MaterialApp(
      theme: ThemeData.dark(),
      home: AppShell(
        updates: updates ?? UpdateController(currentVersion: '0.0.0-dev'),
        autoUpdateCheck: false,
        whatsNew: whatsNew,
        windowControls: false,
        videoBuilder: video ?? (context, controls) => const FakeVideo(),
        // A real probe (network, yt-dlp) never answers on the test clock.
        linkProbe: (url) async => LinkProbe.file(Uri.parse(url), 1000),
      ),
    )));
    await tester.pumpAndSettle();
  }

  final party = [
    member('a', 'Alex'),
    member('b', 'Bob', presence: Presence.brb),
    member('c', 'Cleo'),
    member('d', 'Dan'),
    member('e', 'Eve', gone: true),
    member('f', 'Finn'),
  ];

  group('version and update bar', () {
    testWidgets('the version at the bottom of Settings, not in the strip; the bar on the tabs, off the full player '
        'until the video ends', (tester) async {
      final updates = UpdateController(currentVersion: '0.0.0-dev');
      await pumpShell(tester, const Size(1280, 800), updates: updates);
      expect(find.byKey(const ValueKey('strip-version')), findsNothing);
      expect(find.textContaining('dev run'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('tab-settings')));
      await tester.pumpAndSettle();
      expect(
          tester.widget<SelectableText>(find.byKey(const ValueKey('settings-version'))).data, contains('dev run'));
      await tester.tap(find.byKey(const ValueKey('tab-library')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('update-bar')), findsNothing);
      updates.status.value = const UpdateStatus(UpdatePhase.available,
          manifest: UpdateManifest(version: '9.9.9', protocol: 1, url: 'http://x/a.tgz', notes: ''),
          canInstall: true);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('update-bar')), findsOneWidget);
      online(party);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('update-bar')), findsNothing);
      final r = coord.serverState.value!;
      coord.serverState.value = StateBroadcast(
        eventId: 2,
        transport: 'finished',
        position: 0,
        serverTime: r.serverTime,
        mediaId: r.mediaId,
        media: r.media,
        members: r.members,
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('update-bar')), findsOneWidget);
    });
  });

  group('what\'s new', () {
    testWidgets('the first start after an update shows the card once', (tester) async {
      final store = MemoryWhatsNewStore(
          seen: '1.3.2',
          notes: const ReleaseNotes(version: '1.3.3', changes: ReleaseChanges(fixed: ['Various bug fixes'])));
      await pumpShell(tester, const Size(1280, 800), whatsNew: WhatsNew(currentVersion: '1.3.3', store: store));
      expect(find.text("What's new in 1.3.3"), findsOneWidget);
      expect(find.text('STARSYNC · UPDATED'), findsOneWidget);
      expect(store.seen, '1.3.3');
      await tester.tap(find.byKey(const ValueKey('whats-new-close')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('whats-new-card')), findsNothing);
      // The next start: nothing.
      await tester.pumpWidget(const SizedBox());
      await pumpShell(tester, const Size(1280, 800), whatsNew: WhatsNew(currentVersion: '1.3.3', store: store));
      expect(find.byKey(const ValueKey('whats-new-card')), findsNothing);
    });
  });

  group('party strip', () {
    testWidgets('home, alone: a plain player\'s strip, Join a friend and Invite (once your server runs)',
        (tester) async {
      await pumpShell(tester, const Size(1280, 800));
      expect(find.byKey(const ValueKey('strip-join')), findsOneWidget);
      expect(find.byKey(const ValueKey('strip-host')), findsNothing, reason: 'no Host: your server is always there');
      expect(find.byKey(const ValueKey('party-avatars')), findsNothing);
      expect(find.byKey(const ValueKey('strip-leave')), findsNothing);
      expect(find.byKey(const ValueKey('strip-chat')), findsNothing);
      expect(tester.getSize(find.byType(PartyStrip)).height, partyStripHeight);
      ButtonStyleButton invite() => tester.widget<ButtonStyleButton>(find.byKey(const ValueKey('strip-invite')));
      expect(invite().onPressed, isNull, reason: 'your server is not up yet');
      final yours = session.yourServer;
      yours.port.value = 40000;
      addTearDown(() {
        yours.port.value = null;
        yours.shared.value = null;
      });
      // On your own server with only you in it: still the plain strip.
      session.navigation.place.value = Place.yours;
      coord.serverState.value = StateBroadcast(
          eventId: 1, transport: 'held', position: 0, serverTime: DateTime.now().toUtc(), mediaId: 0,
          members: [member('', 'Me')]);
      await tester.pumpAndSettle();
      expect(invite().onPressed, isNotNull);
      expect(find.byKey(const ValueKey('party-avatars')), findsNothing);
      expect(find.byKey(const ValueKey('strip-chat')), findsNothing);
      expect(find.byKey(const ValueKey('sharing-chip')), findsNothing);
      // Shared, nobody came yet: the chip says so (and opens the invite).
      yours.shared.value = const Invite(host: '192.168.1.20', port: 8080);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('sharing-chip')), findsOneWidget);
      expect(find.text('port 8080'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('sharing-chip')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('stop-sharing')), findsOneWidget);
      await tester.tapAt(const Offset(40, 700));
      await tester.pumpAndSettle();
      // A friend came: the party, with Invite and no Leave (it is yours).
      coord.serverState.value = StateBroadcast(
          eventId: 2, transport: 'held', position: 0, serverTime: DateTime.now().toUtc(), mediaId: 0,
          members: [member('', 'Me'), member('b', 'Bob')]);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('party-avatars')), findsOneWidget);
      expect(find.byKey(const ValueKey('strip-chat')), findsOneWidget);
      expect(find.byKey(const ValueKey('strip-invite')), findsOneWidget);
      expect(find.byKey(const ValueKey('strip-leave')), findsNothing);
      expect(find.text('Your server'), findsOneWidget);
    });

    testWidgets('online: avatars, server and readiness, chat, Leave', (tester) async {
      await pumpShell(tester, const Size(1280, 800));
      online(party, media: false);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('strip-join')), findsNothing);
      expect(find.byKey(const ValueKey('strip-leave')), findsOneWidget);
      expect(find.byKey(const ValueKey('strip-chat')), findsOneWidget);
      expect(find.text('4 watching · 1 BRB'), findsOneWidget, reason: 'Eve is gone: not counted');
      final stack = find.byKey(const ValueKey('party-avatars'));
      // Five shown, the sixth as "+1"; watching ones first.
      expect(find.descendant(of: stack, matching: find.byType(StatusAvatar)), findsNWidgets(5));
      expect(find.descendant(of: stack, matching: find.text('+1')), findsOneWidget);
      final alex = tester.getTopLeft(find.descendant(of: stack, matching: find.byKey(const ValueKey('stack-a-Alex'))));
      final bob = tester.getTopLeft(find.descendant(of: stack, matching: find.byKey(const ValueKey('stack-b-Bob'))));
      expect(alex.dx, lessThan(bob.dx));
      // Leave asks first.
      await tester.tap(find.byKey(const ValueKey('strip-leave')));
      await tester.pumpAndSettle();
      expect(find.text('Leave server?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(session.navigation.place.value, Place.friend);
    });

    testWidgets('compact below 1100 px: 3 avatars, no server text', (tester) async {
      await pumpShell(tester, const Size(1000, 800));
      online(party, media: false);
      await tester.pumpAndSettle();
      final stack = find.byKey(const ValueKey('party-avatars'));
      expect(find.descendant(of: stack, matching: find.byType(StatusAvatar)), findsNWidgets(3));
      expect(find.descendant(of: stack, matching: find.text('+3')), findsOneWidget);
      expect(find.byKey(const ValueKey('server-label')), findsNothing);
      expect(tester.takeException(), isNull);
    });

  });

  group('popovers', () {
    testWidgets('members card opens from the avatars and closes outside', (tester) async {
      await pumpShell(tester, const Size(1280, 800));
      session.navigation.serverVersion.value = '1.3.0-dev.1';
      addTearDown(() => session.navigation.serverVersion.value = '');
      online([member('a', 'Alex', app: '1.3.0-dev.1'), ...party.skip(1)], media: false);
      await tester.pumpAndSettle();
      // The server label opens it (an avatar is its person's card).
      await tester.tap(find.byKey(const ValueKey('server-label')));
      await tester.pumpAndSettle();
      final card = find.byKey(const ValueKey('members-card'));
      expect(card, findsOneWidget);
      for (final m in party) {
        expect(find.descendant(of: card, matching: find.text(m.name)), findsOneWidget);
      }
      expect(find.descendant(of: card, matching: find.text('reconnecting…')), findsOneWidget);
      // Each member's version in its row, the server's in the header.
      expect(find.descendant(of: card, matching: find.byKey(const ValueKey('version-a'))), findsOneWidget);
      expect(find.descendant(of: card, matching: find.text('1.3.0-dev.1')), findsOneWidget);
      expect(find.descendant(of: card, matching: find.text('Server 1.3.0-dev.1')), findsOneWidget);
      // Someone else: nudge or set them out (no kicking).
      await tester.tap(find.descendant(of: find.byKey(const ValueKey('member-b')), matching: find.byTooltip('More')));
      await tester.pumpAndSettle();
      expect(find.text('Nudge'), findsOneWidget);
      expect(find.text('Out'), findsOneWidget);
      expect(find.text('Kick'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(40, 700));
      await tester.pumpAndSettle();
      expect(card, findsNothing);
    });

    testWidgets('profile card opens from your avatar; its links open Settings', (tester) async {
      await pumpShell(tester, const Size(1280, 800));
      await tester.tap(find.byKey(const ValueKey('strip-profile')));
      await tester.pumpAndSettle();
      expect(find.byType(ProfileCard), findsOneWidget);
      expect(find.text('just you'), findsOneWidget);
      await tester.tap(find.text('Help & about'));
      await tester.pumpAndSettle();
      expect(find.byType(ProfileCard), findsNothing);
      expect(find.text('Dev build — update checks are off'), findsOneWidget);
      // Its Settings link opens Party, where the profile is edited too.
      await tester.tap(find.byKey(const ValueKey('strip-profile')));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(of: find.byType(ProfileCard), matching: find.text('Settings')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('party-you')), findsOneWidget);
    });

    testWidgets('showPopover fades and scales in, Esc closes it', (tester) async {
      await tester.pumpWidget(scoped(_graph, MaterialApp(
        home: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => showPopover<void>(context, at: Alignment.topRight, child: const Text('card')),
              child: const Text('open'),
            ),
          ),
        ),
      )));
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(easeTime ~/ 2);
      final fade = tester.widget<FadeTransition>(
          find.ancestor(of: find.text('card'), matching: find.byType(FadeTransition)).first);
      expect(fade.opacity.value, inExclusiveRange(0.0, 1.0));
      await tester.pumpAndSettle();
      expect(find.text('card'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('card'), findsNothing);
    });
  });

  testWidgets('Ctrl+V outside a field: a link asks, then fills Library → Link', (tester) async {
    await pumpShell(tester, const Size(1280, 800));
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') return {'text': 'https://cdn.example/b.mkv'};
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    // fox_utils' clipboard files: none.
    const pasteboard = MethodChannel('pasteboard');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(pasteboard, (call) async => const <String>[]);
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(pasteboard, null));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('handoff-card')), findsOneWidget);
    expect(find.text('Open in Link'), findsOneWidget); // alone
    await tester.tap(find.byKey(const ValueKey('handoff-openLink')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('handoff-card')), findsNothing);
    final field = tester.widget<TextField>(find.byKey(const ValueKey('link-field')));
    expect(field.controller!.text, 'https://cdn.example/b.mkv');
    expect(tester.takeException(), isNull);
  });

  testWidgets('profile rename goes to the server through the hook', (tester) async {
    final pushed = <String?>[];
    final p = Profile.instance;
    final before = p.push;
    p.push = ({String? name, String? avatar, String? color}) => pushed.add(name);
    addTearDown(() => p.push = before);
    session.forms.form.name = 'Old';
    p.name.value = 'Old';
    await tester.pumpWidget(scoped(_graph, MaterialApp(
      home: Scaffold(body: Center(child: ProfileCard(onOpenSettings: (_) {}))),
    )));
    await tester.enterText(find.byKey(const ValueKey('profile-name')), 'Neo');
    await tester.pump();
    expect(p.name.value, 'Neo');
    expect(session.forms.form.name, 'Neo');
    // Typing settles before it is sent, once.
    expect(pushed, isEmpty);
    await tester.pump(const Duration(milliseconds: 700));
    expect(pushed, ['Neo']);
  });

  testWidgets('player: mini and full share one video, never two', (tester) async {
    coord.playback.alive.value = true;
    await pumpShell(tester, const Size(1280, 800));
    online(party);
    await tester.pumpAndSettle();
    final videos = find.byType(FakeVideo);
    AppShellState shell() => tester.state<AppShellState>(find.byType(AppShell));
    // Joined with something up: it opens full.
    expect(shell().mode, PlayerMode.full);
    expect(videos, findsOneWidget);
    expect(tester.getSize(videos), tester.getSize(find.byKey(const ValueKey('body'))));

    Future<void> stepThrough() async {
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(videos, findsOneWidget);
      }
      await tester.pumpAndSettle();
      expect(videos, findsOneWidget);
    }

    // A tab sends it to the mini player.
    await tester.tap(find.byKey(const ValueKey('tab-settings')));
    await stepThrough();
    expect(shell().mode, PlayerMode.mini);
    expect(tester.getSize(videos), AppShellState.miniSize);
    expect(find.byType(SettingsTab), findsOneWidget);
    // Double-click on the mini: full again.
    final mini = tester.getCenter(videos);
    await tester.tapAt(mini);
    await tester.tapAt(mini);
    await stepThrough();
    expect(shell().mode, PlayerMode.full);
    // F: fullscreen hides the strip; Esc leaves it.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await stepThrough();
    expect(shell().fullscreen, isTrue);
    expect(find.byType(PartyStrip), findsNothing);
    // Player keys are debounced on the wall clock.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 400)));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await stepThrough();
    expect(shell().fullscreen, isFalse);
    expect(find.byType(PartyStrip), findsOneWidget);
    // Esc again: big → mini, not leave; from mini it asks to leave.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 400)));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await stepThrough();
    expect(shell().mode, PlayerMode.mini);
    expect(find.text('Leave server?'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Leave server?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    // Never rebuilt from scratch on the way.
    expect(FakeVideo.created, 1);
    // Offline: no player at all.
    session.navigation.place.value = Place.none;
    await tester.pumpAndSettle();
    expect(videos, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the mini player clears the full player\'s controls (media_kit keeps the last ones on null)',
      (tester) async {
    coord.playback.alive.value = true;
    final given = <PlayerMode, Object?>{};
    PlayerMode mode() => tester.state<AppShellState>(find.byType(AppShell)).mode;
    await pumpShell(tester, const Size(1280, 800), video: (context, controls) {
      given[mode()] = controls;
      return const ColoredBox(color: Color(0xFF7A3B2E));
    });
    online(party);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('tab-settings')));
    await tester.pumpAndSettle();
    expect(mode(), PlayerMode.mini);
    expect(given[PlayerMode.full], isNotNull);
    expect(given[PlayerMode.mini], isNotNull, reason: 'null would keep the full controls');
    expect(given[PlayerMode.mini], isNot(same(given[PlayerMode.full])));
  });

  testWidgets('status pill: who the group waits for, and the keys that act now', (tester) async {
    coord.playback.alive.value = true;
    await pumpShell(tester, const Size(1280, 800));
    online([
      member('a', 'Alex'),
      member('b', 'Bob', presence: Presence.brb),
      member('c', 'Cleo', presence: Presence.brb),
    ], wants: true, hold: const HoldInfo(brb: ['b', 'c']));
    await tester.pumpAndSettle();
    expect(find.text('Waiting for Bob and Cleo'), findsOneWidget);
    expect(find.text('BRB too'), findsOneWidget);
    expect(find.text('continue without'), findsOneWidget);
  });

  test('a version that is not ours stands out (a dev run matches any)', () {
    expect(versionDiffers('1.3.0', own: '1.3.0'), isFalse);
    expect(versionDiffers('1.2.4', own: '1.3.0'), isTrue);
    expect(versionDiffers('', own: '1.3.0'), isFalse);
    expect(versionDiffers('1.2.4', own: '0.0.0-dev'), isFalse);
  });

  test('toasts: feed toasts carry the actor, the rest are the app\'s', () {
    AvatarInfo who(String n) => AvatarInfo(name: n, color: Colors.teal);
    final at = DateTime.now();
    // The actor is exact: "Bob" is not mistaken for "Bob Jr".
    final chat = shellToastFor(ToastItem(id: 1, text: 'Bob Jr: hi there', at: at, actor: 'Bob Jr', chat: true), who);
    expect(chat.who!.name, 'Bob Jr');
    expect(chat.text, 'hi there');
    expect(chat.chat, isTrue);
    final joined = shellToastFor(ToastItem(id: 2, text: 'Bob joined', at: at, actor: 'Bob'), who);
    expect(joined.who!.name, 'Bob');
    expect(joined.text, 'joined');
    expect(joined.icon, Icons.login);
    // A name that is a prefix of a sentence is not guessed without an actor.
    final app = shellToastFor(ToastItem(id: 3, text: 'Bob joined', at: at), who);
    expect(app.who, isNull);
    expect(app.text, 'Bob joined');
    final notice = shellToastFor(ToastItem(id: 4, text: 'Shaders off', at: at), who);
    expect(notice.who, isNull);
    // An Up next add: who, what, and the item's picture.
    final added = shellToastFor(
        ToastItem(id: 5, text: 'Bob added Ep 6 to Up next', at: at, actor: 'Bob', thumb: 'h1'), who);
    expect((added.who!.name, added.text, added.icon, added.thumb),
        ('Bob', 'added Ep 6 to Up next', Icons.playlist_add_rounded, 'h1'));
  });

  testWidgets("toasts slide in and leave when the Notifier's time is up", (tester) async {
    await tester.pumpWidget(scoped(_graph, const MaterialApp(home: Scaffold(body: PartyToasts()))));
    session.notifier.notify(const Copied('Shaders off'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Shaders off'), findsOneWidget);
    await tester.pump(session.notifier.toastLife);
    await tester.pumpAndSettle();
    expect(find.text('Shaders off'), findsNothing);
  });

  for (final skin in ControlsSkin.values) {
    testWidgets('toasts sit above the control bar and follow it (${skin.name})', (tester) async {
      final s = AppSettings.instance;
      s.controlsSkin.value = skin;
      addTearDown(() => s.controlsSkin.value = ControlsSkin.standard);
      coord.playback.alive.value = true;
      await pumpShell(tester, const Size(1280, 800),
          video: (context, controls) => Stack(fit: StackFit.expand, children: [
                const ColoredBox(color: Colors.black),
                if (controls != null) controls(VideoState()),
              ]));
      online(party);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.state<AppShellState>(find.byType(AppShell)).mode, PlayerMode.full);
      expect(tester.state<ControlsFrameState>(find.byType(ControlsFrame)).visible, isTrue);
      session.notifier.notify(const Copied('Link copied'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final body = tester.getRect(find.byKey(const ValueKey('body')));
      final bar = controlsBottomHeight(skin, s.controlsSize.peek());
      final up = tester.getRect(find.byType(ToastCard));
      expect(up.bottom, lessThanOrEqualTo(body.bottom - bar), reason: 'clear of the control bar');
      // The controls hide (3 s): the toasts come down to the edge.
      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(milliseconds: 600));
      expect(tester.state<ControlsFrameState>(find.byType(ControlsFrame)).visible, isFalse);
      final down = tester.getRect(find.byType(ToastCard));
      expect(down.bottom, closeTo(body.bottom - AppShellState.toastInset, 1));
      expect(down.bottom, greaterThan(up.bottom));
      session.navigation.place.value = Place.none;
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
    });
  }

  group('fullscreen party', () {
    Future<void> fullscreen(WidgetTester tester) async {
      coord.playback.alive.value = true;
      await pumpShell(tester, const Size(1280, 800),
          video: (context, controls) => Stack(fit: StackFit.expand, children: [
                const ColoredBox(color: Colors.black),
                if (controls != null) controls(VideoState()),
              ]));
      online(party);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(tester.state<AppShellState>(find.byType(AppShell)).fullscreen, isTrue);
      expect(find.byType(PartyStrip), findsNothing);
    }

    Future<void> done(WidgetTester tester) async {
      session.navigation.place.value = Place.none;
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
    }

    double opacity(WidgetTester tester) => tester
        .widget<AnimatedOpacity>(
            find.ancestor(of: find.byKey(const ValueKey('fullscreen-party')), matching: find.byType(AnimatedOpacity)).first)
        .opacity;

    testWidgets('the avatars come and go with the controls, while it plays too', (tester) async {
      await fullscreen(tester);
      online(party, transport: 'playing');
      await tester.pump(const Duration(milliseconds: 400));
      final frame = tester.state<ControlsFrameState>(find.byType(ControlsFrame));
      expect(frame.visible, isTrue);
      expect(opacity(tester), 1, reason: 'up with the controls, playing');
      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(milliseconds: 600));
      expect(frame.visible, isFalse);
      expect(opacity(tester), 0, reason: 'hidden with them');
      // A hidden stack takes no clicks.
      await tester.tap(find.byKey(const ValueKey('fullscreen-party')), warnIfMissed: false);
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(find.byKey(const ValueKey('members-card')), findsNothing);
      await done(tester);
    });

    testWidgets('a click opens the members card; the player panel moves them aside', (tester) async {
      await fullscreen(tester);
      final stack = find.byKey(const ValueKey('fullscreen-party'));
      final right = tester.getRect(stack).right;
      expect(right, closeTo(1280 - 16, 1));
      // The player panel docks at the right: the avatars sit left of it.
      final model = tester.widget<SessionControls>(find.byType(SessionControls)).model;
      model.panelOpen.value = true;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final panel = tester.getRect(find.byKey(const ValueKey('player-panel-hold')));
      expect(tester.getRect(stack).right, lessThan(panel.left));
      model.panelOpen.value = false;
      await tester.pump(const Duration(milliseconds: 400));
      // People cards, as in the strip: a click on an avatar pins its
      // person's card, which leads to the members card.
      expect(find.descendant(of: stack, matching: find.byKey(const ValueKey('stack-b-Bob'))), findsOneWidget);
      await tester.tap(find.descendant(of: stack, matching: find.byKey(const ValueKey('stack-b-Bob'))));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('person-card')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('person-card')), matching: find.text('Bob')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('person-everyone')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('person-card')), findsNothing);
      final card = find.byKey(const ValueKey('members-card'));
      expect(card, findsOneWidget);
      expect(find.descendant(of: card, matching: find.text('Cleo')), findsOneWidget);
      await tester.tapAt(const Offset(40, 700));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(card, findsNothing);
      await done(tester);
    });
  });

  group('avatars in chat toasts', () {
    tearDown(() {
      coord.connection.client
        ..memberId = ''
        ..wsUri = null
        ..token = '';
      Profile.instance.picture.value = null;
    });

    ImageProvider? toastPicture(WidgetTester tester) => tester
        .widget<StatusAvatar>(find.descendant(of: find.byType(ToastCard), matching: find.byType(StatusAvatar)))
        .info
        .image;

    void chat(String id, String name, String text) => coord.notify(ChatPosted(
        FeedMessage(actor: name, actorId: id, action: 'chat', reason: text, at: DateTime.now().toUtc()),
        own: id == coord.connection.memberId));

    testWidgets('your first message after joining has your picture', (tester) async {
      Profile.instance.picture.value = _png;
      coord.connection.client.memberId = 'a';
      await tester.pumpWidget(scoped(_graph, const MaterialApp(home: Scaffold(body: PartyToasts()))));
      online([member('a', 'Alex', avatarHash: 'ha'), member('b', 'Bob')], media: false);
      chat('a', 'Alex', 'hi');
      await tester.pump();
      await tester.pump();
      expect(find.text('hi'), findsOneWidget);
      expect(toastPicture(tester), isNotNull);
      await tester.pump(session.notifier.toastLife);
      await tester.pumpAndSettle();
    });

    testWidgets("someone's first message: their picture shows once it lands", (tester) async {
      // A real HTTP client (the test binding answers 400 to everything).
      final http = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = http);
      // Serves the picture route like a server does.
      final server = (await tester.runAsync(() => HttpServer.bind(InternetAddress.loopbackIPv4, 0)))!;
      addTearDown(() => server.close(force: true));
      server.listen((req) {
        req.response.add(_png);
        req.response.close();
      });
      coord.connection.client
        ..memberId = 'a'
        ..wsUri = Uri.parse('ws://127.0.0.1:${server.port}/sync')
        ..token = 't';
      await tester.pumpWidget(scoped(_graph, const MaterialApp(home: Scaffold(body: PartyToasts()))));
      online([member('a', 'Alex'), member('b', 'Bob', avatarHash: 'hb')], media: false);
      // Bob's line comes before his picture.
      expect(coord.avatars.bytesFor('hb'), isNull);
      chat('b', 'Bob', 'first!');
      await tester.pump();
      await tester.pump();
      expect(find.text('first!'), findsOneWidget);
      // The fetch runs on the real clock (and its callbacks on the test's).
      for (var i = 0; i < 100 && coord.avatars.bytesFor('hb') == null; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
      }
      expect(coord.avatars.bytesFor('hb'), isNotNull);
      await tester.pump();
      expect(toastPicture(tester), isNotNull, reason: 'the toast shows it once it is here');
      await tester.pump(session.notifier.toastLife);
      await tester.pumpAndSettle();
    });
  });
}
