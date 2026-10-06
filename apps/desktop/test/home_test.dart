import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_relay_core/core.dart';
import 'package:watch_together/src/screens/home/health_probe.dart';
import 'package:watch_together/src/screens/home/home_screen.dart';
import 'package:watch_together/src/screens/home/media_picker.dart';
import 'package:watch_together/src/screens/home/ui.dart';
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
    expect(c.source, MediaKind.file);
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
      home: Scaffold(
        body: HomeShell(
          updates: UpdateController(currentVersion: '0.0.0-dev'),
          autoUpdateCheck: false,
          healthGet: health ?? fakeHealth(const {}),
        ),
      ),
    ));
    await tester.pump();
  }

  setUp(() => SessionState.instance.recents.value = const []);

  testWidgets('tabs and page buttons switch the body', (tester) async {
    await pumpShell(tester, const Size(1280, 900));
    expect(find.byKey(const ValueKey('join-row')), findsOneWidget);
    expect(find.byKey(const ValueKey('host-picker')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('tab-host')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('host-picker')), findsOneWidget);
    expect(find.byKey(const ValueKey('join-row')), findsNothing);
    expect(find.text('No password — anyone can join'), findsOneWidget);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('Hardware decoding'), findsOneWidget);
    expect(find.text('Check automatically on start'), findsOneWidget);
    expect(find.text('Toggle ready'), findsOneWidget);
    await tester.tap(find.byTooltip('Integrations'));
    await tester.pumpAndSettle();
    expect(find.text('Jellyfin'), findsOneWidget);
    await tester.tap(find.byTooltip('About'));
    await tester.pumpAndSettle();
    expect(find.text('Dev build — update checks are off'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('tab-join')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('join-row')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Enter in the join row submits; errors show under it', (tester) async {
    SessionState.instance.lastForm.name = '';
    await pumpShell(tester, const Size(1280, 720));
    await tester.enterText(find.byKey(const ValueKey('join-address')), 'friend.example');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('display name', findRichText: true), findsOneWidget);
    // The button submits too, and typing in the address clears the error.
    await tester.enterText(find.byKey(const ValueKey('join-address')), 'friend.example2');
    await tester.pump();
    expect(find.textContaining('display name', findRichText: true), findsNothing);
    await tester.tap(find.widgetWithText(FilledButton, 'Join'));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('display name', findRichText: true), findsOneWidget);
  });

  testWidgets('recent tiles show live status from /health', (tester) async {
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
    await tester.pump();
    Finder inTile(String key, Finder f) =>
        find.descendant(of: find.byKey(ValueKey('recent-$key')), matching: f);
    expect(inTile('alpha.example:8080', find.text('Movie night')), findsOneWidget);
    expect(inTile('alpha.example:8080', find.text('● online · 3 watching')), findsOneWidget);
    expect(inTile('alpha.example:8080', find.text('needs update')), findsNothing);
    expect(inTile('beta.example:9000', find.text('○ offline')), findsOneWidget);
    expect(inTile('beta.example:9000', find.text('beta.example')), findsOneWidget);
    expect(inTile('gamma.example:7000', find.text('needs update')), findsOneWidget);
    // Hosted entries live on the Host tab, not in the join grid.
    expect(find.byKey(const ValueKey('recent-host:8181')), findsNothing);
    // Tiles share a row on a wide window.
    final a = tester.getRect(find.byKey(const ValueKey('recent-alpha.example:8080')));
    final b = tester.getRect(find.byKey(const ValueKey('recent-beta.example:9000')));
    expect(a.top, b.top);
    // x forgets.
    await tester.tap(inTile('beta.example:9000', find.byTooltip('Forget')));
    await tester.pump();
    expect(find.byKey(const ValueKey('recent-beta.example:9000')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('no recents shows the empty state', (tester) async {
    await pumpShell(tester, const Size(1280, 720));
    expect(find.byKey(const ValueKey('recents-empty')), findsOneWidget);
  });

  testWidgets('wide windows: grid fills the width, fields stay compact', (tester) async {
    SessionState.instance.recents.value = [
      for (var i = 0; i < 6; i++) join('10.0.0.$i', '8080'),
    ];
    await pumpShell(tester, const Size(3440, 1440));
    final first = tester.getRect(find.byKey(const ValueKey('recent-10.0.0.0:8080')));
    final last = tester.getRect(find.byKey(const ValueKey('recent-10.0.0.5:8080')));
    expect(first.top, last.top);
    expect(tester.getSize(find.byKey(const ValueKey('join-address'))).width, 280);
    await tester.tap(find.byKey(const ValueKey('tab-host')));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(const ValueKey('host-column'))).width, 340);
    final file = find.descendant(
        of: find.byKey(const ValueKey('media-file')), matching: find.byType(TextField));
    expect(tester.getSize(file).width, lessThanOrEqualTo(kFieldMaxWidth));
    expect(tester.takeException(), isNull);
  });

  testWidgets('media picker segments switch the input', (tester) async {
    await pumpShell(tester, const Size(1280, 900));
    await tester.tap(find.byKey(const ValueKey('tab-host')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('media-file')), findsOneWidget);
    expect(find.text('Browse'), findsOneWidget);
    await tester.tap(find.text('Link'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('media-link')), findsOneWidget);
    expect(find.text('Paste'), findsOneWidget);
    await tester.tap(find.text('Jellyfin'));
    await tester.pumpAndSettle();
    // No linked server: sign-in right in the picker.
    expect(find.text('Add a Jellyfin server'), findsOneWidget);
    await tester.tap(find.text('Open Integrations'));
    await tester.pumpAndSettle();
    expect(find.text('Add server'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('host column sits right when wide, below when narrow', (tester) async {
    await pumpShell(tester, const Size(1280, 900));
    await tester.tap(find.byKey(const ValueKey('tab-host')));
    await tester.pumpAndSettle();
    var picker = tester.getRect(find.byKey(const ValueKey('host-picker')));
    var column = tester.getRect(find.byKey(const ValueKey('host-column')));
    expect(picker.right, lessThan(column.left));
    expect(picker.top, column.top);

    await pumpShell(tester, const Size(640, 1000));
    picker = tester.getRect(find.byKey(const ValueKey('host-picker')));
    column = tester.getRect(find.byKey(const ValueKey('host-column')));
    expect(picker.bottom, lessThan(column.top));
    expect(tester.takeException(), isNull);
  });

  testWidgets('host without a name errors in the server column', (tester) async {
    SessionState.instance.lastForm.name = '';
    await pumpShell(tester, const Size(1280, 900));
    await tester.tap(find.byKey(const ValueKey('tab-host')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Host'));
    await tester.pump();
    await tester.pump();
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('host-column')),
        matching: find.textContaining('display name', findRichText: true),
      ),
      findsOneWidget,
    );
  });

  testWidgets('narrow window: bar, join row and host tab fit', (tester) async {
    await pumpShell(tester, const Size(480, 800));
    expect(find.byKey(const ValueKey('join-row')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('tab-host')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Jellyfin'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
