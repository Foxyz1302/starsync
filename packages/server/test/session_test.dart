import 'package:sync_relay_core/core.dart';
import 'package:sync_relay_server/server.dart';
import 'package:test/test.dart';

void main() {
  group('Session model', () {
    test('tokens are unique 128-bit hex', () {
      final s = Session(id: 'default', secret: 'shh');
      final a = s.issueToken('alice', '');
      final b = s.issueToken('bob', '');
      expect(a, hasLength(32));
      expect(a, isNot(b));
      expect(RegExp(r'^[0-9a-f]{32}$').hasMatch(a), isTrue);
    });

    test('gate: unknown -> unauthorized, known -> ok', () {
      final s = Session(id: 'default', secret: 'shh');
      expect(s.gate(null), MediaGate.unauthorized);
      expect(s.gate('nope'), MediaGate.unauthorized);
      final t = s.issueToken('alice', '');
      expect(s.gate(t), MediaGate.ok);
    });

    test('oversize avatar rejected', () {
      final s = Session(id: 'default', secret: 'shh');
      final big = 'x' * (RelayConstants.maxAvatarBytes + 1);
      expect(() => s.issueToken('alice', big), throwsA(isA<AuthException>()));
    });

    test('64 KiB avatar accepted under raised cap', () {
      final s = Session(id: 'default', secret: 'shh');
      final png = 'x' * (64 * 1024);
      expect(s.issueToken('alice', png), isNotEmpty);
      expect(s.tokens, hasLength(1));
    });

    test('names truncated to cap, blank becomes ?', () {
      final s = Session(id: 'default', secret: 'shh');
      final long = s.issueToken('a' * 100, '');
      expect(s.tokens[long]!.name, hasLength(RelayConstants.maxNameLength));
      final blank = s.issueToken('   ', '');
      expect(s.tokens[blank]!.name, '?');
    });

    test('byte counters accumulate', () {      final s = Session(id: 'default', secret: 'shh');
      final a = s.issueToken('alice', '');
      final b = s.issueToken('bob', '');
      s.addBytes(a, 100);
      s.addBytes(b, 50);
      s.addBytes('ghost', 999);
      expect(s.tokens[a]!.bytesServed, 100);
      expect(s.totalBytesServed, 150);
    });

    test('SessionMap create/get/drop', () {
      final m = SessionMap();
      expect(m.get('default'), isNull);
      final s = m.getOrCreate('default', 'shh');
      expect(m.get('default'), same(s));
      expect(m.getOrCreate('default', 'other'), same(s));
      m.drop('default');
      expect(m.get('default'), isNull);
    });
  });

  group('core welcome + proto', () {
    test('proto 11: avatars by hash, profile intent', () {
      expect(RelayConstants.protoVersion, 11);
      const v = MemberView(id: 'm1', name: 'a', ready: false, inSet: false, buffered: 0, stale: false);
      expect(v.toJson().containsKey('avatarHash'), isFalse);
      expect(v.toJson().containsKey('avatar'), isFalse);
      const h = MemberView(
          id: 'm1', name: 'a', avatarHash: 'abc', ready: false, inSet: false, buffered: 0, stale: false);
      expect(MemberView.fromJson(Map<String, Object?>.from(h.toJson())).avatarHash, 'abc');
      // host: only on the hosting app's member, absent otherwise.
      expect(v.toJson().containsKey('host'), isFalse);
      const host = MemberView(id: 'm2', name: 'h', ready: false, inSet: false, buffered: 0, stale: false, host: true);
      expect(host.toJson()['host'], isTrue);
      expect(MemberView.fromJson(Map<String, Object?>.from(host.toJson())).host, isTrue);
      expect(MemberView.fromJson(Map<String, Object?>.from(v.toJson())).host, isFalse);
      expect(const ProfileIntent(name: 'b').toJson(), {'t': 'profile', 'name': 'b'});
      final p = ProfileIntent.fromJson({'t': 'profile', 'avatar': ''});
      expect(p.name, isNull);
      expect(p.avatar, '');
    });

    test('relayed media', () {
      const m = HelloMedia(name: 'a', size: 1, duration: 0, relay: MediaRelay(source: 'm1', live: true));
      final back = HelloMedia.fromJson(Map<String, Object?>.from(m.toJson()));
      expect(back.relay!.source, 'm1');
      expect(back.relay!.live, isTrue);
      expect(back.relay!.fetch, isFalse);
      expect(const MediaRelay().toJson(), isEmpty);
    });

    test('welcome round-trips with token + member id', () {
      const w = WelcomeMessage(token: 'abc', memberId: 'm1', mediaUrl: 'http://h/m');
      final back = WelcomeMessage.fromJson(Map<String, Object?>.from(w.toJson()));
      expect(back.token, 'abc');
      expect(back.memberId, 'm1');
      expect(back.mediaUrl, 'http://h/m');
      expect(back.state, isNull);
    });

    test('welcome rejects wrong type', () {
      expect(() => WelcomeMessage.fromJson({'t': 'hello'}), throwsA(isA<ProtocolException>()));
    });

    test('lastSeen touch + stale helper', () {
      final s = Session(id: 'default', secret: 'shh');
      final t = s.issueToken('alice', '');
      final viewer = s.tokens[t]!;
      expect(viewer.isStale(const Duration(seconds: 30)), isFalse);
      viewer.touch(DateTime.utc(2020, 1, 1));
      expect(viewer.isStale(const Duration(seconds: 30)), isTrue);
      expect(viewer.isStale(const Duration(seconds: 30), DateTime.utc(2020, 1, 1, 0, 0, 10)), isFalse);
    });
  });
}
