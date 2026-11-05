import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemChannels;
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_relay_core/core.dart';
import 'package:starsync/src/controls/model/controls_prefs.dart';
import 'package:starsync/src/controls/player_panel.dart';
import 'package:starsync/src/controls/volume.dart' show VolumeBar;
import 'package:starsync/src/danmaku/danmaku.dart' show DanmakuStyle;
import 'package:starsync/src/jellyfin/track_prefs.dart';
import 'package:starsync/src/schedule/animeflow.dart';
import 'package:starsync/src/shaders/shader_presets.dart';
import 'package:starsync/src/shell/avatar.dart';
import 'package:starsync/src/shell/party_strip.dart';
import 'package:starsync/src/shell/profile_card.dart' show ProfileColors, ProfilePicture;
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
    testWidgets('Settings\' own widgets, dense: sound first, subtitles & audio, picture, over the video, controls',
        (tester) async {
      bigWindow(tester);
      addTearDown(() {
        s.soundVolume.value = 1;
        s.hwdecCustom.value = '';
        s.playerVolume.value = 100;
        coord.playback.volume.value = 100;
      });
      coord.playback.tracks.value = const [
        MpvTrack(id: 1, type: JellyfinStreamType.audio, language: 'jpn', codec: 'eac3', channels: 2, selected: true),
        MpvTrack(id: 1, type: JellyfinStreamType.subtitle, language: 'eng', codec: 'ass', title: 'Full'),
      ];
      coord.playback.volume.value = 80;
      var closed = 0;
      final opened = <PanelSection>[];
      await tester.pumpWidget(scoped(
          _graph,
          app(Align(
            alignment: Alignment.topRight,
            child: SizedBox(
              height: 1000,
              child: PlayerPanel(onClose: () => closed++, onAllSettings: opened.add),
            ),
          ))));
      await tester.pumpAndSettle();
      final panel = find.byKey(const ValueKey('player-panel'));
      expect(panel, findsOneWidget);
      // The same labels as in Settings.
      for (final label in [
        'Volume',
        'App sounds',
        'Subtitles',
        'Audio',
        'Subtitle size',
        'Subtitles above the controls',
        'Upscaling shader',
      ]) {
        expect(find.descendant(of: panel, matching: find.text(label)), findsOneWidget, reason: label);
      }
      // Sound is the first section: the video's volume, then the app's.
      double top(String key) => tester.getTopLeft(find.byKey(ValueKey(key))).dy;
      expect(top('panel-section-sound'), lessThan(top('panel-section-subtitles')));
      expect(top('video-volume'), lessThan(top('app-sounds')));
      final bar = tester.getRect(find.descendant(of: find.byKey(const ValueKey('video-volume')), matching: find.byType(VolumeBar)));
      await tester.tapAt(Offset(bar.left + 10, bar.center.dy));
      expect(coord.playback.volume.value, lessThan(20), reason: 'the bar runs 0..150 across the row');
      expect(s.playerVolume.value, coord.playback.volume.value, reason: 'kept for the next start');
      await tester.drag(find.byKey(const ValueKey('sound-volume')), const Offset(-60, 0));
      expect(s.soundVolume.value, lessThan(1));
      // "All settings" goes where the section last used lives.
      await tester.tap(find.byKey(const ValueKey('panel-all-settings')));
      expect(opened, [PanelSection.sound]);
      // Subtitles off (none selected), audio on the selected track.
      expect(find.descendant(of: find.byKey(const ValueKey('subtitle-track')), matching: find.text('Off')),
          findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('audio-track')), matching: find.textContaining('Japanese')),
          findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('lift-subtitles')));
      await tester.pump();
      expect(s.liftSubtitles.value, isTrue);
      // The shader: one picker, HQ / Fast under an Anime4K mode.
      expect(find.byKey(const ValueKey('shader-quality')), findsNothing);
      await pick(tester, 'shader-preset', 'Mode B');
      expect(s.shaderPreset.value, ShaderPreset.b);
      await tester.tap(find.text('Fast'));
      await tester.pump();
      expect(s.shaderQuality.value, ShaderQuality.fast);
      // Troubleshooting is folded: sharp video and hardware decoding (with
      // its custom field, as in Settings).
      expect(find.byKey(const ValueKey('hwdec')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('fold-Troubleshooting')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('screen-res-video')), findsOneWidget);
      await pick(tester, 'hwdec', 'Off');
      expect(s.hwdec.value, 'no');
      expect(find.byKey(const ValueKey('hwdec-custom')), findsNothing);
      await pick(tester, 'hwdec', 'Custom');
      await tester.enterText(find.byKey(const ValueKey('hwdec-custom')), 'vaapi');
      expect(s.hwdec.value, 'vaapi');
      await tester.tap(find.byKey(const ValueKey('panel-all-settings')));
      expect(opened.last, PanelSection.picture);
      // Folded sections open with a click: over the video, then the
      // danmaku look's knobs (with Danmaku).
      expect(find.byKey(const ValueKey('notify-style')), findsNothing);
      await tester.ensureVisible(find.byKey(const ValueKey('panel-section-overVideo')));
      await tester.tap(find.byKey(const ValueKey('panel-section-overVideo')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('chat-popups')), findsOneWidget);
      expect(find.byKey(const ValueKey('fold-Danmaku look')), findsNothing, reason: 'toasts');
      await pick(tester, 'notify-style', 'Danmaku');
      expect(s.notifyStyle.value, NotifyStyle.danmaku);
      await tester.tap(find.byKey(const ValueKey('fold-Danmaku look')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('danmaku-weight')), findsOneWidget);
      expect(find.text('Crossing time'), findsOneWidget, reason: 'the same words as in Settings');
      await tester.ensureVisible(find.byKey(const ValueKey('panel-section-controls')));
      await tester.tap(find.byKey(const ValueKey('panel-section-controls')));
      await tester.pumpAndSettle();
      await pick(tester, 'player-design', 'Minimal');
      expect(s.controlsSkin.value, ControlsSkin.minimal);
      expect(find.byKey(const ValueKey('controls-size')), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('player-panel-close')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('player-panel-close')));
      expect(closed, 1);
      expect(tester.takeException(), isNull);
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
        'Player',
        'Party',
        'Notifications & sounds',
        'Library & accounts',
        'Updates',
        'Help & about',
      ]);
      expect(find.byIcon(Icons.hub_outlined), findsOneWidget);
    });

    testWidgets('Notifications: over the video first; the danmaku look with its preview under More', (tester) async {
      addTearDown(() => s.danmakuStyle.value = const DanmakuStyle());
      await pumpSettings(tester, SettingsSection.notifications, size: const Size(1280, 3600));
      final card = find.byKey(const ValueKey('over-the-video'));
      expect(card, findsOneWidget);
      for (final label in ['Notifications', 'Chat pop-ups', 'Joins and leaves too', 'App sounds', 'Sound set']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      expect(find.byKey(const ValueKey('danmaku-preview-strip')), findsNothing, reason: 'folded');
      expect(find.byKey(const ValueKey('sound-play-ready')), findsNothing, reason: 'each sound folded');
      expect(s.notifyStyle.value, NotifyStyle.toasts, reason: 'toasts by default');
      await pick(tester, 'notify-style', 'Danmaku');
      expect(s.notifyStyle.value, NotifyStyle.danmaku);
      await tester.tap(find.descendant(of: card, matching: find.byKey(const ValueKey('fold-More'))));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('danmaku-preview-strip')), findsOneWidget);
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

    testWidgets('Player: sound, subtitles, picture, controls, playback; the rarer rows under More', (tester) async {
      await pumpSettings(tester, SettingsSection.player, size: const Size(1280, 2400));
      expect(find.textContaining('Also in the player: ⚙'), findsOneWidget);
      for (final key in [
        'video-volume',
        'sub-scale',
        'lift-subtitles',
        'shader-preset',
        'player-design',
        'controls-size',
        'progress-line',
        'auto-advance',
      ]) {
        expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
      }
      // Dropped for their defaults: no time display or hide delay rows.
      expect(find.text('Time display'), findsNothing);
      expect(find.text('Hide the controls after'), findsNothing);
      expect(find.byKey(const ValueKey('audio-track')), findsNothing, reason: 'tracks only in the player');
      // Folded: the custom files, sharp video, hardware decoding; the bar's buttons.
      for (final key in ['hwdec', 'screen-res-video', 'add-shaders', 'bar-chat']) {
        expect(find.byKey(ValueKey(key)), findsNothing, reason: '$key folded');
      }
      for (final more in find.byKey(const ValueKey('fold-More')).evaluate().toList()) {
        await tester.tap(find.byWidget(more.widget));
        await tester.pumpAndSettle();
      }
      for (final key in ['hwdec', 'screen-res-video', 'add-shaders', for (final c in OptionalControl.values) 'bar-${c.name}']) {
        expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
      }
      expect(find.text('Standard'), findsOneWidget);
      await pick(tester, 'player-design', 'Minimal');
      expect(s.controlsSkin.value, ControlsSkin.minimal);
      await pick(tester, 'controls-size', 'Large');
      expect(s.controlsSize.value, ControlsSize.large);
      await tester.tap(find.byKey(const ValueKey('bar-chat')));
      await tester.pump();
      expect(s.hiddenControls.value, {OptionalControl.chat});
      await tester.tap(find.byKey(const ValueKey('bar-chat')));
      await tester.pump();
      expect(s.hiddenControls.value, isEmpty);
    });

    testWidgets('Party: you (picture, name, colour) in place, away, your server, recent servers', (tester) async {
      final profile = _graph.profile;
      final name = profile.name.peek();
      addTearDown(() => profile.name.value = name);
      _graph.forms.recents.value = const [
        RecentServer(host: 'vps.example', port: '8080', secret: 'pw'),
        RecentServer(host: 'friend.example', port: '9000'),
      ];
      await pumpSettings(tester, SettingsSection.party, size: const Size(1280, 1800));
      final you = find.byKey(const ValueKey('party-you'));
      expect(find.descendant(of: you, matching: find.byType(ProfilePicture)), findsOneWidget);
      expect(find.descendant(of: you, matching: find.byType(ProfileColors)), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('party-name')), 'Hana');
      expect(profile.name.peek(), 'Hana');
      expect(find.byKey(const ValueKey('auto-sit-out')), findsNothing, reason: 'AFK has no switch');
      // The avatar shape lives under More.
      expect(find.byKey(const ValueKey('avatar-shape')), findsNothing);
      await tester.tap(find.descendant(of: you, matching: find.text('More')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('avatar-shape')), findsOneWidget);
      expect(find.text('Your server'), findsOneWidget);
      expect(find.text('Port'), findsOneWidget);
      expect(find.text('vps.example:8080'), findsOneWidget);
      expect(find.text('friend.example:9000'), findsOneWidget);
      expect(find.text('Unready when the video changes'), findsNothing, reason: 'dropped: ready stays');
      await tester.enterText(find.byKey(const ValueKey('host-port')), '70000');
      await tester.pump();
      expect(find.text('A number from 1 to 65535'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('host-port')), '9100');
      await tester.pump();
      expect(_graph.forms.form.hostPort, '9100');
      await tester.tap(find.descendant(
          of: find.byKey(const ValueKey('recent-vps.example:8080')), matching: find.byTooltip('Forget')));
      await tester.pumpAndSettle();
      expect(find.text('vps.example:8080'), findsNothing);
      _graph.forms.form.hostPort = '8080';
      await tester.pump(const Duration(seconds: 1)); // the name's push
    });

    testWidgets('Library & accounts: AnimeFlow says who you are connected as, or why not; web links', (tester) async {
      await pumpSettings(tester, SettingsSection.library,
          me: () async => const AnimeFlowMe(
              userId: 'u1', name: 'foxyz', scopes: {AnimeFlowScope.view, AnimeFlowScope.request}));
      expect(find.text('connected as foxyz · can view, request'), findsOneWidget);
      expect(find.byKey(const ValueKey('web-links')), findsOneWidget);
      expect(find.text('Hide re-releases in Latest'), findsNothing, reason: 'in the Latest row\'s menu only');
      // A fresh tree: the card keeps its first answer otherwise.
      await tester.pumpWidget(scoped(_graph, const SizedBox()));
      await pumpSettings(tester, SettingsSection.library,
          me: () async => throw const AnimeFlowException(
              401, AnimeFlowErrorCode.missingToken, 'No linked Jellyfin account for AnimeFlow'));
      expect(find.text('No linked Jellyfin account for AnimeFlow'), findsOneWidget);
    });

    testWidgets('Updates: always checked, the channel and the config address under More', (tester) async {
      await pumpSettings(tester, SettingsSection.updates);
      expect(find.text('Check now'), findsOneWidget);
      expect(find.text('Check for updates automatically'), findsNothing, reason: 'always on');
      expect(find.byKey(const ValueKey('update-channel')), findsNothing);
      expect(find.byKey(const ValueKey('config-address')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('fold-More')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('update-channel')), findsOneWidget);
      final s = AppSettings.instance;
      await tester.enterText(find.byKey(const ValueKey('config-address')), 'not a url');
      await tester.pump();
      expect(find.text('Not a web address'), findsOneWidget);
      expect(s.configAddress.value, isNot('not a url'));
      await tester.enterText(find.byKey(const ValueKey('config-address')), 'https://mirror.example/starsync-config.json');
      await tester.pump();
      expect(find.text('Not a web address'), findsNothing);
      expect(s.configAddress.value, 'https://mirror.example/starsync-config.json');
      s.setConfigAddress('');
    });

    testWidgets('Help & about: diagnostics first, every key, about', (tester) async {
      await pumpSettings(tester, SettingsSection.help, size: const Size(1280, 2400));
      double top(Finder f) => tester.getTopLeft(f).dy;
      expect(top(find.byKey(const ValueKey('copy-diagnostics'))), lessThan(top(find.text('Keyboard shortcuts'))));
      expect(find.byKey(const ValueKey('share-diagnostics')), findsOneWidget);
      expect(find.text('Mute / unmute'), findsOneWidget);
      expect(find.text('Settings'), findsNothing, reason: 'Anywhere folded');
      await tester.tap(find.byKey(const ValueKey('fold-Anywhere, and in the library')));
      await tester.pumpAndSettle();
      expect(find.text('Ctrl+,'), findsOneWidget);
      expect(find.text('Ctrl+V'), findsOneWidget);
      expect(find.text('/ or Ctrl+F'), findsOneWidget);
      expect(find.byKey(const ValueKey('uosc-credit')), findsOneWidget);
    });

    testWidgets('narrow: icon chips instead of the side nav', (tester) async {
      await pumpSettings(tester, SettingsSection.party, size: const Size(700, 1600));
      expect(find.byType(ChoiceChip), findsWidgets);
      expect(find.byType(ListTile).evaluate().where((e) => e.widget.key == const ValueKey('settings-party')),
          isEmpty, reason: 'no side nav');
      final chip = tester.widget<ChoiceChip>(find.byKey(const ValueKey('settings-party')));
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

    test('an invite: the address, its link; pasted back', () {
      const invite = Invite(host: '192.168.1.20', port: 8080, password: true, version: '1.3.0');
      expect(invite.address, '192.168.1.20:8080');
      expect(invite.link().uri, 'starsync://192.168.1.20:8080');
      expect(invite.fp, isNull, reason: 'reserved for pinned certificates');
      expect(addressIn(invite.link().uri), (host: '192.168.1.20', port: '8080'));
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
        MemberView(id: 'm1', name: 'Hana', buffered: 30, host: true),
        MemberView(id: 'm2', name: 'Bob', buffered: 0),
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
      // The host can be set out like anyone, or waited for.
      await tester.tap(find.descendant(of: find.byKey(const ValueKey('member-m1')), matching: find.byTooltip('More')));
      await tester.pumpAndSettle();
      expect(find.text('Out'), findsOneWidget);
      expect(find.text('Wait for Hana'), findsOneWidget);
    });

    testWidgets('your server, not shared: only you, Invite; shared: the invite and Stop sharing', (tester) async {
      online(const [MemberView(id: 'm1', name: 'Me', buffered: 0)]);
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
      expect(find.text('Looking up your internet address…'), findsOneWidget);
      expect(find.text('Copy invite link'), findsOneWidget);
      expect(find.byKey(const ValueKey('stop-sharing')), findsOneWidget);
      // One address so far: nothing else to pick, nothing to say.
      expect(find.byKey(const ValueKey('invite-other-addresses')), findsNothing);
      expect(find.byKey(const ValueKey('invite-note')), findsNothing);

      // Behind a router: the internet address, one line on forwarding;
      // the home address waits behind Other addresses.
      yours.shared.value = const Invite(host: '203.0.113.7', port: 8080, version: '1.3.0');
      yours.reach.value = const InviteReach(public: '203.0.113.7', local: ['192.168.1.20']);
      await tester.pumpAndSettle();
      expect(find.text('Looking up your internet address…'), findsNothing);
      expect(find.text('Friends outside your home network need port 8080 forwarded to this computer.'),
          findsOneWidget);
      expect(find.text('192.168.1.20:8080'), findsNothing);
      Future<String?> copy() async {
        String? copied;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
          return null;
        });
        addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
        await tester.tap(find.byKey(const ValueKey('copy-invite')));
        await tester.pumpAndSettle();
        return copied;
      }

      // Just the link, nothing around it.
      expect(await copy(), matches(RegExp(r'^starsync://203\.0\.113\.7:8080(/\?name=\S+)?$')));

      await tester.tap(find.byKey(const ValueKey('invite-other-addresses')));
      await tester.pumpAndSettle();
      expect(find.text('203.0.113.7:8080'), findsOneWidget);
      await tester.tap(find.text('192.168.1.20:8080'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('invite-note')), findsNothing, reason: 'home network picked');
      expect(await copy(), startsWith('starsync://192.168.1.20:8080'));

      // No internet address found: one line saying so.
      yours.reach.value = const InviteReach(local: ['192.168.1.20']);
      await tester.pumpAndSettle();
      expect(find.textContaining("Couldn't find your internet address"), findsOneWidget);
      expect(_graph.notifier.toasts.peek().map((t) => t.text), contains('Invite link copied'));
      await tester.pump(const Duration(seconds: 6)); // the toasts go
    });
  });
}
