import 'dart:convert';

import 'package:sync_relay_core/core.dart';
import 'package:test/test.dart';

void main() {
  group('AppConfig', () {
    test('defaults are sane', () {
      final c = AppConfig.defaults();
      expect(c.port, 8080);
      expect(c.secret, isEmpty, reason: 'empty password = open server');
      expect(c.advertiseHost, isEmpty);
    });

    test('fromMap tolerates missing keys', () {
      final c = AppConfig.fromMap({});
      expect(c.port, 8080);
      expect(c.name, 'server');
    });

    test('round-trips through map', () {
      const c = AppConfig(
          port: 1234,
          secret: 's',
          name: 'n',
          mediaPath: 'm',
          advertiseHost: '1.2.3.4',
          hostKey: 'hk');
      final back = AppConfig.fromMap(c.toMap());
      expect(back.hostKey, 'hk');
      expect(back.port, 1234);
      expect(back.secret, 's');
      expect(back.mediaPath, 'm');
      expect(back.advertiseHost, '1.2.3.4');
    });
  });

  group('protocol', () {
    test('non-finite numbers are rejected', () {
      final inf = jsonDecode('{"t":"seek","position":1e400}') as Map<String, Object?>;
      expect(inf['position'], double.infinity);
      expect(() => SeekIntent.fromJson(inf), throwsA(isA<ProtocolException>()));
      expect(
          () => ReportMessage.fromJson(
              {'t': 'report', 'position': 1.0, 'buffered': double.infinity}),
          throwsA(isA<ProtocolException>()));
      expect(
          () => ReportMessage.fromJson(
              {'t': 'report', 'position': double.nan, 'buffered': 1.0}),
          throwsA(isA<ProtocolException>()));
      expect(
          () => SwapIntent.fromJson({
                't': 'swap',
                'media': {'name': 'a', 'size': 1, 'duration': double.infinity}
              }),
          throwsA(isA<ProtocolException>()));
    });

    test('hello round-trips', () {
      const msg = HelloMessage(
        proto: 1,
        secret: 'shh',
        user: HelloUser(name: 'alice'),
        media: HelloMedia(name: 'Ep01.mkv', size: 1500000000, duration: 1400.0),
      );
      final back = HelloMessage.fromJson(Map<String, Object?>.from(msg.toJson()));
      expect(back.user.name, 'alice');
      expect(back.media.size, 1500000000);
      expect(back.hostKey, isEmpty);
      expect(msg.toJson().containsKey('hostKey'), isFalse);
    });

    test('hello carries hostKey when set', () {
      const msg = HelloMessage(
        proto: 1,
        secret: '',
        user: HelloUser(name: 'host'),
        media: HelloMedia(name: '', size: 0, duration: 0),
        hostKey: 'hk',
      );
      final back = HelloMessage.fromJson(Map<String, Object?>.from(msg.toJson()));
      expect(back.hostKey, 'hk');
    });

    test('hello rejects wrong type', () {
      expect(() => HelloMessage.fromJson({'t': 'bye'}), throwsA(isA<ProtocolException>()));
    });

    test('sync state round-trips', () {
      final s = SyncState(position: 12.5, paused: false, mediaId: 3, serverTime: DateTime.utc(2026, 1, 1));
      final back = SyncState.fromJson(Map<String, Object?>.from(s.toJson()));
      expect(back.position, 12.5);
      expect(back.paused, isFalse);
      expect(back.mediaId, 3);
    });

    test('sync event carries doSeek flag', () {
      const e = SyncEvent(kind: 'seek', position: 42.0, doSeek: true, ignoringOnTheFly: 7);
      final back = SyncEvent.fromJson(Map<String, Object?>.from(e.toJson()));
      expect(back.doSeek, isTrue);
      expect(back.ignoringOnTheFly, 7);
    });
  });

  group('RangeRequest', () {
    test('open-ended range', () {
      final r = RangeRequest.parse('bytes=100-', 1000)!;
      expect(r.start, 100);
      expect(r.end, isNull);
      expect(r.contentLength, 900);
    });

    test('closed range', () {
      final r = RangeRequest.parse('bytes=0-99', 1000)!;
      expect(r.contentLength, 100);
      expect(r.contentRange, 'bytes 0-99/1000');
    });

    test('suffix range maps to tail (mkv cues probe)', () {
      final r = RangeRequest.parse('bytes=-500', 1000)!;
      expect(r.start, 500);
      expect(r.contentLength, 500);
    });

    test('missing header returns null (full 200)', () {
      expect(RangeRequest.parse(null, 1000), isNull);
    });

    test('out-of-range start rejected', () {
      expect(RangeRequest.parse('bytes=5000-6000', 1000), isNull);
    });
  });

  group('ClockSync', () {
    test('uses the min-RTT sample, not the average', () {
      final c = ClockSync();
      expect(c.offsetMs, 0);
      // Server is 5000 ms ahead. Symmetric 10 ms trip: exact.
      c.add(sentMs: 1000, serverMs: 6010, receivedMs: 1020);
      // Asymmetric slow trips (300 ms out, 10 back) would skew an average.
      c.add(sentMs: 2000, serverMs: 7300, receivedMs: 2310);
      c.add(sentMs: 3000, serverMs: 8400, receivedMs: 3410);
      expect(c.rttMs, 20);
      expect(c.offsetMs, 5000);
      final local = DateTime.utc(2026, 1, 1);
      expect(c.serverNow(local), local.add(const Duration(seconds: 5)));
    });

    test('old samples age out of the window', () {
      final c = ClockSync(window: 2);
      c.add(sentMs: 0, serverMs: 105, receivedMs: 10); // offset 100
      c.add(sentMs: 0, serverMs: 250, receivedMs: 100);
      c.add(sentMs: 0, serverMs: 250, receivedMs: 100);
      expect(c.offsetMs, 200);
    });

    test('negative round trip ignored', () {
      final c = ClockSync()..add(sentMs: 10, serverMs: 0, receivedMs: 5);
      expect(c.hasSample, isFalse);
    });
  });

  group('proto 6 fields', () {
    Map<String, Object?> rt(Map<String, Object?> j) =>
        Map<String, Object?>.from(jsonDecode(jsonEncode(j)) as Map);

    test('round-trip', () {
      final hello = HelloMessage.fromJson(rt(const HelloMessage(
              proto: 6,
              secret: '',
              user: HelloUser(name: 'a'),
              media: HelloMedia(name: '', size: 0, duration: 0),
              resume: 'tok')
          .toJson()));
      expect(hello.resume, 'tok');
      final seek = SeekIntent.fromJson(rt(const SeekIntent(position: 3, seq: 9).toJson()));
      expect(seek.seq, 9);
      final report = ReportMessage.fromJson(rt(const ReportMessage(
              position: 1, buffered: 2, eventId: 3, duration: 1440.5, mediaId: 4)
          .toJson()));
      expect(report.duration, 1440.5);
      expect(report.mediaId, 4);
      final pong = PongMessage.fromJson(
          rt(const PongMessage(clientMs: 5, serverMs: 7).toJson()));
      expect((pong.clientMs, pong.serverMs), (5, 7));
      expect(PingMessage.fromJson(rt(const PingMessage(clientMs: 5).toJson())).clientMs, 5);
    });

    test('older frames without the new fields still parse', () {
      expect(SeekIntent.fromJson({'t': 'seek', 'position': 1}).seq, 0);
      final r = ReportMessage.fromJson(
          {'t': 'report', 'position': 1, 'buffered': 2, 'eventId': 3});
      expect((r.duration, r.mediaId), (0.0, 0));
    });
  });
}
