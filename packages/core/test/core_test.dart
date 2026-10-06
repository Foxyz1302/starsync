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
      expect(c.name, 'room');
    });

    test('round-trips through map', () {
      const c = AppConfig(
          port: 1234,
          secret: 's',
          name: 'n',
          mediaPath: 'm',
          advertiseHost: '1.2.3.4');
      final back = AppConfig.fromMap(c.toMap());
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
    });

    test('hello rejects wrong type', () {
      expect(() => HelloMessage.fromJson({'t': 'bye'}), throwsA(isA<ProtocolException>()));
    });

    test('room state round-trips', () {
      final s = RoomState(position: 12.5, paused: false, mediaId: 3, serverTime: DateTime.utc(2026, 1, 1));
      final back = RoomState.fromJson(Map<String, Object?>.from(s.toJson()));
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
}
