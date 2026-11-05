// Who fetches the current media and how it spreads (the members card's
// source line, part of the one status), and each member's route and
// buffer.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_relay_core/core.dart';
import 'package:starsync/src/session/delivery.dart';
import 'package:starsync/src/shell/delivery_line.dart';

import 'test_graph.dart';

/// This file's composition root (see test_graph.dart).
final _graph = testGraph();

MemberView _m(String id, String name, {double buffered = 30, bool host = false, int rate = 0}) =>
    MemberView(id: id, name: name, buffered: buffered, host: host, rate: rate);

StateBroadcast _state(Map<String, Object?>? media, List<MemberView> members, {String transport = 'playing'}) =>
    StateBroadcast(
      eventId: 1,
      transport: transport,
      position: 10,
      serverTime: DateTime.now().toUtc(),
      mediaId: 2,
      media: media,
      members: members,
    );

Map<String, Object?> _relayed(MediaRelay relay) =>
    {'name': 'x.mkv', 'size': 0, 'duration': 1000, 'relay': relay.toJson()};

void main() {
  final foxyz = _m('m1', 'Foxyz');
  final bob = _m('m2', 'Bob', rate: 3200000);
  final ann = _m('m3', 'Ann');

  test('a member relay: who passes it on, how many read it, how fast', () {
    final r = _state(
        _relayed(const MediaRelay(source: 'm1', live: true, rate: 4100000, need: 2300000)), [foxyz, bob, ann]);
    final d = deliveryOf(r, selfId: 'm2')!;
    expect(d.kind, DeliveryKind.memberRelay);
    expect(d.state, SourceState.ok);
    expect(d.title, 'Foxyz passes it on through the server');
    expect(d.detail, '2 through the server · 4.1 MB/s, needs 2.3 MB/s');
    expect(d.headroom, closeTo(4.1 / 2.3, 0.01));
    expect(deliveryOf(r, selfId: 'm1')!.title, 'You pass it on through the server');
    final mb = memberDeliveryOf(bob, r, d);
    expect(mb.route, DeliveryRoute.server);
    expect(mb.detail, 'via server · 3.2 MB/s · 30 s buffered');
    expect(memberDeliveryOf(foxyz, r, d).route, DeliveryRoute.source);
  });

  test('slow source: amber for everyone, the warning for the source only', () {
    final r = _state(
        _relayed(const MediaRelay(source: 'm1', live: true, rate: 1200000, need: 2300000)), [foxyz, bob]);
    expect(deliveryOf(r, selfId: 'm2')!.state, SourceState.slow);
    expect(deliveryOf(r, selfId: 'm2')!.title, "Foxyz's upload is slower than the video");
    expect(slowSourceWarning(r, 'm1'), contains('Your upload (1.2 MB/s) is slower than this video needs (2.3 MB/s)'));
    expect(slowSourceWarning(r, 'm2'), isNull);
    // Bitrate unknown: rates without a comparison, no warning.
    final unknown = _state(_relayed(const MediaRelay(source: 'm1', live: true, rate: 1200000)), [foxyz, bob]);
    expect(deliveryOf(unknown, selfId: 'm2')!.state, SourceState.ok);
    expect(deliveryOf(unknown, selfId: 'm2')!.detail, '1 through the server · 1.2 MB/s');
    expect(slowSourceWarning(unknown, 'm1'), isNull);
  });

  test('the source left: named from before, no rates', () {
    final names = MemberNames()..observe(_state(null, [foxyz, bob]));
    final r = _state(_relayed(const MediaRelay(source: 'm1', rate: 4100000, need: 2300000)), [bob, ann]);
    final d = deliveryOf(r, selfId: 'm2', names: names)!;
    expect(d.state, SourceState.left);
    expect(d.title, 'Foxyz left — playing what the server has');
    expect(d.detail, '2 through the server');
  });

  test("the source's connection dropped: what the server has, for how long, no rates", () {
    final since = DateTime.utc(2026, 1, 1, 12);
    final gone = MemberView(id: 'm1', name: 'Foxyz', buffered: 30, gone: true);
    final r = _state(
        _relayed(MediaRelay(source: 'm1', live: true, rate: 4100000, need: 2300000, sourceGone: true, sourceGoneSince: since)),
        [gone, bob, ann]);
    final d = deliveryOf(r, selfId: 'm2', now: since.add(const Duration(seconds: 30)))!;
    expect(d.state, SourceState.gone);
    expect(d.title, "Foxyz's connection dropped — playing what the server has");
    expect(d.detail, '2 through the server');
    expect(deliveryOf(r, selfId: 'm2', now: since.add(const Duration(minutes: 3)))!.title,
        "Foxyz's connection dropped — playing what the server has (3 min)");
  });

  test('channel down: waiting', () {
    final r = _state(_relayed(const MediaRelay(source: 'm1')), [foxyz, bob]);
    expect(deliveryOf(r, selfId: 'm2')!.title, 'Waiting for Foxyz to reconnect');
  });

  test('links are direct, the host file is the host\'s, solo shows nothing', () {
    final link = _state({'name': 'v', 'url': 'https://example.com/v.mp4'}, [foxyz, bob]);
    final d = deliveryOf(link, selfId: 'm2')!;
    expect(d.title, 'Everyone plays the link directly');
    expect(d.detail, isEmpty);
    expect(memberDeliveryOf(bob, link, d).short, 'direct');
    final file = _state({'name': 'f.mkv'}, [_m('m1', 'Foxyz', host: true), bob]);
    expect(deliveryOf(file, selfId: 'm2')!.title, 'Foxyz hosts the file');
    expect(deliveryOf(_state({'name': 'f.mkv'}, [bob]), selfId: 'm2'), isNull);
    expect(deliveryOf(_state(null, [foxyz, bob]), selfId: 'm2'), isNull);
  });

  test('Jellyfin: own accounts direct, the rest via server', () {
    const ref = {'serverId': 'srv', 'itemId': '0123456789abcdef0123456789abcdef', 'title': 'Pilot'};
    MemberView jf(String id, String name, bool own) =>
        MemberView(id: id, name: name, buffered: 30, jf: {'srv': own});
    final all = [jf('m1', 'Foxyz', true), jf('m2', 'Bob', true)];
    final media = {'name': 'Pilot', 'jellyfin': ref, 'relay': const MediaRelay(source: 'm1', live: true).toJson()};
    final d = deliveryOf(_state(media, all), selfId: 'm2')!;
    expect(d.title, 'Everyone streams it from Jellyfin', reason: 'the relay stands by');
    final mixed = _state(media, [...all, jf('m3', 'Guest', false)]);
    final m = deliveryOf(mixed, selfId: 'm2')!;
    expect(m.kind, DeliveryKind.memberRelay);
    expect(m.detail, '1 with their own account · 1 through the server');
    expect(memberDeliveryOf(jf('m2', 'Bob', true), mixed, m).short, 'own Jellyfin account');
  });

  test('buffer health: enough, low, empty while playing', () {
    final r = _state({'name': 'v', 'url': 'https://e/v', 'duration': 1000}, [foxyz, bob]);
    final d = deliveryOf(r, selfId: 'm2')!;
    expect(memberDeliveryOf(_m('a', 'A', buffered: 30), r, d).health, BufferHealth.good);
    expect(memberDeliveryOf(_m('a', 'A', buffered: 2), r, d).health, BufferHealth.low);
    expect(memberDeliveryOf(_m('a', 'A', buffered: 0), r, d).health, BufferHealth.starving);
    final held = _state(r.media, [foxyz, bob], transport: 'held');
    expect(memberDeliveryOf(_m('a', 'A', buffered: 0), held, d).health, BufferHealth.low);
  });

  test('rates read as MB/s or kB/s', () {
    expect(formatRate(4100000), '4.1 MB/s');
    expect(formatRate(12000000), '12 MB/s');
    expect(formatRate(850000), '850 kB/s');
  });

  testWidgets('the source line and a member\'s status fit the members card', (tester) async {
    final r = _state(
        _relayed(const MediaRelay(source: 'm1', live: true, rate: 1200000, need: 2300000)), [foxyz, bob, ann]);
    final d = deliveryOf(r, selfId: 'm2')!;
    await tester.pumpWidget(scoped(_graph, MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 340,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              SourceLine(delivery: d),
              DeliveryStatus(status: 'ready', delivery: memberDeliveryOf(bob, r, d)),
            ]),
          ),
        ),
      ),
    )));
    await tester.pumpAndSettle();
    expect(find.text("Foxyz's upload is slower than the video"), findsOneWidget);
    expect(find.byKey(const ValueKey('headroom-bar')), findsOneWidget);
    expect(find.text('ready · via server · 3.2 MB/s'), findsOneWidget);
    expect(find.byKey(const ValueKey('health-dot')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
