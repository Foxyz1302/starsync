import 'dart:typed_data';

import 'package:sync_relay_core/core.dart';
import 'package:sync_relay_server/server.dart';
import 'package:test/test.dart';

/// A feed that only records pulls; the test answers them.
class _Feed extends RelayFeed {
  final pulls = <int>[];
  @override
  void pull(int id, int start, int end) => pulls.add(id);
  @override
  void pullPiece(int id, int index) => pulls.add(id);
  @override
  void cancel(int id) {}
}

void main() {
  test('rates keep two significant digits; under 10 kB/s is 0', () {
    expect(roundRate(3249999), 3200000);
    expect(roundRate(87654), 88000);
    expect(roundRate(9999), 0);
    expect(roundRate(double.nan), 0);
  });

  test('the source rate counts busy time only, and settles first', () {
    final r = SourceRate();
    r.sample(2000000, const Duration(seconds: 1));
    expect(r.rate, 0, reason: 'under 2 s of busy time');
    r.sample(4000000, const Duration(seconds: 2));
    expect(r.rate, 2000000);
    // The buffer is full: no pull, no bytes, no busy time: the rate holds.
    r.sample(4000000, const Duration(seconds: 2));
    expect(r.rate, 2000000);
    // Slower now (0.5 MB/s): moves toward it over the window.
    r.sample(5000000, const Duration(seconds: 4));
    expect(r.rate, inExclusiveRange(500000, 2000000));
    // A new feed (totals back to 0) starts over without a bogus sample.
    final before = r.rate;
    r.sample(0, Duration.zero);
    expect(r.rate, before);
  });

  test('read rates: bytesServed over the last 5 s, forgotten tokens drop', () {
    final rates = ReadRates();
    final t0 = DateTime.utc(2026);
    expect(rates.sample(t0, {'a': 0, 'b': 0}), {'a': 0, 'b': 0});
    for (var i = 1; i <= 10; i++) {
      final out = rates.sample(t0.add(Duration(seconds: i)), {'a': i * 2000000, 'b': 0});
      expect(out['a'], 2000000);
      expect(out['b'], 0);
    }
    // a stops reading: its rate falls to 0 once the window has passed.
    var out = <String, int>{};
    for (var i = 11; i <= 16; i++) {
      out = rates.sample(t0.add(Duration(seconds: i)), {'a': 20000000});
    }
    expect(out, {'a': 0});
  });

  test('a buffer runs its clock while a pull is in flight', () async {
    final clock = FeedClock();
    final buf = RelayBuffer()..clock = clock;
    final feed = _Feed();
    buf.attach(feed, 3 * RelayBuffer.slice);
    // A viewer asks: the buffer pulls.
    final read = buf.read('v', 0, 9).toList();
    await Future<void>.delayed(Duration.zero);
    expect(feed.pulls, isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final busy = clock.busy;
    expect(busy, greaterThan(Duration.zero));
    final id = feed.pulls.first;
    buf.feedBytes(id, Uint8List(3 * RelayBuffer.slice));
    buf.feedEnd(id);
    await read;
    final after = clock.busy;
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(clock.busy, after, reason: 'idle: the clock stopped');
    buf.dispose();
  });

  test('the hub puts each member\'s read rate in the state', () {
    var now = DateTime.utc(2026);
    final hub = ServerHub(SessionMap(), 'pw', engine: SyncEngine(clock: () => now));
    final token = hub.session.issueToken('bob', '');
    hub.engine.applyJoin(token, 'bob', '');
    hub.sampleRates();
    hub.session.addBytes(token, 3000000);
    now = now.add(const Duration(seconds: 1));
    hub.sampleRates();
    final json = hub.stateBroadcast().toJson();
    final members = (json['members'] as List).cast<Map<String, Object?>>();
    expect(members.single['rate'], 3000000);
    expect(StateBroadcast.fromJson(json).members.single.rate, 3000000);
  });

  test('media.relay rate and need round-trip; slow only with both known', () {
    const r = MediaRelay(source: 'm1', live: true, rate: 1200000, need: 2300000);
    final back = MediaRelay.fromJson(r.toJson());
    expect(back.rate, 1200000);
    expect(back.need, 2300000);
    expect(back.slow, isTrue);
    expect(const MediaRelay(rate: 1200000).slow, isFalse);
    expect(const MediaRelay().toJson().containsKey('rate'), isFalse);
    expect(MediaRelay.fromJson({'rate': double.infinity, 'need': -1}).rate, 0);
  });

  test('a relay\'s need: byte tracks by size over the duration', () {
    final r = ActiveRelay.fromMember(1, 'x', 't', onLiveChanged: () {});
    expect(r.need(100), 0, reason: 'size unknown until the source connects');
    (r.buffers.single as RelayBuffer).attach(_Feed(), 230000000);
    expect(r.need(100), 2300000);
    expect(r.need(0), 0, reason: 'duration unknown');
    r.dispose();
  });

}
