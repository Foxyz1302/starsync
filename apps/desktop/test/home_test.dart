import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_together/src/files/ui/files_page.dart';
import 'package:watch_together/src/schedule/ui/schedule_page.dart';
import 'package:sync_relay_core/core.dart';
import 'package:watch_together/src/screens/home/health_probe.dart';
import 'package:watch_together/src/screens/home/media_picker.dart';
import 'package:watch_together/src/shell/app_shell.dart';
import 'package:watch_together/src/shell/library_link.dart' show soloPlayHint;
import 'package:watch_together/src/state/session_state.dart';
import 'package:watch_together/src/state/settings.dart';
import 'package:watch_together/src/update/update_controller.dart';

RecentServer join(String host, String port, [String secret = '']) =>
    RecentServer(hosted: false, host: host, port: port, secret: secret);

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

    test('hosted entries are one per port, separate from joins', () {
      var list = <RecentServer>[];
      list = pushRecent(list, const RecentServer(hosted: true, host: '', port: '8080'));
      list = pushRecent(list, join('127.0.0.1', '8080'));
      list = pushRecent(list, const RecentServer(hosted: true, host: '', port: '8080', secret: 'x'));
      expect(list.length, 2);
      expect(list.first.secret, 'x');
    });

    test('round-trips and tolerates junk', () {
      final list = [join('a.example', '9000', 's'), const RecentServer(hosted: true, host: '', port: '8080')];
      final back = decodeRecents(encodeRecents(list));
      expect(back.map((r) => r.key), list.map((r) => r.key));
      expect(back.first.secret, 's');
      expect(back.last.hosted, isTrue);
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

  test('hwdec value follows mode', () {
    final s = AppSettings();
    expect(s.hwdec.value, 'auto');
    s.setHwdecMode(HwdecMode.off);
    expect(s.hwdec.value, 'no');
    s.setHwdecMode(HwdecMode.custom);
    expect(s.hwdec.value, 'auto');
    s.setHwdecCustom(' vaapi ');
    expect(s.hwdec.value, 'vaapi');
  });

  test('health parse: online, junk and protocol mismatch', () {
    final ok = ServerHealth.parse(jsonEncode(
        {'ok': true, 'name': 'Den', 'proto': RelayConstants.protoVersion, 'viewers': 2}));
    expect(ok.online, isTrue);
    expect(ok.name, 'Den');
    expect(ok.viewers, 2);
    expect(ok.needsUpdate, isFalse);
    expect(ServerHealth.parse('{"ok":true,"proto":-1}').needsUpdate, isTrue);
    expect(ServerHealth.parse('nope').online, isFalse);
    expect(ServerHealth.parse('{"ok":false}').online, isFalse);
    expect(healthUri('::1', '8080').toString(), 'http://[::1]:8080/health');
  });

  test('pasting sorts links and paths into the right source', () {
    final c = MediaPickerController();
    expect(c.source, MediaKind.jellyfin);
    c.pasteText(' https://example.com/a.mkv ');
    expect(c.source, MediaKind.link);
    expect(c.selection, const LinkMedia('https://example.com/a.mkv'));
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
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: AppShell(
        updates: UpdateController(currentVersion: '0.0.0-dev'),
        autoUpdateCheck: false,
        windowControls: false,
        healthGet: health ?? fakeHealth(const {}),
      ),
    ));
    await tester.pump();
  }

  Future<void> openCard(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(ValueKey(key)));
    await tester.pumpAndSettle();
  }

  setUp(() {
    SessionState.instance.recents.value = const [];
    SessionState.instance.route.value = AppRoute.home;
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
    expect(find.text('Name, picture and colour: click your avatar in the top left'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('settings-player')));
    await tester.pumpAndSettle();
    expect(find.text('Hardware decoding'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('settings-updates')));
    await tester.pumpAndSettle();
    expect(find.text('Check for updates on start'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('settings-shortcuts')));
    await tester.pumpAndSettle();
    expect(find.text('Toggle ready'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('settings-integrations')));
    await tester.pumpAndSettle();
    expect(find.text('Play the next episode automatically'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('settings-about')));
    await tester.pumpAndSettle();
    expect(find.text('Dev build — update checks are off'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('tab-library')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('library-tab')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Enter in the join card submits; errors show under it', (tester) async {
    SessionState.instance.lastForm.name = '';
    await pumpShell(tester, const Size(1280, 720));
    await openCard(tester, 'strip-join');
    await tester.enterText(find.byKey(const ValueKey('join-address')), 'friend.example');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.textContaining('display name', findRichText: true), findsOneWidget);
    // The button submits too, and typing in the address clears the error.
    await tester.enterText(find.byKey(const ValueKey('join-address')), 'friend.example2');
    await tester.pump();
    expect(find.textContaining('display name', findRichText: true), findsNothing);
    await tester.tap(find.widgetWithText(FilledButton, 'Join').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('display name', findRichText: true), findsOneWidget);
    // A click outside closes the card; the error is still there on reopen.
    await tester.tapAt(const Offset(20, 700));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('join-address')), findsNothing);
    await openCard(tester, 'strip-join');
    expect(find.textContaining('display name', findRichText: true), findsOneWidget);
  });

  testWidgets('recent rows show live status from /health', (tester) async {
    SessionState.instance.recents.value = [
      join('alpha.example', '8080'),
      join('beta.example', '9000', 'pw'),
      join('gamma.example', '7000'),
      const RecentServer(hosted: true, host: '', port: '8181'),
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
    // Hosted entries live on the Host card, not in the join list.
    expect(find.byKey(const ValueKey('recent-host:8181')), findsNothing);
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

  testWidgets('library offline: welcome band, sources that need nothing, Jellyfin optional', (tester) async {
    await pumpShell(tester, const Size(1280, 900));
    // The three ways in, Join first; none needs Jellyfin.
    expect(find.byKey(const ValueKey('welcome-band')), findsOneWidget);
    expect(find.text('Watch together, in sync'), findsOneWidget);
    final join = tester.getTopLeft(find.byKey(const ValueKey('way-join')));
    expect(join.dx, lessThan(tester.getTopLeft(find.byKey(const ValueKey('way-solo'))).dx));
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
    expect(find.text(soloPlayHint), findsOneWidget);
    expect(find.text('How the others get it'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('host without a name errors in the host card', (tester) async {
    SessionState.instance.lastForm.name = '';
    SessionState.instance.recents.value = [const RecentServer(hosted: true, host: '', port: '8181', secret: 's')];
    await pumpShell(tester, const Size(1280, 900));
    await openCard(tester, 'strip-host');
    expect(find.text('No password — anyone can join'), findsOneWidget);
    expect(find.text('You pick what to watch afterwards, in the library.'), findsOneWidget);
    // A hosted port refills the fields.
    await tester.tap(find.byKey(const ValueKey('recent-host:8181')));
    await tester.pump();
    expect(find.text('No password — anyone can join'), findsNothing);
    await tester.tap(find.widgetWithText(FilledButton, 'Host').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('display name', findRichText: true), findsOneWidget);
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
}
