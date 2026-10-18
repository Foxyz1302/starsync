import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:signals/signals_flutter.dart' show signal;
import 'package:sync_relay_core/core.dart';
import 'package:starsync/src/controls/model/controls_prefs.dart';
import 'package:starsync/src/controls/player_panel.dart';
import 'package:starsync/src/danmaku/danmaku.dart' show DanmakuStyle;
import 'package:starsync/src/jellyfin/track_prefs.dart';
import 'package:starsync/src/schedule/animeflow.dart';
import 'package:starsync/src/shaders/shader_presets.dart';
import 'package:starsync/src/shell/avatar.dart';
import 'package:starsync/src/shell/party_strip.dart';
import 'package:starsync/src/shell/settings_tab.dart';
import 'package:starsync/src/state/settings.dart';
import 'package:starsync/src/update/update_controller.dart';

import 'package:starsync/src/session/invite.dart';
import 'package:starsync/src/session/navigation.dart' show Place;
import 'package:starsync/src/state/connect_prefs.dart' show RecentServer;

import 'test_graph.dart';

/// This file's composition root (see test_graph.dart).
final _graph = testGraph();

// The player settings card (both skins, never a media_kit `Video`), the
// Settings pages, the host flag in the party UI and invite addresses.

Widget app(Widget child) => MaterialApp(theme: ThemeData.dark(), home: Scaffold(body: child));

