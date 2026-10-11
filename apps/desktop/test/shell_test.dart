import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_relay_core/core.dart';
import 'package:watch_together/src/screens/home/profile.dart';
import 'package:watch_together/src/shell/app_shell.dart';
import 'package:watch_together/src/shell/avatar.dart';
import 'package:watch_together/src/shell/motion.dart';
import 'package:watch_together/src/shell/party_strip.dart';
import 'package:watch_together/src/shell/profile_card.dart';
import 'package:watch_together/src/shell/session_player.dart';
import 'package:watch_together/src/shell/settings_tab.dart' show SettingsTab;
import 'package:watch_together/src/shell/toasts.dart';
import 'package:watch_together/src/session/session_coordinator.dart' show ToastItem;
import 'package:watch_together/src/state/session_state.dart';
import 'package:watch_together/src/update/update_controller.dart';

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

MemberView member(String id, String name, {bool ready = false, bool stale = false}) =>
    MemberView(id: id, name: name, ready: ready, inSet: ready, buffered: 30, stale: stale);

void main() {
  final session = SessionState.instance;
  final coord = session.coordinator;

  void online(List<MemberView> members, {bool media = true}) {
    coord.serverState.value = StateBroadcast(
      eventId: 1,
      transport: 'held',
      position: 0,
      serverTime: DateTime.now().toUtc(),
      mediaId: media ? 1 : 0,
      media: media ? {'name': 'Movie.mkv', 'size': 1, 'duration': 0} : null,
      members: members,
    );
    session.route.value = AppRoute.session;
  }

  setUp(() {
    FakeVideo.created = 0;
    session.recents.value = const [];
  });

  tearDown(() {
    session.route.value = AppRoute.home;
    coord.serverState.value = null;
    coord.playback.alive.value = false;
    coord.toasts.value = [];
  });

  Future<void> pumpShell(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: AppShell(
        updates: UpdateController(currentVersion: '0.0.0-dev'),
        autoUpdateCheck: false,
        windowControls: false,
        videoBuilder: (context, controls) => const FakeVideo(),
      ),
    ));
    await tester.pumpAndSettle();
  }

  final party = [
    member('a', 'Alex', ready: true),
    member('b', 'Bob'),
    member('c', 'Cleo', ready: true),
    member('d', 'Dan'),
    member('e', 'Eve', stale: true),
    member('f', 'Finn'),
  ];

  group('party strip', () {
    testWidgets('offline: Join and Host, no party', (tester) async {
      await pumpShell(tester, const Size(1280, 800));
      expect(find.byKey(const ValueKey('strip-join')), findsOneWidget);
      expect(find.byKey(const ValueKey('strip-host')), findsOneWidget);
      expect(find.text('Offline'), findsOneWidget);
      expect(find.byKey(const ValueKey('party-avatars')), findsNothing);
      expect(find.byKey(const ValueKey('strip-leave')), findsNothing);
      expect(tester.getSize(find.byType(PartyStrip)).height, partyStripHeight);
    });

    testWidgets('online: avatars, server and readiness, chat, Leave', (tester) async {
      await pumpShell(tester, const Size(1280, 800));
      online(party, media: false);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('strip-join')), findsNothing);
      expect(find.byKey(const ValueKey('strip-leave')), findsOneWidget);
      expect(find.byKey(const ValueKey('strip-chat')), findsOneWidget);
      expect(find.text('ready 2/6'), findsOneWidget);
      final stack = find.byKey(const ValueKey('party-avatars'));
      // Five shown, the sixth as "+1"; ready ones first.
      expect(find.descendant(of: stack, matching: find.byType(StatusAvatar)), findsNWidgets(5));
      expect(find.descendant(of: stack, matching: find.text('+1')), findsOneWidget);
      final alex = tester.getTopLeft(find.descendant(of: stack, matching: find.byTooltip('Alex')));
      final bob = tester.getTopLeft(find.descendant(of: stack, matching: find.byTooltip('Bob')));
      expect(alex.dx, lessThan(bob.dx));
      // Leave asks first.
      await tester.tap(find.byKey(const ValueKey('strip-leave')));
      await tester.pumpAndSettle();
      expect(find.text('Leave server?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(session.route.value, AppRoute.session);
    });

    testWidgets('solo: just you, Invite friends opens the host card, Stop asks nothing', (tester) async {
      await pumpShell(tester, const Size(1280, 800));
      session.solo.value = true;
      addTearDown(() => session.solo.value = false);
      online([member('me', 'Me')], media: false);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('solo-chip')), findsOneWidget);
      expect(find.byKey(const ValueKey('party-avatars')), findsNothing);
      expect(find.byKey(const ValueKey('strip-chat')), findsNothing);
      expect(find.byKey(const ValueKey('welcome-band')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('strip-invite')));
      await tester.pumpAndSettle();
      expect(find.text('Invite friends'), findsWidgets);
      expect(find.text('Start hosting'), findsOneWidget);
      await tester.tapAt(const Offset(5, 790));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('strip-leave')));
      await tester.pumpAndSettle();
      expect(find.text('Leave server?'), findsNothing);
      expect(session.route.value, AppRoute.home);
      expect(session.solo.value, isFalse);
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

    testWidgets('tabs: the underline moves to the selected one', (tester) async {
      await pumpShell(tester, const Size(1280, 800));
      double underline(String tab) => tester
          .getSize(find.descendant(of: find.byKey(ValueKey('tab-$tab')), matching: find.byType(AnimatedContainer)))
          .width;
      expect(underline('library'), 22);
      expect(underline('settings'), 0);
      await tester.tap(find.byKey(const ValueKey('tab-settings')));
      await tester.pumpAndSettle();
      expect(underline('library'), 0);
      expect(underline('settings'), 22);
    });
  });

  group('popovers', () {
    testWidgets('members card opens from the avatars and closes outside', (tester) async {
      await pumpShell(tester, const Size(1280, 800));
      online(party, media: false);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('avatar-stack')));
      await tester.pumpAndSettle();
      final card = find.byKey(const ValueKey('members-card'));
      expect(card, findsOneWidget);
      for (final m in party) {
        expect(find.descendant(of: card, matching: find.text(m.name)), findsOneWidget);
      }
      expect(find.descendant(of: card, matching: find.text('reconnecting…')), findsOneWidget);
      // Someone else: nudge or sit them out (no kicking).
      await tester.tap(find.descendant(of: find.byKey(const ValueKey('member-b')), matching: find.byTooltip('More')));
      await tester.pumpAndSettle();
      expect(find.text('Nudge'), findsOneWidget);
      expect(find.text('Sit out'), findsOneWidget);
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
      expect(find.text('offline'), findsOneWidget);
      await tester.tap(find.text('About'));
      await tester.pumpAndSettle();
      expect(find.byType(ProfileCard), findsNothing);
      expect(find.text('Dev build — update checks are off'), findsOneWidget);
    });

    testWidgets('showPopover fades and scales in, Esc closes it', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => showPopover<void>(context, at: Alignment.topRight, child: const Text('card')),
              child: const Text('open'),
            ),
          ),
        ),
      ));
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
    expect(find.text('Open in Link'), findsOneWidget); // offline
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
    p.push = ({String? name, String? avatar}) => pushed.add(name);
    addTearDown(() => p.push = before);
    session.lastForm.name = 'Old';
    p.name.value = 'Old';
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: Center(child: ProfileCard(onOpenSettings: (_) {}))),
    ));
    await tester.enterText(find.byKey(const ValueKey('profile-name')), 'Neo');
    await tester.pump();
    expect(p.name.value, 'Neo');
    expect(session.lastForm.name, 'Neo');
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
    session.route.value = AppRoute.home;
    await tester.pumpAndSettle();
    expect(videos, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('status pill: who is not ready, with the ready count', (tester) async {
    coord.playback.alive.value = true;
    await pumpShell(tester, const Size(1280, 800));
    online([member('a', 'Alex', ready: true), member('b', 'Bob'), member('c', 'Cleo')]);
    await tester.pumpAndSettle();
    expect(find.text('Waiting for Bob and Cleo'), findsOneWidget);
    expect(find.text('1/3 ready'), findsOneWidget);
  });

  test('toasts: feed toasts carry the actor, the rest are the app\'s', () {
    AvatarInfo who(String n) => AvatarInfo(name: n, color: Colors.teal);
    final at = DateTime.now();
    // The actor is exact: "Bob" is not mistaken for "Bob Jr".
    final chat = shellToastFor(ToastItem(id: 1, text: 'Bob Jr: hi there', at: at, actor: 'Bob Jr'), who);
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
  });

  testWidgets('toasts slide in with an avatar and leave after their time', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: PartyToasts(life: Duration(seconds: 1)))));
    coord.toasts.value = [ToastItem(id: 1, text: 'Shaders off', at: DateTime.now())];
    await tester.pump();
    await tester.pump();
    expect(find.text('Shaders off'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.text('Shaders off'), findsNothing);
  });

  testWidgets('status avatar fills its box at any size', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Center(
        child: StatusAvatar(info: AvatarInfo(name: 'Zed', color: Colors.teal, ready: true), size: 88),
      ),
    ));
    final circle = tester.getSize(find.byType(CircleAvatar));
    // Ring and gap (2 x 4 px each side at this size) inside the 88 px box.
    expect(circle.width, 88 - 4 * 4);
    expect(find.text('Z'), findsOneWidget);
  });
}
