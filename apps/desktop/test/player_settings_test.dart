import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_relay_core/core.dart';
import 'package:watch_together/src/controls/controls_probe.dart';
import 'package:watch_together/src/controls/player_settings.dart';
import 'package:watch_together/src/controls/uosc/controls.dart';
import 'package:watch_together/src/jellyfin/track_prefs.dart';
import 'package:watch_together/src/schedule/animeflow.dart';
import 'package:watch_together/src/shaders/shader_presets.dart';
import 'package:watch_together/src/shell/avatar.dart';
import 'package:watch_together/src/shell/party_strip.dart';
import 'package:watch_together/src/shell/settings_tab.dart';
import 'package:watch_together/src/state/session_state.dart';
import 'package:watch_together/src/state/settings.dart';
import 'package:watch_together/src/update/update_controller.dart';

// The player's ⚙ card (both designs, never a media_kit `Video`), the
// Settings pages, the host flag in the party UI and invite addresses.

Widget app(Widget child) => MaterialApp(theme: ThemeData.dark(), home: Scaffold(body: child));

void bigWindow(WidgetTester tester, [Size size = const Size(1280, 1100)]) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> pick(WidgetTester tester, String key, String item) async {
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle();
  await tester.tap(find.text(item).last);
  await tester.pumpAndSettle();
}