void bigWindow(WidgetTester tester, [Size size = const Size(1280, 1100)]) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> pick(WidgetTester tester, String key, String item) async {
  await tester.ensureVisible(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle();
  await tester.tap(find.text(item).last);
  await tester.pumpAndSettle();
}

void main() {
  final s = AppSettings.instance;
  final coord = _graph.coordinator;

  tearDown(() {
    s.controlsSkin.value = ControlsSkin.standard;
    s.timeDisplay.value = TimeDisplay.elapsed;
    s.controlsSize.value = ControlsSize.normal;
    s.controlsHideSecs.value = defaultControlsHideSecs;
    s.hiddenControls.value = const {};
    s.progressLine.value = true;
    s.shaderPreset.value = ShaderPreset.off;
    s.shaderQuality.value = ShaderQuality.hq;
    s.hwdecMode.value = HwdecMode.auto;
    s.liftSubtitles.value = false;
    s.notifyStyle.value = NotifyStyle.toasts;
    coord.playback.tracks.value = const [];
    coord.serverState.value = null;
    coord.hostFile = null;
    _graph.navigation.place.value = Place.none;
    _graph.forms.recents.value = const [];
  });

  group('player panel', () {
    testWidgets('tracks, subtitles, picture, sound, notifications and controls; all live', (tester) async {
      bigWindow(tester);
      coord.playback.tracks.value = const [
        MpvTrack(id: 1, type: JellyfinStreamType.audio, language: 'jpn', codec: 'eac3', channels: 2, selected: true),
        MpvTrack(id: 1, type: JellyfinStreamType.subtitle, language: 'eng', codec: 'ass', title: 'Full'),
      ];
      var volume = 80.0;
      var closed = 0;
      final vol = signal(volume);
      await tester.pumpWidget(scoped(
          _graph,
          app(Align(
            alignment: Alignment.topRight,
            child: SizedBox(
              height: 1000,
              child: PlayerPanel(
                onClose: () => closed++,
                volume: vol,
                onVolume: (v) => vol.value = volume = v,
              ),
            ),
          ))));
      await tester.pumpAndSettle();
      final panel = find.byKey(const ValueKey('player-panel'));
      expect(panel, findsOneWidget);
      for (final label in ['Subtitles', 'Audio', 'Size', 'Upscaling', 'Hardware decoding', 'Volume']) {
        expect(find.descendant(of: panel, matching: find.text(label)), findsWidgets, reason: label);
      }
      // Subtitles off (none selected), audio on the selected track.
      expect(find.descendant(of: find.byKey(const ValueKey('panel-subtitles')), matching: find.text('Off')),
          findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('panel-audio')), matching: find.textContaining('Japanese')),
          findsOneWidget);
      await pick(tester, 'panel-shader', 'Mode B');
      expect(s.shaderPreset.value, ShaderPreset.b);
      await pick(tester, 'panel-hwdec', 'Off');
      expect(s.hwdec.value, 'no');
      await tester.tap(find.descendant(of: find.byKey(const ValueKey('panel-lift')), matching: find.byType(Switch)));
      await tester.pump();
      expect(s.liftSubtitles.value, isTrue);
      await tester.drag(find.descendant(of: find.byKey(const ValueKey('panel-volume')), matching: find.byType(Slider)),
          const Offset(-60, 0));
      expect(volume, lessThan(80));
      // Folded sections open with a click: notifications, then danmaku's knobs.
      expect(find.byKey(const ValueKey('notify-style')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('panel-section-Notifications')));
      await tester.pumpAndSettle();
      await pick(tester, 'notify-style', 'Danmaku');
      expect(s.notifyStyle.value, NotifyStyle.danmaku);
      expect(find.byKey(const ValueKey('danmaku-weight')), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('panel-section-Controls')));
      await tester.tap(find.byKey(const ValueKey('panel-section-Controls')));
      await tester.pumpAndSettle();
      await pick(tester, 'panel-design', 'Minimal');
      expect(s.controlsSkin.value, ControlsSkin.minimal);
      await tester.ensureVisible(find.byKey(const ValueKey('player-panel-close')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('player-panel-close')));
      expect(closed, 1);
    });
  });

  group('Settings pages', () {
    Future<void> pumpSettings(WidgetTester tester, SettingsSection section,
        {Future<AnimeFlowMe> Function()? me, Size size = const Size(1280, 1400)}) async {
      bigWindow(tester, size);
      await tester.pumpWidget(scoped(_graph, app(SettingsTab(
        section: section,
        onSection: (_) {},
        updates: UpdateController(currentVersion: '0.0.0-dev'),
        animeFlowMe: me ?? () async => throw const AnimeFlowException(401, AnimeFlowErrorCode.missingToken, 'x'),
      ))));
      await tester.pumpAndSettle();
    }

    testWidgets('every section renders as cards, with icons in the nav', (tester) async {
      for (final section in SettingsSection.values) {
        await pumpSettings(tester, section);
        expect(find.text(section.label), findsWidgets, reason: section.name);
        expect(tester.takeException(), isNull, reason: section.name);
      }
      expect(SettingsSection.values.map((s) => s.label), [
        'Profile',
        'Party & network',
        'Player',
        'Jellyfin & integrations',
        'Notifications & sounds',
        'Updates',
        'Keyboard shortcuts',
        'About',
      ]);
      expect(find.byIcon(Icons.hub_outlined), findsOneWidget);
    });

    testWidgets('Notifications: Toasts / Danmaku, a preview strip and every knob of the look', (tester) async {
      addTearDown(() => s.danmakuStyle.value = const DanmakuStyle());
      await pumpSettings(tester, SettingsSection.notifications, size: const Size(1280, 2600));
      final card = find.byKey(const ValueKey('danmaku-settings'));
      expect(card, findsOneWidget);
      expect(find.byKey(const ValueKey('danmaku-preview-strip')), findsOneWidget);
      expect(s.notifyStyle.value, NotifyStyle.toasts, reason: 'toasts by default');
      await pick(tester, 'notify-style', 'Danmaku');
      expect(s.notifyStyle.value, NotifyStyle.danmaku);
      for (final k in ['cross', 'cap', 'band', 'opacity', 'size', 'weight', 'outline', 'avatars', 'own']) {
        expect(find.byKey(ValueKey('danmaku-$k')), findsOneWidget, reason: k);
      }
      // Boldness: one step right of Semibold is Bold.
      final weight = find.byKey(const ValueKey('danmaku-weight'));
      final box = tester.getRect(weight);
      await tester.tapAt(Offset(box.left + box.width * 0.6, box.center.dy));
      await tester.pump();
      expect(s.danmakuStyle.value.weight, 700);
      expect(find.text('Bold'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('danmaku-avatars')));
      await tester.pump();
      expect(s.danmakuStyle.value.avatars, isFalse);
      await tester.tap(find.byKey(const ValueKey('danmaku-reset')));
      await tester.pump();
      expect(s.danmakuStyle.value, const DanmakuStyle());
      // The strip rests after a while and plays again on a click.
      await tester.pump(const Duration(seconds: 20));
      expect(find.byKey(const ValueKey('danmaku-preview-play')), findsOneWidget);
      await tester.pumpAndSettle();
    });

    testWidgets('Player: the card\'s rows, a pointer to it, and the controls\' choices', (tester) async {
      await pumpSettings(tester, SettingsSection.player, size: const Size(1280, 2400));
      expect(find.textContaining('also in the player: ⚙ → Player settings'), findsOneWidget);
      for (final key in [
        'player-design',
        'progress-line',
        'shader-preset',
        'hwdec',
        'sub-scale',
        'lift-subtitles',
        'time-display',
        'controls-size',
        'controls-hide',
        for (final c in OptionalControl.values) 'bar-${c.name}',
      ]) {
        expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
      }
      expect(find.byKey(const ValueKey('audio-track')), findsNothing, reason: 'tracks only in the player');
      expect(find.text('Standard'), findsOneWidget);
      await pick(tester, 'player-design', 'Minimal');
      expect(s.controlsSkin.value, ControlsSkin.minimal);
      await pick(tester, 'time-display', 'Remaining');
      expect(s.timeDisplay.value, TimeDisplay.remaining);
      await pick(tester, 'controls-size', 'Large');
      expect(s.controlsSize.value, ControlsSize.large);
      await pick(tester, 'controls-hide', '5 s');
      expect(s.controlsHideSecs.value, 5);
      await tester.tap(find.byKey(const ValueKey('bar-chat')));
      await tester.pump();
      expect(s.hiddenControls.value, {OptionalControl.chat});
      await tester.tap(find.byKey(const ValueKey('bar-chat')));
      await tester.pump();
      expect(s.hiddenControls.value, isEmpty);
    });

    testWidgets('Party & network: your server\'s port and password, recent servers with remove', (tester) async {
      _graph.forms.recents.value = const [
        RecentServer(host: 'vps.example', port: '8080', secret: 'pw'),
        RecentServer(host: 'friend.example', port: '9000'),
      ];
      await pumpSettings(tester, SettingsSection.network);
      expect(find.text('Your server'), findsOneWidget);
      expect(find.text('Port'), findsOneWidget);
      expect(find.text('vps.example:8080'), findsOneWidget);
      expect(find.text('friend.example:9000'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('host-port')), '70000');
      await tester.pump();
      expect(find.text('A number from 1 to 65535'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('host-port')), '9100');
      await tester.pump();
      expect(_graph.forms.form.hostPort, '9100');
      await tester.tap(find.descendant(
          of: find.byKey(const ValueKey('recent-vps.example:8080')), matching: find.byTooltip('Remove')));
      await tester.pumpAndSettle();
      expect(find.text('vps.example:8080'), findsNothing);
      _graph.forms.form.hostPort = '8080';
    });

    testWidgets('Integrations: AnimeFlow says who you are connected as, or why not', (tester) async {
      await pumpSettings(tester, SettingsSection.integrations,
          me: () async => const AnimeFlowMe(
              userId: 'u1', name: 'foxyz', scopes: {AnimeFlowScope.view, AnimeFlowScope.request}));
      expect(find.text('connected as foxyz · can view, request'), findsOneWidget);
      // A fresh tree: the card keeps its first answer otherwise.
      await tester.pumpWidget(scoped(_graph, const SizedBox()));
      await pumpSettings(tester, SettingsSection.integrations,
          me: () async => throw const AnimeFlowException(
              401, AnimeFlowErrorCode.missingToken, 'No linked Jellyfin account for AnimeFlow'));
      expect(find.text('No linked Jellyfin account for AnimeFlow'), findsOneWidget);
    });

    testWidgets('narrow: icon chips instead of the side nav', (tester) async {
      await pumpSettings(tester, SettingsSection.network, size: const Size(700, 1000));
      expect(find.byType(ChoiceChip), findsWidgets);
      expect(find.byType(ListTile).evaluate().where((e) => e.widget.key == const ValueKey('settings-profile')),
          isEmpty, reason: 'no side nav');
      final chip = tester.widget<ChoiceChip>(find.byKey(const ValueKey('settings-network')));
      expect(chip.selected, isTrue);
      expect((chip.avatar! as Icon).icon, Icons.hub_outlined);
      expect(find.text('Port'), findsOneWidget);
    });
  });

  group('party', () {
    test('invite addresses: home network first; no proxy fake-IP, link-local, loopback or container bridge', () {
      ({String name, InternetAddress address}) at(String name, String ip) => (name: name, address: InternetAddress(ip));
      final list = inviteAddresses([
        at('lo', '127.0.0.1'),
        at('Meta', '198.18.0.1'), // a TUN proxy's fake-IP range (198.18.0.0/15)
        at('utun', '198.19.255.2'),
        at('tailscale0', '100.64.1.2'),
        at('docker0', '172.17.0.1'),
        at('br-3f2a', '172.18.0.1'),
        at('virbr0', '192.168.122.1'),
        at('eth1', '10.0.0.5'),
        at('wlan0', '169.254.3.4'),
        at('eth0', '192.168.1.20'),
        at('eth0', '192.168.1.20'),
        at('eth0', '::1'),
        at('wan', '203.0.113.7'),
      ]);
      expect(list, ['192.168.1.20', '10.0.0.5', '100.64.1.2', '203.0.113.7']);
      expect(inviteAddresses(const []), isEmpty);
      expect(isFakeIp(InternetAddress('198.19.1.1').rawAddress), isTrue);
      expect(isFakeIp(InternetAddress('198.20.1.1').rawAddress), isFalse);
    });

    test('an invite: the address, whether to ask for a password, the version; pasted back', () {
      const invite = Invite(host: '192.168.1.20', port: 8080, password: true, version: '1.3.0');
      expect(invite.address, '192.168.1.20:8080');
      expect(invite.text,
          'Join me on Starsync: starsync://192.168.1.20:8080 (ask me for the password) · Starsync 1.3.0');
      expect(invite.fp, isNull, reason: 'reserved for pinned certificates');
      expect(addressIn(invite.text), (host: '192.168.1.20', port: '8080'));
      expect(addressIn('vps.example.com:9000'), (host: 'vps.example.com', port: '9000'));
      expect(addressIn('[fe80::1]:8080'), (host: 'fe80::1', port: '8080'));
      expect(addressIn('just a host'), isNull);
    });

    void online(List<MemberView> members) {
      coord.serverState.value = StateBroadcast(
        eventId: 1,
        transport: 'held',
        position: 0,
        serverTime: DateTime.now().toUtc(),
        mediaId: 0,
        members: members,
      );
      _graph.navigation.place.value = Place.friend;
    }

    testWidgets('the state\'s host flag crowns that member for everyone', (tester) async {
      online(const [
        MemberView(id: 'm1', name: 'Hana', ready: true, inSet: true, buffered: 30, host: true),
        MemberView(id: 'm2', name: 'Bob', ready: false, inSet: false, buffered: 0),
      ]);
      final avatars = {for (final a in partyAvatars(coord)) a.name: a};
      expect(avatars['Hana']!.host, isTrue);
      expect(avatars['Bob']!.host, isFalse);
      bigWindow(tester);
      await tester.pumpWidget(scoped(_graph, app(const Center(child: MembersCard()))));
      await tester.pumpAndSettle();
      expect(find.descendant(of: find.byKey(const ValueKey('member-m1')), matching: find.text('host')),
          findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('member-m2')), matching: find.text('host')),
          findsNothing);
      // The host can be sat out like anyone.
      await tester.tap(find.descendant(of: find.byKey(const ValueKey('member-m1')), matching: find.byTooltip('More')));
      await tester.pumpAndSettle();
      expect(find.text('Sit out'), findsOneWidget);
    });

    testWidgets('your server, not shared: only you, Invite; shared: the invite and Stop sharing', (tester) async {
      online(const [MemberView(id: 'm1', name: 'Me', ready: false, inSet: false, buffered: 0)]);
      _graph.navigation.place.value = Place.yours;
      final yours = _graph.yourServer;
      yours.port.value = 40000; // as if it runs
      addTearDown(() {
        yours.port.value = null;
        yours.shared.value = null;
      });
      bigWindow(tester);
      await tester.pumpWidget(scoped(_graph, app(const Center(child: MembersCard()))));
      await tester.pumpAndSettle();
      expect(find.text('Your server'), findsOneWidget);
      expect(find.textContaining('Only you can reach it'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Invite'), findsOneWidget);
      expect(find.byKey(const ValueKey('stop-sharing')), findsNothing);

      yours.shared.value = const Invite(host: '192.168.1.20', port: 8080, version: '1.3.0');
      yours.reach.value = const InviteReach(local: ['192.168.1.20'], looking: true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('192.168.1.20:8080'), findsOneWidget);
      expect(find.text('Looking up your internet address…'), findsOneWidget);
      expect(find.text('Copy invite link'), findsOneWidget);
      expect(find.byKey(const ValueKey('stop-sharing')), findsOneWidget);
      expect(find.textContaining('friends on your network'), findsOneWidget);
      // No password set: nothing to tick.
      expect(find.byKey(const ValueKey('invite-with-password')), findsNothing);

      // Behind a router: the internet address first, with the forwarding
      // it needs; the home address stays a choice.
      yours.shared.value = const Invite(host: '203.0.113.7', port: 8080, version: '1.3.0');
      yours.reach.value = const InviteReach(public: '203.0.113.7', local: ['192.168.1.20']);
      await tester.pumpAndSettle();
      expect(find.text('203.0.113.7:8080'), findsOneWidget);
      expect(find.text('192.168.1.20:8080'), findsOneWidget);
      expect(find.textContaining('port 8080 is forwarded on your router to this computer (192.168.1.20)'),
          findsOneWidget);
      await tester.tap(find.text('192.168.1.20:8080'));
      await tester.pumpAndSettle();
      expect(find.textContaining('friends on your network'), findsOneWidget);

      // No internet address found: say what friends elsewhere need.
      yours.reach.value = const InviteReach(local: ['192.168.1.20']);
      await tester.pumpAndSettle();
      expect(find.textContaining('VPS'), findsOneWidget);
    });
  });
}
