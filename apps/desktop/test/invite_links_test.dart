import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_relay_core/core.dart';
import 'package:starsync/src/platform/single_instance.dart';
import 'package:starsync/src/platform/url_scheme.dart';
import 'package:starsync/src/session/invite.dart';
import 'package:starsync/src/session/join_offers.dart';
import 'package:starsync/src/session/navigation.dart' show Place;
import 'package:starsync/src/session/public_address.dart';
import 'package:starsync/src/shell/join_offer_card.dart';
import 'package:starsync/src/state/connect_prefs.dart' show RecentServer;

import 'test_graph.dart';

// starsync:// invite links, the internet address lookup, the join
// prompt (links and the clipboard), one app per profile and the link
// handler's registration values.

String health({String name = "Bob's server", String version = '1.3.2', int viewers = 2}) => jsonEncode({
      'ok': true,
      'name': name,
      'proto': RelayConstants.protoMax,
      'protoMin': RelayConstants.protoMin,
      'protoMax': RelayConstants.protoMax,
      'version': version,
      'viewers': viewers,
    });

final _graph = testGraph(healthGet: (uri) async => health());

void main() {
  group('invite link', () {
    test('round trip: address, name and password, which never shows in toString', () {
      const link = InviteLink(host: '203.0.113.7', port: 9000, name: "Bob's server & co", secret: 'p@ss w&rd=1');
      expect(link.uri, startsWith('starsync://203.0.113.7:9000/?name='));
      expect(InviteLink.parse(link.uri), link);
      expect(link.toString(), isNot(contains('p@ss')));
      expect(link.toString(), contains('password'));
      expect(redactLog('opening ${link.uri}'), isNot(contains('w%26rd')));
    });

    test('bare links, IPv6, the default port; anything else is no link', () {
      expect(InviteLink.parse('starsync://192.168.1.20:8080'), const InviteLink(host: '192.168.1.20', port: 8080));
      expect(const InviteLink(host: '192.168.1.20', port: 8080).uri, 'starsync://192.168.1.20:8080');
      expect(InviteLink.parse('STARSYNC://vps.example.com'), const InviteLink(host: 'vps.example.com', port: 8080));
      const v6 = InviteLink(host: 'fe80::1', port: 8080);
      expect(v6.uri, 'starsync://[fe80::1]:8080');
      expect(InviteLink.parse(v6.uri)?.port, 8080);
      expect(InviteLink.parse('starsync://host:99999'), isNull);
      expect(InviteLink.parse('starsync://'), isNull);
      expect(InviteLink.parse('https://192.168.1.20:8080'), isNull);
      expect(InviteLink.parse('starsync://a b:1'), isNull);
    });

    test('the invite copies its link, the password only when asked; old apps still read the address', () {
      const invite = Invite(host: '192.168.1.20', port: 8080, name: "Bob's server", password: true, version: '1.3.2');
      expect(invite.text, contains('(ask me for the password)'));
      expect(invite.text, isNot(contains('pw=')));
      final withPw = invite.textWith(secret: 'hunter2');
      expect(withPw, isNot(contains('ask me')));
      expect(inviteIn(withPw)?.secret, 'hunter2');
      expect(inviteIn(withPw)?.name, "Bob's server");
      // A 1.3.x app pasting it into the Join card's address.
      expect(addressIn(withPw), (host: '192.168.1.20', port: '8080'));
      expect(invite.at('203.0.113.7').address, '203.0.113.7:8080');
    });

    test('found in a text: a link anywhere, an old plain invite, never a bare address', () {
      expect(inviteIn('hey, come watch: starsync://10.0.0.5:8081/?name=Ann see you')?.address, '10.0.0.5:8081');
      expect(inviteIn('Join me on Starsync: 192.168.1.20:8080 (ask me for the password) · Starsync 1.3.0'),
          const InviteLink(host: '192.168.1.20', port: 8080));
      expect(inviteIn('192.168.1.20:8080'), isNull);
      expect(inviteIn('see https://example.com:443/x'), isNull);
      expect(inviteIn('${'x' * 5000} starsync://1.2.3.4:1'), isNull, reason: 'only the start of a long text');
    });

    test('reach: the internet address first; forwarding when it is the router\'s', () {
      const behindRouter = InviteReach(public: '203.0.113.7', local: ['192.168.1.20', '100.64.1.2']);
      expect(behindRouter.best, '203.0.113.7');
      expect(behindRouter.forwarding, isTrue);
      expect([for (final c in behindRouter.choices) c.kind], [AddressKind.public, AddressKind.lan, AddressKind.vpn]);
      const direct = InviteReach(public: '203.0.113.7', local: ['203.0.113.7']);
      expect(direct.forwarding, isFalse);
      expect(direct.choices.length, 1);
      expect(const InviteReach(local: ['192.168.1.20']).best, '192.168.1.20');
      expect(isPublicIpv4('8.8.8.8'), isTrue);
      for (final ip in ['10.1.2.3', '192.168.0.1', '172.20.0.1', '100.100.1.1', '127.0.0.1', '198.18.0.1', '::1', 'x']) {
        expect(isPublicIpv4(ip), isFalse, reason: ip);
      }
    });
  });

  group('internet address', () {
    final a = Uri.parse('https://a.test'), b = Uri.parse('https://b.test'), c = Uri.parse('https://c.test');

    test('the first service with a public address wins; failing, private or odd answers are skipped', () async {
      final asked = <String>[];
      final ip = await lookUpPublicAddress(
        services: [a, b, c],
        get: (uri) async {
          asked.add(uri.host);
          return switch (uri.host) {
            'a.test' => throw const SocketException('blocked'),
            'b.test' => '192.168.1.1\n',
            _ => '203.0.113.7\n',
          };
        },
      );
      expect(ip, '203.0.113.7');
      expect(asked, ['a.test', 'b.test', 'c.test']);
    });

    test('a slow service is given up on; none answering is no address', () async {
      final ip = await lookUpPublicAddress(
        services: [a, b],
        each: const Duration(milliseconds: 50),
        get: (uri) => uri.host == 'a.test' ? Completer<String>().future : Future.value('203.0.113.9'),
      );
      expect(ip, '203.0.113.9');
      expect(await lookUpPublicAddress(services: [a], get: (_) async => '<html>nope</html>'), isNull);
    });
  });

  group('join prompt', () {
    final offers = _graph.joinOffers;
    final yours = _graph.yourServer;
    tearDown(() {
      offers.offer.value = null;
      yours.shared.value = null;
      yours.reach.value = null;
      _graph.forms.recents.value = const [];
    });

    test('a clicked link becomes an offer with what /health says', () async {
      offers.fromArgs(['--whatever', 'starsync://203.0.113.7:8080/?name=Bob']);
      expect(offers.offer.peek()?.source, OfferSource.link);
      expect(offers.offer.peek()?.question, 'Join Bob (203.0.113.7:8080)?');
      await pumpEventQueue();
      final o = offers.offer.peek()!;
      expect(o.question, "Join Bob's server (203.0.113.7:8080)?");
      expect(o.detail, 'Starsync 1.3.2 · 2 watching');
    });

    test('the clipboard: offered once; Not now and Join both stop it coming back', () async {
      offers.fromClipboard('come: starsync://203.0.113.20:8080');
      expect(offers.offer.peek()?.source, OfferSource.clipboard);
      await offers.dismiss();
      expect(offers.offer.peek(), isNull);
      offers.fromClipboard('something else');
      offers.fromClipboard('come: starsync://203.0.113.20:8080');
      expect(offers.offer.peek(), isNull, reason: 'dismissed');

      offers.fromClipboard('starsync://203.0.113.21:8080');
      _graph.forms.recents.value = const [RecentServer(host: '203.0.113.21', port: '8080', secret: 'saved')];
      final link = offers.accept();
      expect(link?.secret, 'saved', reason: 'a link without its password takes the saved one');
      offers.fromClipboard('x');
      offers.fromClipboard('starsync://203.0.113.21:8080');
      expect(offers.offer.peek(), isNull, reason: 'joined');
    });

    test('never your own invite, nor the server you are in, nor plain text', () {
      yours.port.value = 40000;
      addTearDown(() => yours.port.value = null);
      yours.shared.value = const Invite(host: '203.0.113.7', port: 8080);
      yours.reach.value = const InviteReach(public: '203.0.113.7', local: ['192.168.1.20']);
      offers.fromClipboard('starsync://192.168.1.20:8080');
      offers.fromClipboard('starsync://127.0.0.1:40000');
      expect(offers.offer.peek(), isNull);
      // What this app just copied is not offered back to it.
      const copied = 'Join me on Starsync: starsync://198.51.100.4:8080';
      offers.copied(copied);
      offers.fromClipboard(copied);
      expect(offers.offer.peek(), isNull);
      offers.fromClipboard('just some text 10.0.0.1:80');
      expect(offers.offer.peek(), isNull);

      final nav = _graph.navigation;
      nav.place.value = Place.friend;
      nav.address.value = '198.51.100.9:8080';
      addTearDown(() {
        nav.place.value = Place.none;
        nav.address.value = '';
      });
      offers.fromArgs(['starsync://198.51.100.9:8080']);
      expect(offers.offer.peek(), isNull);
    });

    testWidgets('the card: the question, Join and Not now', (tester) async {
      var joined = 0;
      await tester.pumpWidget(scoped(
          _graph,
          MaterialApp(
              theme: ThemeData.dark(),
              home: Scaffold(body: JoinOfferCard(offers: offers, onJoin: () => joined++)))));
      expect(find.byKey(const ValueKey('join-offer')), findsNothing);
      offers.offer.value = const JoinOffer(InviteLink(host: '203.0.113.7', port: 8080, name: 'Ann'), OfferSource.clipboard);
      await tester.pumpAndSettle();
      expect(find.text('Join Ann (203.0.113.7:8080)?'), findsOneWidget);
      expect(find.text('Invite on your clipboard · Checking the server…'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('join-offer-join')));
      expect(joined, 1);
      await tester.tap(find.byKey(const ValueKey('join-offer-dismiss')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('join-offer')), findsNothing);
    });
  });

  group('one app per profile', () {
    late Directory tmp;
    setUp(() async => tmp = await Directory.systemTemp.createTemp('starsync-instance'));
    tearDown(() async => tmp.delete(recursive: true));

    test('a second start hands its arguments and token over and ends', () async {
      final first = await InstanceLock.claim(tmp.path);
      expect(first, isNotNull);
      expect(first!.held, isTrue);
      final got = first.handoffs.first;
      int? allowed;
      final second = await InstanceLock.claim(tmp.path,
          args: ['starsync://1.2.3.4:8080/?pw=x'], activation: 'tok', beforeSend: (p) => allowed = p);
      expect(second, isNull, reason: 'handed over');
      expect(allowed, pid);
      final h = await got;
      expect(h.args, ['starsync://1.2.3.4:8080/?pw=x']);
      expect(h.activation, 'tok');
      await first.release();
    });

    test('each profile folder is its own instance', () async {
      final a = await InstanceLock.claim('${tmp.path}/a');
      final b = await InstanceLock.claim('${tmp.path}/b');
      expect(a?.held, isTrue);
      expect(b?.held, isTrue);
      await a!.release();
      await b!.release();
    });

    test('a start while the app closes waits and takes over once it is gone', () async {
      final first = (await InstanceLock.claim(tmp.path))!;
      first.closing();
      final second = InstanceLock.claim(tmp.path, retryEvery: const Duration(milliseconds: 20));
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await first.release();
      final taken = await second;
      expect(taken?.held, isTrue);
      await taken!.release();
    });

    test('a wrong token is refused (nothing handed over)', () async {
      final first = (await InstanceLock.claim(tmp.path))!;
      var handed = false;
      first.handoffs.listen((_) => handed = true);
      final s = await Socket.connect(InternetAddress.loopbackIPv4, first.port!);
      s.writeln(jsonEncode({'token': 'guess', 'args': ['x']}));
      final reply = await utf8.decoder.bind(s).join();
      expect(reply, contains('"ok":false'));
      expect(handed, isFalse);
      s.destroy();
      await first.release();
    });

    test('no lock and nobody answering: starts anyway after a while', () async {
      final first = (await InstanceLock.claim(tmp.path))!;
      first.closing();
      final started = await InstanceLock.claim(tmp.path,
          retryFor: const Duration(milliseconds: 100),
          closingWait: const Duration(milliseconds: 100),
          retryEvery: const Duration(milliseconds: 20));
      expect(started?.held, isFalse);
      await first.release();
    });
  });

  group('link handler', () {
    test('Windows: HKCU\\Software\\Classes\\starsync opens starsync.exe with the link', () {
      final v = windowsSchemeValues(r'C:\Apps\Starsync\starsync.exe');
      expect(v.first, (r'Software\Classes\starsync', '', 'URL:Starsync invite'));
      expect(v, contains((r'Software\Classes\starsync', 'URL Protocol', '')));
      expect(v.last, (r'Software\Classes\starsync\shell\open\command', '', r'"C:\Apps\Starsync\starsync.exe" "%1"'));
    });

    test('an old-named copy points links at starsync next to it', () {
      expect(schemeExecutable(r'C:\S\watch_together.exe', exists: (_) => true), r'C:\S\starsync.exe');
      expect(schemeExecutable(r'C:\S\watch_together.exe', exists: (_) => false), r'C:\S\watch_together.exe');
      expect(schemeExecutable('/opt/s/watch_together', exists: (_) => true), '/opt/s/starsync');
      expect(schemeExecutable('/opt/s/starsync', exists: (_) => true), '/opt/s/starsync');
    });
  });
}
