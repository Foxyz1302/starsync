import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_together/src/screens/home/home_screen.dart';
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

  Future<void> pumpShell(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: HomeShell(updates: UpdateController(currentVersion: '0.0.0-dev'), autoUpdateCheck: false),
      ),
    ));
    await tester.pump();
  }

  testWidgets('home shows both cards side by side on a wide window', (tester) async {
    await pumpShell(tester, const Size(1280, 720));
    final join = tester.getRect(find.byKey(const ValueKey('join-card')));
    final host = tester.getRect(find.byKey(const ValueKey('host-card')));
    expect(join.top, host.top);
    expect(join.height, host.height);
    expect(join.right, lessThan(host.left));
    expect(find.text('No password — anyone can join'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cards stack on a narrow window', (tester) async {
    await pumpShell(tester, const Size(560, 900));
    final join = tester.getRect(find.byKey(const ValueKey('join-card')));
    final host = tester.getRect(find.byKey(const ValueKey('host-card')));
    expect(join.bottom, lessThan(host.top));
    expect(tester.takeException(), isNull);
  });

  testWidgets('join without a name errors inline in the join card', (tester) async {
    SessionState.instance.lastForm.name = '';
    await pumpShell(tester, const Size(1280, 720));
    await tester.tap(find.widgetWithText(FilledButton, 'Join'));
    await tester.pump();
    await tester.pump();
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('join-card')),
        matching: find.textContaining('display name', findRichText: true),
      ),
      findsOneWidget,
    );
  });

  testWidgets('rail switches to settings, integrations and about', (tester) async {
    await pumpShell(tester, const Size(1280, 900));
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    expect(find.text('Hardware decoding'), findsOneWidget);
    expect(find.text('Check automatically on start'), findsOneWidget);
    expect(find.text('Toggle ready'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.extension_outlined));
    await tester.pumpAndSettle();
    expect(find.text('Jellyfin'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.info_outline));
    await tester.pumpAndSettle();
    expect(find.text('Dev build — update checks are off'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
