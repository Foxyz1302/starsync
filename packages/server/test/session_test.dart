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

    test('kick unknown throws, kick known forbids + drops', () async {
      final s = Session(id: 'default', secret: 'shh');
      expect(() => s.kick('nope'), throwsA(isA<AuthException>()));
      final t = s.issueToken('mallory', '');
      var dropped = false;
      String? gotReason;
      s.tokens[t]!.onKick = (reason) async {
        dropped = true;
        gotReason = reason;
      };
      await s.kick(t, reason: 'idle');
      expect(s.gate(t), MediaGate.forbidden);
      expect(dropped, isTrue);
      expect(gotReason, 'idle');
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
      expect(s.tokens.values.single.avatar, hasLength(64 * 1024));
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
    test('proto 7: Jellyfin refs and relay', () {
      expect(RelayConstants.protoVersion, 7);
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

    test('kicked + kick request round-trip', () {
      const k = KickedMessage(reason: 'idle');
      final back = KickedMessage.fromJson(Map<String, Object?>.from(k.toJson()));
      expect(back.reason, 'idle');
      const r = KickRequest(target: 'abc', reason: 'afk?');
      final backR = KickRequest.fromJson(Map<String, Object?>.from(r.toJson()));
      expect(backR.target, 'abc');
      expect(backR.reason, 'afk?');
      expect(() => KickedMessage.fromJson({'t': 'err'}), throwsA(isA<ProtocolException>()));
      expect(() => KickRequest.fromJson({'t': 'err'}), throwsA(isA<ProtocolException>()));
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
