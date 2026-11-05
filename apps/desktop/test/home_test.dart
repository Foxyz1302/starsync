import 'dart:convert';
import 'dart:io' show Platform, SocketException;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:starsync/src/files/ui/files_page.dart';
import 'package:starsync/src/schedule/ui/schedule_page.dart';
import 'package:sync_relay_core/core.dart';
import 'package:starsync/src/screens/home/health_probe.dart';
import 'package:starsync/src/screens/home/media_picker.dart';
import 'package:starsync/src/screens/home/update_indicator.dart';
import 'package:starsync/src/shell/app_shell.dart';
import 'package:starsync/src/shell/library_link.dart' show alonePlayHint;
import 'package:starsync/src/state/connect_prefs.dart';
import 'package:starsync/src/state/settings.dart';
import 'package:starsync/src/update/update_controller.dart';

import 'package:starsync/src/session/connection.dart' show ConnClosed;
import 'package:starsync/src/session/navigation.dart' show JoinFailed, Place;
import 'package:starsync/src/session/session_coordinator.dart' show ConnectParams;

import 'test_graph.dart';

/// This file's composition root (see test_graph.dart).
final _graph = testGraph();

RecentServer join(String host, String port, [String secret = '']) =>
    RecentServer(host: host, port: port, secret: secret);