void main() {
  final s = AppSettings.instance;
  final coord = SessionState.instance.coordinator;

  tearDown(() {
    s.mpvControls.value = false;
    s.progressLine.value = true;
    s.shaderPreset.value = ShaderPreset.off;
    s.shaderQuality.value = ShaderQuality.hq;
    s.hwdecMode.value = HwdecMode.auto;
    coord.playback.tracks.value = const [];
    coord.serverState.value = null;
    coord.hostFile = null;
    SessionState.instance.route.value = AppRoute.home;
    SessionState.instance.recents.value = const [];
  });

  group('⚙ player settings', () {
    testWidgets('standard controls: the gear opens every player setting, changes apply live', (tester) async {
      bigWindow(tester);
      coord.playback.tracks.value = const [
        MpvTrack(id: 1, type: JellyfinStreamType.audio, language: 'jpn', codec: 'eac3', channels: 2, selected: true),
        MpvTrack(id: 1, type: JellyfinStreamType.subtitle, language: 'eng', codec: 'ass', title: 'Full'),
      ];
      await tester.pumpWidget(app(const Align(alignment: Alignment.bottomRight, child: PlayerSettingsButton())));
      await tester.tap(find.byKey(const ValueKey('player-settings')));
      await tester.pumpAndSettle();
      final card = find.byKey(const ValueKey('player-settings-card'));
      expect(card, findsOneWidget);
      for (final label in [
        'Player design',
        'Progress line when hidden',
        'Upscaling shader',
        'Hardware decoding',
        'Subtitles',
        'Audio',
      ]) {
        expect(find.descendant(of: card, matching: find.text(label)), findsOneWidget, reason: label);
      }
      // Subtitles off (none selected), audio on the selected track.
      expect(find.descendant(of: find.byKey(const ValueKey('subtitle-track')), matching: find.text('Off')),
          findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('audio-track')), matching: find.textContaining('Japanese')),
          findsOneWidget);

      await pick(tester, 'player-design', 'uosc');
      expect(s.mpvControls.value, isTrue);
      await tester.tap(find.byKey(const ValueKey('progress-line')));
      await tester.pump();
      expect(s.progressLine.value, isFalse);
      await pick(tester, 'shader-preset', 'Mode B');
      expect(s.shaderPreset.value, ShaderPreset.b);
      await pick(tester, 'shader-quality', 'Fast');
      expect(s.shaderQuality.value, ShaderQuality.fast);
      await pick(tester, 'hwdec', 'Off');
      expect(s.hwdec.value, 'no');
      // Esc closes it.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(card, findsNothing);
    });

    testWidgets('uosc controls: the gear opens the card and keeps the controls up', (tester) async {
      bigWindow(tester);
      s.mpvControls.value = true;
      await tester.pumpWidget(app(UoscControls(
        hideAfter: const Duration(seconds: 1),
        timeline: (context, expanded) => const SizedBox(height: 30),
        right: const [UoscPlayerSettingsButton()],
      )));
      final controls = tester.state<UoscControlsState>(find.byType(UoscControls));
      await tester.tap(find.byKey(const ValueKey('uosc-player-settings')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('player-settings-card')), findsOneWidget);
      expect(find.text('uosc'), findsOneWidget, reason: 'the current design');
      await tester.pump(const Duration(seconds: 3));
      expect(controls.visible, isTrue, reason: 'held while the card is open');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 2));
      expect(controls.visible, isFalse);
    });

    testWidgets('uosc: hidden controls keep the line unless the setting is off', (tester) async {
      await tester.pumpWidget(app(UoscControls(
        hideAfter: const Duration(milliseconds: 100),
        timeline: (context, expanded) => const SizedBox(height: 2),
      )));
      double opacity() =>
          tester.widget<AnimatedOpacity>(find.byKey(const ValueKey('uosc-timeline-wrap'))).opacity;
      await tester.pump(const Duration(milliseconds: 200));
      expect(opacity(), 1, reason: 'hidden, line on');
      s.setProgressLine(false);
      await tester.pump();
      expect(opacity(), 0, reason: 'hidden, line off');
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(400, 300));
      addTearDown(mouse.removePointer);
      await mouse.moveTo(const Offset(410, 300));
      await tester.pump();
      expect(opacity(), 1, reason: 'controls up: the full timeline');
      await tester.pump(const Duration(milliseconds: 200));
    });
  });

  testWidgets('standard controls: the probe follows media_kit\'s show / hide rule', (tester) async {
    final shown = ValueNotifier(false);
    addTearDown(shown.dispose);
    await tester.pumpWidget(app(ControlsHoverProbe(
      shown: shown,
      hideAfter: const Duration(seconds: 3),
      child: const SizedBox.expand(),
    )));
    await tester.pump();
    expect(shown.value, isTrue, reason: 'up on mount');
    await tester.pump(const Duration(seconds: 3));
    expect(shown.value, isFalse, reason: 'down 3 s later');
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(400, 300));
    addTearDown(mouse.removePointer);
    await mouse.moveTo(const Offset(420, 300));
    await tester.pump();
    expect(shown.value, isTrue, reason: 'mouse movement');
    await tester.pump(const Duration(seconds: 3));
    expect(shown.value, isFalse);
  });

  group('Settings pages', () {
    Future<void> pumpSettings(WidgetTester tester, SettingsSection section,
        {Future<AnimeFlowMe> Function()? me, Size size = const Size(1280, 1400)}) async {
      bigWindow(tester, size);
      await tester.pumpWidget(app(SettingsTab(
        section: section,
        onSection: (_) {},
        updates: UpdateController(currentVersion: '0.0.0-dev'),
        animeFlowMe: me ?? () async => throw const AnimeFlowException(401, AnimeFlowErrorCode.missingToken, 'x'),
      )));
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

    testWidgets('Player: the same rows as the ⚙, plus a pointer to it', (tester) async {
      await pumpSettings(tester, SettingsSection.player);
      expect(find.textContaining("also in the player's ⚙"), findsOneWidget);
      for (final key in ['player-design', 'progress-line', 'shader-preset', 'hwdec']) {
        expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
      }
      expect(find.byKey(const ValueKey('audio-track')), findsNothing, reason: 'tracks only in the player');
      expect(find.text('Standard'), findsOneWidget);
      await pick(tester, 'player-design', 'uosc');
      expect(s.mpvControls.value, isTrue);
    });

    testWidgets('Party & network: host defaults and recent servers with remove', (tester) async {
      SessionState.instance.recents.value = const [
        RecentServer(hosted: false, host: 'vps.example', port: '8080', secret: 'pw'),
        RecentServer(hosted: true, host: '127.0.0.1', port: '9000'),
      ];
      await pumpSettings(tester, SettingsSection.network);
      expect(find.text('Default port'), findsOneWidget);
      expect(find.text('vps.example:8080'), findsOneWidget);
      expect(find.text('Hosted on port 9000'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('host-port')), '70000');
      await tester.pump();
      expect(find.text('A number from 1 to 65535'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('host-port')), '9100');
      await tester.pump();
      expect(SessionState.instance.lastForm.hostPort, '9100');
      await tester.tap(find.descendant(
          of: find.byKey(const ValueKey('recent-vps.example:8080')), matching: find.byTooltip('Remove')));
      await tester.pumpAndSettle();
      expect(find.text('vps.example:8080'), findsNothing);
      SessionState.instance.lastForm.hostPort = '8080';
    });

    testWidgets('Integrations: AnimeFlow says who you are connected as, or why not', (tester) async {
      await pumpSettings(tester, SettingsSection.integrations,
          me: () async => const AnimeFlowMe(
              userId: 'u1', name: 'foxyz', scopes: {AnimeFlowScope.view, AnimeFlowScope.request}));
      expect(find.text('connected as foxyz · can view, request'), findsOneWidget);
      // A fresh tree: the card keeps its first answer otherwise.
      await tester.pumpWidget(const SizedBox());
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
      expect(find.text('Default port'), findsOneWidget);
    });
  });

  group('party', () {
    test('invite addresses: LAN IPv4 with the port, private first, no loopback', () {
      final list = inviteAddresses([
        InternetAddress('127.0.0.1'),
        InternetAddress('100.64.1.2'),
        InternetAddress('192.168.1.20'),
        InternetAddress('169.254.3.4'),
        InternetAddress('::1'),
        InternetAddress('10.0.0.5'),
        InternetAddress('192.168.1.20'),
      ], '8080');
      expect(list, ['192.168.1.20:8080', '10.0.0.5:8080', '100.64.1.2:8080']);
      expect(inviteAddresses(const [], '8080'), isEmpty);
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
      SessionState.instance.route.value = AppRoute.session;
    }

    testWidgets('the state\'s host flag crowns that member for everyone', (tester) async {
      online(const [
        MemberView(id: 'm1', name: 'Hana', ready: true, inSet: true, buffered: 30, stale: false, host: true),
        MemberView(id: 'm2', name: 'Bob', ready: false, inSet: false, buffered: 0, stale: false),
      ]);
      final avatars = {for (final a in partyAvatars(coord)) a.name: a};
      expect(avatars['Hana']!.host, isTrue);
      expect(avatars['Bob']!.host, isFalse);
      bigWindow(tester);
      await tester.pumpWidget(app(const Center(child: MembersCard())));
      await tester.pumpAndSettle();
      expect(find.descendant(of: find.byKey(const ValueKey('member-m1')), matching: find.text('host')),
          findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('member-m2')), matching: find.text('host')),
          findsNothing);
      // The host cannot be kicked: no Kick in its menu.
      await tester.tap(find.descendant(of: find.byKey(const ValueKey('member-m1')), matching: find.byTooltip('More')));
      await tester.pumpAndSettle();
      expect(find.text('Kick'), findsNothing);
    });

    testWidgets('hosting: Copy invite address lists this machine\'s addresses', (tester) async {
      online(const [MemberView(id: 'm1', name: 'Me', ready: false, inSet: false, buffered: 0, stale: false)]);
      coord.hostFile = (_) async => null;
      SessionState.instance.lastForm.hostPort = '8080';
      bigWindow(tester);
      await tester.pumpWidget(app(Center(
        child: MembersCard(lanAddresses: (port) async => ['192.168.1.20:$port', '10.0.0.5:$port']),
      )));
      await tester.pumpAndSettle();
      expect(find.text('Copy invite address'), findsOneWidget);
      expect(find.text('192.168.1.20:8080'), findsOneWidget);
      expect(find.text('10.0.0.5:8080'), findsOneWidget);
      expect(find.textContaining('port 8080 forwarded'), findsOneWidget);
      expect(find.textContaining('VPS'), findsOneWidget);
    });
  });
}
