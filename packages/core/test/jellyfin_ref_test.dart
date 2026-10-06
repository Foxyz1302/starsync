import 'dart:convert';
import 'dart:io';

import 'package:sync_relay_core/core.dart';
import 'package:test/test.dart';

Map<String, Object?> wire(Map<String, Object?> json) =>
    Map<String, Object?>.from(jsonDecode(jsonEncode(json)) as Map);

void main() {
  const ref = JellyfinRef(
    serverId: 'abc123',
    itemId: '0123456789abcdef0123456789abcdef',
    mediaSourceId: 'fedcba9876543210fedcba9876543210',
    title: 'Pilot',
    subtitle: 'Show - S01E01',
    runtimeSecs: 1440.5,
  );

  group('protocol', () {
    test('swap with a Jellyfin ref round-trips, no url', () {
      const swap = SwapIntent(media: HelloMedia(name: 'Pilot', size: 0, duration: 0, jellyfin: ref));
      final json = wire(swap.toJson());
      expect(json['media'], {
        'name': 'Pilot',
        'size': 0,
        'duration': 0.0,
        'jellyfin': {
          'serverId': 'abc123',
          'itemId': '0123456789abcdef0123456789abcdef',
          'mediaSourceId': 'fedcba9876543210fedcba9876543210',
          'title': 'Pilot',
          'subtitle': 'Show - S01E01',
          'runtimeSecs': 1440.5,
        },
      });
      final back = SwapIntent.fromJson(json).media;
      expect(back.jellyfin, ref);
      expect(back.url, isNull);
    });

    test('minimal ref omits optional fields; url media has no jellyfin', () {
      const minimal = JellyfinRef(serverId: 's', itemId: 'i');
      expect(minimal.toJson(), {'serverId': 's', 'itemId': 'i', 'title': ''});
      expect(JellyfinRef.fromJson(wire(minimal.toJson())), minimal);
      final url = HelloMedia.fromJson(wire(const HelloMedia(name: 'a', size: 1, duration: 2, url: 'http://x/a').toJson()));
      expect(url.jellyfin, isNull);
      expect(url.toJson().containsKey('jellyfin'), isFalse);
    });

    test('non-finite runtimeSecs is rejected', () {
      expect(() => JellyfinRef.fromJson({'serverId': 's', 'itemId': 'i', 'runtimeSecs': double.infinity}),
          throwsA(isA<ProtocolException>()));
    });

    test('state relay flag and member jf round-trip, absent by default', () {
      final state = StateBroadcast(
        eventId: 1,
        transport: 'held',
        position: 0,
        serverTime: DateTime.utc(2026),
        mediaId: 2,
        media: const HelloMedia(name: 'Pilot', size: 0, duration: 0, jellyfin: ref).toJson(),
        members: const [
          MemberView(id: 'm1', name: 'a', ready: false, inSet: false, buffered: 0, stale: false, jf: {'abc123': false}),
          MemberView(id: 'm2', name: 'b', ready: false, inSet: false, buffered: 0, stale: false),
        ],
        relay: true,
      );
      final json = wire(state.toJson());
      expect(json['relay'], true);
      expect((json['members'] as List)[0], containsPair('jf', {'abc123': false}));
      expect((json['members'] as List)[1], isNot(contains('jf')));
      final back = StateBroadcast.fromJson(json);
      expect(back.relay, isTrue);
      expect(back.members[0].jf, {'abc123': false});
      expect(back.members[1].jf, isEmpty);
      expect(HelloMedia.fromJson(back.media!).jellyfin, ref);

      final plain = StateBroadcast(
          eventId: 1, transport: 'held', position: 0, serverTime: DateTime.utc(2026), mediaId: 1, members: const []);
      expect(plain.toJson().containsKey('relay'), isFalse);
      expect(StateBroadcast.fromJson(wire(plain.toJson())).relay, isFalse);
    });

    test('welcome relayUrl round-trips, omitted when null', () {
      const w = WelcomeMessage(token: 't', memberId: 'm1', relayUrl: 'http://h:1/j/default/t/i');
      expect(WelcomeMessage.fromJson(wire(w.toJson())).relayUrl, 'http://h:1/j/default/t/i');
      expect(const WelcomeMessage(token: 't').toJson().containsKey('relayUrl'), isFalse);
    });

    test('report jf: round-trip, absent = null, junk dropped and capped', () {
      const r = ReportMessage(position: 1, buffered: 2, eventId: 3, jf: {'abc123': true});
      expect(wire(r.toJson())['jf'], {'abc123': true});
      expect(ReportMessage.fromJson(wire(r.toJson())).jf, {'abc123': true});
      expect(ReportMessage.fromJson(wire(const ReportMessage(position: 1, buffered: 2, eventId: 3).toJson())).jf,
          isNull);
      final junk = ReportMessage.fromJson({
        't': 'report',
        'position': 0,
        'buffered': 0,
        'eventId': 0,
        'jf': {
          'ok': true,
          'bad': 'yes',
          'x' * 65: true,
          for (var i = 0; i < 20; i++) 's$i': false,
        },
      }).jf!;
      expect(junk['ok'], isTrue);
      expect(junk.containsKey('bad'), isFalse);
      expect(junk.length, 8);
    });
  });

  group('engine', () {
    late DateTime t;
    late SyncEngine engine;
    setUp(() {
      t = DateTime.utc(2026);
      engine = SyncEngine(clock: () => t);
      engine.applyJoin('a', 'alice', '');
    });

    test('swap with a ref broadcasts the ref, and a learned duration keeps it', () {
      expect(engine.applySwap('a', const HelloMedia(name: 'Pilot', size: 0, duration: 0, jellyfin: ref)), isTrue);
      expect(engine.mediaId, 2);
      engine.applyReport('a', 0, 0, engine.eventId, duration: 1441, mediaId: 2);
      final media = HelloMedia.fromJson(engine.broadcast().media!);
      expect(media.duration, 1441);
      expect(media.jellyfin, ref);
      expect(media.url, isNull);
    });

    test('broadcast carries relay only when asked', () {
      expect(engine.broadcast().relay, isFalse);
      expect(engine.broadcast(relay: true).relay, isTrue);
    });

    test('report jf is sticky per member and shows in the member view', () {
      engine.applyReport('a', 0, 0, engine.eventId, jf: {'abc123': true});
      engine.applyReport('a', 0, 0, engine.eventId);
      expect(engine.broadcast().members.single.jf, {'abc123': true});
      engine.applyReport('a', 0, 0, engine.eventId, jf: {'abc123': false});
      expect(engine.broadcast().members.single.jf, {'abc123': false});
    });
  });

  group('config', () {
    const cred = JellyfinCredential(
      baseUrl: 'http://jf.local:8096',
      serverId: 'abc123',
      token: 'SECRET-TOKEN',
      client: 'Watch Together',
      device: 'host-pc',
      deviceId: 'dev-1',
      version: '1.2.3',
    );

    test('AppConfig map round-trips the credential as primitives', () {
      final map = const AppConfig(port: 1, secret: '', name: 'n', jellyfin: cred).toMap();
      expect(map['jellyfin'], {
        'baseUrl': 'http://jf.local:8096',
        'serverId': 'abc123',
        'token': 'SECRET-TOKEN',
        'client': 'Watch Together',
        'device': 'host-pc',
        'deviceId': 'dev-1',
        'version': '1.2.3',
      });
      final back = AppConfig.fromMap(wire(map)).jellyfin!;
      expect(back.toMap(), cred.toMap());
      expect(const AppConfig(port: 1, secret: '', name: 'n').toMap().containsKey('jellyfin'), isFalse);
      expect(AppConfig.fromMap(const {}).jellyfin, isNull);
    });

    test('serverId optional; missing fields fail without echoing values', () {
      final m = cred.toMap()..remove('serverId');
      expect(JellyfinCredential.fromMap(m)!.serverId, '');
      final bad = cred.toMap()..remove('device');
      expect(
          () => AppConfig.fromMap({'jellyfin': bad}),
          throwsA(isA<ConfigException>()
              .having((e) => e.message, 'message', allOf(contains('jellyfin.device'), isNot(contains('SECRET'))))));
    });

    test('toString never prints the token', () {
      expect('$cred', isNot(contains('SECRET')));
    });

    test('clientInfo sends exactly the configured fields', () {
      expect(cred.clientInfo.authorizationHeader(cred.token),
          'MediaBrowser Client="Watch%20Together", Device="host-pc", DeviceId="dev-1", Version="1.2.3", Token="SECRET-TOKEN"');
    });

    test('credential file (YAML) loads; parse errors do not echo the file', () async {
      final dir = await Directory.systemTemp.createTemp('jfcred');
      try {
        final ok = File('${dir.path}/jf.yaml');
        await ok.writeAsString('baseUrl: http://jf.local:8096\ntoken: SECRET-TOKEN\nclient: Watch Together\n'
            'device: host-pc\ndeviceId: dev-1\nversion: 1.2.3\n');
        final loaded = await JellyfinCredential.loadFile(ok.path);
        expect(loaded.token, 'SECRET-TOKEN');
        expect(loaded.serverId, '');
        final cfg = File('${dir.path}/cfg.yaml');
        await cfg.writeAsString('port: 9\njellyfin:\n  baseUrl: http://x\n  token: SECRET-TOKEN\n'
            '  client: c\n  device: d\n  deviceId: i\n  version: v\n');
        expect((await AppConfig.loadFile(cfg.path)).jellyfin!.device, 'd');
        final broken = File('${dir.path}/bad.yaml');
        await broken.writeAsString('token: SECRET-TOKEN\n  : : [\n');
        await expectLater(
            JellyfinCredential.loadFile(broken.path),
            throwsA(isA<ConfigException>()
                .having((e) => e.message, 'message', isNot(contains('SECRET')))));
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });
}