void main() {
  group('recent servers', () {
    test('newest first, deduped by server, capped', () {
      var list = <RecentServer>[];
      for (var i = 0; i < 8; i++) {
        list = pushRecent(list, join('10.0.0.$i', '8080'));
      }
      expect(list.length, maxRecentServers);
      expect(list.first.host, '10.0.0.7');
      list = pushRecent(list, join('10.0.0.4', '8080', 'pw'));
      expect(list.length, maxRecentServers);
      expect(list.first.secret, 'pw');
      expect(list.where((r) => r.host == '10.0.0.4').length, 1);
    });

    test('round-trips and tolerates junk; hosted entries of older versions are dropped', () {
      final list = [join('a.example', '9000', 's'), join('b.example', '8080')];
      final back = decodeRecents(encodeRecents(list));
      expect(back.map((r) => r.key), list.map((r) => r.key));
      expect(back.first.secret, 's');
      expect(decodeRecents('[{"hosted":true,"host":"","port":"8080"},{"host":"h","port":"1"}]').single.host, 'h');
      expect(decodeRecents('not json'), isEmpty);
      expect(decodeRecents(42), isEmpty);
      expect(decodeRecents('[{"host":1},{"host":"h","port":"1"}]').single.host, 'h');
    });

    test('old single form migrates to one recent unless it was localhost', () {
      expect(migrateRecents(hadForm: true, host: 'friend.example', port: '8080', secret: 'pw').single.secret, 'pw');
      expect(migrateRecents(hadForm: true, host: '127.0.0.1', port: '8080', secret: ''), isEmpty);
      expect(migrateRecents(hadForm: false, host: 'friend.example', port: '8080', secret: ''), isEmpty);
    });
  });

  test('chat pop-ups default to All', () {
    expect(AppSettings().chatPopups.value, ChatPopups.all);
  });

  test('hwdec value follows mode', () {
    final s = AppSettings();
    expect(s.hwdec.value, autoHwdec);
    expect(autoHwdec, Platform.isWindows ? 'auto-copy' : 'auto');
    s.setHwdecMode(HwdecMode.off);
    expect(s.hwdec.value, 'no');
    s.setHwdecMode(HwdecMode.custom);
    expect(s.hwdec.value, autoHwdec);
    s.setHwdecCustom(' vaapi ');
    expect(s.hwdec.value, 'vaapi');
  });

  test('health parse: online, junk and protocol mismatch', () {
    final ok = ServerHealth.parse(jsonEncode({
      'ok': true,
      'name': 'Den',
      'proto': RelayConstants.protoMax,
      'protoMin': RelayConstants.protoMin,
      'protoMax': RelayConstants.protoMax,
      'viewers': 2,
      'version': '1.3.0'
    }));
    expect(ok.online, isTrue);
    expect(ok.name, 'Den');
    expect(ok.version, '1.3.0');
    expect(ServerHealth.parse('{"ok":true}').version, '', reason: 'a server too old to say');
    expect(ok.viewers, 2);
    expect(ok.needsUpdate, isFalse);
    expect(ServerHealth.parse('{"ok":true,"proto":-1}').needsUpdate, isTrue);
    expect(ServerHealth.parse('nope').online, isFalse);
    expect(ServerHealth.parse('{"ok":false}').online, isFalse);
    expect(healthUri('::1', '8080').toString(), 'http://[::1]:8080/health');
  });

  group('version gate (/health)', () {
    String body({required int min, required int max, String version = '', String name = ''}) =>
        jsonEncode({'ok': true, 'name': name, 'proto': max, 'protoMin': min, 'protoMax': max, 'version': version});
    const own = RelayConstants.protoMin;

    test('older, newer, compatible', () {
      final older = ServerHealth.parse(body(min: own - 2, max: own - 1, version: '1.2.1', name: "Bob's server"));
      expect(older.fit, VersionFit.theyUpdate);
      expect(versionGateText(older), "Bob's server runs Starsync 1.2.1 — they need to update");
      final newer = ServerHealth.parse(body(min: RelayConstants.protoMax + 1, max: RelayConstants.protoMax + 2, version: '2.0.0'));
      expect(newer.fit, VersionFit.youUpdate);
      expect(versionGateText(newer), 'The server runs Starsync 2.0.0 — you need to update');
      final overlap = ServerHealth.parse(body(min: own - 1, max: RelayConstants.protoMax + 3));
      expect(overlap.fit, VersionFit.ok, reason: 'ranges that meet are fine');
      // A proto 15 server says only `proto`.
      final old = ServerHealth.parse('{"ok":true,"proto":15,"name":"server"}');
      expect(old.fit, VersionFit.theyUpdate);
      expect(versionGateText(old), 'The server runs an older Starsync — they need to update');
      expect(ServerHealth.parse('{"ok":true}').fit, isNull, reason: 'unknown: let the hello decide');
    });

    test('a join stops at the gate, still at home, before connecting', () async {
      final graph = testGraph(healthGet: (uri) async => body(min: own - 2, max: own - 1, version: '1.2.1'));
      await expectLater(
          graph.navigation.join(const ConnectParams(host: 'old.example', port: 8080, secret: '', name: 'Me')),
          throwsA(isA<VersionGateRefused>()
              .having((e) => e.youUpdate, 'youUpdate', isFalse)
              .having((e) => e.message, 'message', contains('they need to update'))));
      expect(graph.connection.state.peek(), isA<ConnClosed>(), reason: 'never dialled');
      final newer = testGraph(
          healthGet: (uri) async => body(min: RelayConstants.protoMax + 1, max: RelayConstants.protoMax + 1));
      await expectLater(newer.navigation.join(const ConnectParams(host: 'new.example', port: 8080, secret: '', name: 'Me')),
          throwsA(isA<VersionGateRefused>().having((e) => e.youUpdate, 'youUpdate', isTrue)));
      final offline = testGraph(healthGet: (uri) async => throw const SocketException('refused'));
      await expectLater(offline.navigation.join(const ConnectParams(host: 'gone.example', port: 8080, secret: '', name: 'Me')),
          throwsA(isA<JoinFailed>()));
    });

    testWidgets('the Join card says who has to update and offers the updater when it is you', (tester) async {
      final graph = testGraph(
          healthGet: (uri) async => body(min: RelayConstants.protoMax + 1, max: RelayConstants.protoMax + 1, version: '2.0.0'));
      graph.forms.form.name = 'Me';
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(scoped(
          graph,
          MaterialApp(
            theme: ThemeData.dark(),
            home: AppShell(
              updates: UpdateController(currentVersion: '0.0.0-dev'),
              autoUpdateCheck: false,
              windowControls: false,
              healthGet: graph.navigation.healthGet,
            ),
          )));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('strip-join')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('join-address')), 'new.example');
      await tester.tap(find.widgetWithText(FilledButton, 'Join').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('you need to update'), findsOneWidget);
      expect(find.byKey(const ValueKey('join-update')), findsOneWidget);
    });
  });

  test('pasting sorts links and paths into the right source', () {
    final c = MediaPickerController();
    expect(c.source, MediaKind.jellyfin);
    c.pasteText(' https://example.com/a.mkv ');
    expect(c.source, MediaKind.link);
    expect(c.selection, const LinkMedia('https://example.com/a.mkv', relay: LinkRelay.me));
    c.pasteText('/home/me/b.mkv');
    expect(c.source, MediaKind.file);
    expect(c.selection, const FileMedia('/home/me/b.mkv'));
    c.source = MediaKind.jellyfin;
    expect(c.selection, isNull);
    c.dispose();
  });

  /// Fake `/health`: host -> JSON body; unknown hosts are unreachable.
  HealthGetter fakeHealth(Map<String, Map<String, Object>> up) => (uri) async {
        final body = up[uri.host];
        if (body == null) throw Exception('connection refused');
        return jsonEncode(body);
      };

  Future<void> pumpShell(WidgetTester tester, Size size, {HealthGetter? health}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(scoped(_graph, MaterialApp(
      theme: ThemeData.dark(),
      home: AppShell(
        updates: UpdateController(currentVersion: '0.0.0-dev'),
        autoUpdateCheck: false,
        windowControls: false,
        healthGet: health ?? fakeHealth(const {}),
      ),
    )));
    await tester.pump();
  }

  Future<void> openCard(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(ValueKey(key)));
    await tester.pumpAndSettle();
  }

  setUp(() {
    _graph.forms.recents.value = const [];
    _graph.navigation.place.value = Place.none;
  });

  testWidgets('tabs and settings pages switch the body', (tester) async {
    await pumpShell(tester, const Size(1280, 900));
    expect(find.byKey(const ValueKey('library-tab')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('tab-schedule')));
    // The schedule shows a spinner while it loads: pump frames, not settle.
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(find.byKey(const ValueKey('library-tab')), findsNothing);
    expect(find.byType(SchedulePage), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('tab-settings')));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pumpAndSettle();
    // Player first (also for Ctrl+,).
    expect(find.text('Upscaling shader'), findsOneWidget);
    expect(find.text('Play the next episode automatically'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('settings-party')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('party-name')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('settings-updates')));
    await tester.pumpAndSettle();
    expect(find.text('Check now'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('settings-library')));
    await tester.pumpAndSettle();
    expect(find.text('Web links'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('settings-help')));
    await tester.pumpAndSettle();
    expect(find.text('Play / pause for everyone; hold: BRB (anywhere in a server)'), findsOneWidget);
    expect(find.text('Dev build — update checks are off'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('tab-library')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('library-tab')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Enter in the join card submits; errors show under it', (tester) async {
    _graph.forms.form.name = 'Me';
    await pumpShell(tester, const Size(1280, 720));
    await openCard(tester, 'strip-join');
    await tester.enterText(find.byKey(const ValueKey('join-port')), '0');
    await tester.enterText(find.byKey(const ValueKey('join-address')), 'friend.example');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.textContaining('port must be', findRichText: true), findsOneWidget);
    // The button submits too, and typing in the address clears the error.
    await tester.enterText(find.byKey(const ValueKey('join-address')), 'friend.example2');
    await tester.pump();
    expect(find.textContaining('port must be', findRichText: true), findsNothing);
    await tester.tap(find.widgetWithText(FilledButton, 'Join').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('port must be', findRichText: true), findsOneWidget);
    // A click outside closes the card; the error is still there on reopen.
    await tester.tapAt(const Offset(20, 700));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('join-address')), findsNothing);
    await openCard(tester, 'strip-join');
    expect(find.textContaining('port must be', findRichText: true), findsOneWidget);
  });

  testWidgets('recent rows show live status from /health', (tester) async {
    _graph.forms.recents.value = [
      join('alpha.example', '8080'),
      join('beta.example', '9000', 'pw'),
      join('gamma.example', '7000'),
    ];
    await pumpShell(tester, const Size(1280, 900),
        health: fakeHealth({
          'alpha.example': {
            'ok': true,
            'name': 'Movie night',
            'proto': RelayConstants.protoVersion,
            'viewers': 3,
          },
          'gamma.example': {'ok': true, 'name': '', 'proto': -1, 'viewers': 0},
        }));
    await openCard(tester, 'strip-join');
    Finder inRow(String key, Finder f) =>
        find.descendant(of: find.byKey(ValueKey('recent-$key')), matching: f);
    expect(inRow('alpha.example:8080', find.text('Movie night')), findsOneWidget);
    expect(inRow('alpha.example:8080', find.text('● online · 3 watching')), findsOneWidget);
    expect(inRow('alpha.example:8080', find.text('needs update')), findsNothing);
    expect(inRow('beta.example:9000', find.text('○ offline')), findsOneWidget);
    expect(inRow('beta.example:9000', find.text('beta.example')), findsOneWidget);
    expect(inRow('gamma.example:7000', find.text('needs update')), findsOneWidget);
    // x forgets.
    await tester.tap(inRow('beta.example:9000', find.byTooltip('Forget')));
    await tester.pump();
    expect(find.byKey(const ValueKey('recent-beta.example:9000')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('no recents: the join card is just the form', (tester) async {
    await pumpShell(tester, const Size(1280, 720));
    await openCard(tester, 'strip-join');
    expect(find.text('Recent'), findsNothing);
    expect(find.byKey(const ValueKey('join-row')), findsOneWidget);
  });

  testWidgets('library at home: welcome band, sources that need nothing, Jellyfin optional', (tester) async {
    await pumpShell(tester, const Size(1280, 900));
    // The three ways in, Join first; none needs Jellyfin.
    expect(find.byKey(const ValueKey('welcome-band')), findsOneWidget);
    expect(find.text('Watch together, in sync'), findsOneWidget);
    final join = tester.getTopLeft(find.byKey(const ValueKey('way-join')));
    expect(join.dx, lessThan(tester.getTopLeft(find.byKey(const ValueKey('way-invite'))).dx));
    expect(find.text('Watch on your own'), findsOneWidget);
    expect(find.text('Host'), findsNothing, reason: 'no Host: your server is always there');
    // No linked server: Files and Link first, Jellyfin as an optional card.
    expect(find.text('Pick something to watch'), findsOneWidget);
    expect(find.text('Add a Jellyfin server'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('jellyfin-link')));
    await tester.pumpAndSettle();
    expect(find.text('Add a Jellyfin server'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('source-files')));
    await tester.pumpAndSettle();
    expect(find.byType(FilesPage), findsOneWidget);
    await tester.tap(find.text('Link'));
    await tester.pumpAndSettle();
    expect(find.text('Watch from a link'), findsOneWidget);
    // Alone: Play, no relay modes.
    expect(find.text(alonePlayHint), findsOneWidget);
    expect(find.text('How the others get it'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pasting an invite into the address fills the port', (tester) async {
    await pumpShell(tester, const Size(1280, 900));
    await openCard(tester, 'strip-join');
    await tester.enterText(find.byKey(const ValueKey('join-address')),
        'Join me on Starsync: 192.168.1.20:9123 (ask me for the password) · Starsync 1.3.0');
    await tester.pump();
    expect(tester.widget<TextField>(find.byKey(const ValueKey('join-address'))).controller!.text, '192.168.1.20');
    expect(tester.widget<TextField>(find.byKey(const ValueKey('join-port'))).controller!.text, '9123');
  });

  testWidgets('narrow window: strip, cards and library fit', (tester) async {
    await pumpShell(tester, const Size(480, 800));
    final ex = tester.takeException();
    expect(ex, isNull);
    await openCard(tester, 'strip-join');
    expect(find.byKey(const ValueKey('join-row')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tapAt(const Offset(5, 790));
    await tester.pumpAndSettle();
    // Narrow: the sources are icons with tooltips.
    for (final source in ['Link', 'Files', 'Jellyfin']) {
      await tester.tap(find.byTooltip(source));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: source);
    }
  });

  group('update bar', () {
    const m = UpdateManifest(
        version: '1.2.1', protocol: 1, url: 'http://x/a.tgz', notes: 'Faster joins');
    Future<UpdateController> pump(WidgetTester tester, UpdateStatus s,
        {String current = '1.2.0'}) async {
      final c = UpdateController(
          currentVersion: current,
          executablePath: '/nowhere/watch_together',
          restart: (_, _) async {});
      c.status.value = s;
      await tester.pumpWidget(scoped(_graph, MaterialApp(
          home: Scaffold(body: Column(children: [UpdateBar(controller: c)])))));
      return c;
    }

    testWidgets('says what is ready, the version running, Later hides it',
        (tester) async {
      await pump(tester,
          const UpdateStatus(UpdatePhase.available, manifest: m, canInstall: true));
      expect(find.text('Starsync 1.2.1 is ready'), findsOneWidget);
      expect(find.text('You are running 1.2.0 · Faster joins'), findsOneWidget);
      expect(find.text('Update and restart'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('update-later')));
      await tester.pump();
      expect(find.byKey(const ValueKey('update-bar')), findsNothing);
    });

    testWidgets('a copy that cannot update itself says it is older',
        (tester) async {
      await pump(tester, const UpdateStatus(UpdatePhase.available, manifest: m));
      expect(find.text('This copy of Starsync is older than the latest release (1.2.1)'),
          findsOneWidget);
      expect(find.text('Update and restart'), findsNothing);
    });

    testWidgets('a test build is not told which version it runs',
        (tester) async {
      await pump(tester,
          const UpdateStatus(UpdatePhase.available, manifest: m, canInstall: true),
          current: '1.2.1-dev.2');
      expect(find.text('Faster joins'), findsOneWidget);
    });

    testWidgets('nothing to install: no bar', (tester) async {
      await pump(tester, const UpdateStatus(UpdatePhase.idle));
      expect(find.byKey(const ValueKey('update-bar')), findsNothing);
    });
  });
}
