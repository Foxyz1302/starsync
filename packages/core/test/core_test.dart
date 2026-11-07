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
        user: HelloUser(name: 'alice'));
      final back = HelloMessage.fromJson(Map<String, Object?>.from(msg.toJson()));
      expect(back.user.name, 'alice');
      expect(msg.toJson()['media'], isEmpty, reason: 'a 15 server needs it to say "proto mismatch"');
      expect(back.hostKey, isEmpty);
      expect(msg.toJson().containsKey('hostKey'), isFalse);
    });

    test('hello carries hostKey when set', () {
      const msg = HelloMessage(
        proto: 1,
        secret: '',
        user: HelloUser(name: 'host'),
        hostKey: 'hk');
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
              user: HelloUser(name: 'a'))
          .toJson()));
      expect((hello.protoMin, hello.proto), (6, 6));
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

  test('bufferNeed counts the time played since the last event', () {
    final t0 = DateTime.utc(2026, 1, 1);
    final s = StateBroadcast(
      eventId: 1,
      transport: 'playing',
      position: 0,
      serverTime: t0,
      mediaId: 1,
      media: const {'name': 'clip', 'duration': 6.0},
      members: const [],
    );
    expect(s.bufferNeedAt(t0), 4.0);
    // 3 s in: 3 s left, minus the 2 s end slack.
    expect(s.bufferNeedAt(t0.add(const Duration(seconds: 3))), closeTo(1.0, 1e-9));
    expect(s.bufferNeedAt(t0.add(const Duration(seconds: 5))), 0);
  });

  group('proto 16', () {
    Map<String, Object?> rt(Map<String, Object?> j) => Map<String, Object?>.from(jsonDecode(jsonEncode(j)) as Map);

    test('version ranges: the highest common one, or none', () {
      expect(pickProto(16, 16, serverMin: 16, serverMax: 16), 16);
      expect(pickProto(16, 18, serverMin: 16, serverMax: 17), 17);
      expect(pickProto(15, 15, serverMin: 16, serverMax: 16), isNull);
      expect(pickProto(17, 18, serverMin: 16, serverMax: 16), isNull);
      expect(HelloMessage.protoRangeOf({'proto': 15, 'media': {}}), (min: 15, max: 15));
      expect(HelloMessage.protoRangeOf({'proto': 17, 'protoMin': 16}), (min: 16, max: 17));
      expect(HelloMessage.protoRangeOf({'protoMin': 16}), isNull);
    });

    test('the refusal stays readable by a proto 15 app', () {
      final err = ErrorFrame.version(got: 15, server: '1.3.0').toJson();
      expect(err, {
        't': 'err',
        'code': 'version',
        'message': 'proto mismatch: got 15, want ${RelayConstants.protoMin}..${RelayConstants.protoMax}',
        'for': 'hello',
        'min': RelayConstants.protoMin,
        'max': RelayConstants.protoMax,
        'server': '1.3.0',
      });
      final back = ErrorFrame.fromJson(rt(err));
      expect([back.code, back.min, back.server], [ErrCode.version, RelayConstants.protoMin, '1.3.0']);
      expect(ErrorFrame.fromJson({'t': 'err', 'message': 'wrong secret'}).code, isNull, reason: 'a 15 server');
    });

    test('hello: identity, caps, feedAfter; a bad client id is refused', () {
      const hello = HelloMessage(
          secret: 's',
          user: HelloUser(name: 'a'),
          client: 'AbCdEfGhIjKlMnOpQrStUv',
          seq: 7,
          app: '1.3.0',
          platform: 'linux',
          caps: ClientCaps(source: true, resolve: true),
          feedAfter: 41);
      final json = hello.toJson();
      expect([json['protoMin'], json['proto'], json['media']], [RelayConstants.protoMin, RelayConstants.protoMax, {}]);
      expect(json.containsKey('resume'), isFalse);
      final back = HelloMessage.fromJson(rt(json));
      expect([back.client, back.seq, back.app, back.platform, back.feedAfter], ['AbCdEfGhIjKlMnOpQrStUv', 7, '1.3.0', 'linux', 41]);
      expect(back.caps, const ClientCaps(source: true, resolve: true));
      expect(ClientCaps.fromJson({'source': true, 'teleport': true}).toJson(), {'source': true});
      for (final bad in ['short', 'has space in it 12345', 'x' * 65, 7]) {
        expect(() => HelloMessage.fromJson({...json, 'client': bad}), throwsA(isA<ProtocolException>()));
      }
      expect(HelloMessage.fromJson({...json}..remove('client')).client, isEmpty);
    });

    test('welcome: proto, resumed, instance, grace, replayed feed', () {
      final w = WelcomeMessage(
          token: 't',
          memberId: 'm1',
          proto: 16,
          resumed: true,
          instance: 'boot1',
          grace: 600,
          feed: [FeedMessage(actor: 'a', action: 'join', at: DateTime.utc(2026), seq: 3, replayed: true)]);
      final back = WelcomeMessage.fromJson(rt(w.toJson()));
      expect([back.proto, back.resumed, back.instance, back.grace], [16, true, 'boot1', 600]);
      expect([back.feed.single.seq, back.feed.single.replayed], [3, true]);
    });

    test('presence, play, pause and continue intents, bye', () {
      const p = PresenceIntent(target: 'm2', state: Presence.out, reason: PresenceReason.continued);
      expect(p.toJson(), {'t': 'presence', 'target': 'm2', 'state': 'out', 'reason': 'continue'});
      final back = PresenceIntent.fromJson(rt(p.toJson()));
      expect([back.target, back.state, back.reason], ['m2', Presence.out, PresenceReason.continued]);
      const brb = PresenceIntent(state: Presence.brb, resume: true);
      expect(brb.toJson(), {'t': 'presence', 'state': 'brb', 'resume': true});
      expect(PresenceIntent.fromJson(rt(brb.toJson())).resume, isTrue);
      expect(PresenceIntent.fromJson({'t': 'presence', 'state': 'in'}).target, isEmpty);
      expect(() => PresenceIntent.fromJson({'t': 'presence', 'state': 'away'}), throwsA(isA<ProtocolException>()));
      expect(const TransportIntent(play: true).toJson(), {'t': 'play'});
      expect(TransportIntent.fromJson(const {'t': 'pause'}).play, isFalse);
      expect(const ContinueIntent().toJson(), {'t': 'continue'});
      expect(ContinueIntent.fromJson(const {'t': 'continue', 'target': 'm3'}).target, 'm3');
      expect(const ByeMessage().toJson(), {'t': 'bye'});
    });

    test('members carry presence, since, loading, goneSince, app and caps; no ready', () {
      final since = DateTime.utc(2026, 1, 1, 12);
      final v = MemberView(
          id: 'm1',
          name: 'a',
          presence: Presence.brb,
          since: since,
          loading: true,
          gone: true,
          goneSince: since,
          app: '1.3.0',
          caps: const ClientCaps(jellyfin: true));
      final json = v.toJson();
      expect([json['presence'], json['since'], json['loading'], json['goneSince'], json['app'], json['caps']],
          ['brb', since.toIso8601String(), true, since.toIso8601String(), '1.3.0', {'jellyfin': true}]);
      expect(json.containsKey('ready') || json.containsKey('inSet'), isFalse);
      final back = MemberView.fromJson(rt(json));
      expect([back.presence, back.since, back.loading, back.gone, back.goneSince, back.caps.jellyfin],
          [Presence.brb, since, true, true, since, true]);
      final plain = MemberView.fromJson(rt(const MemberView(id: 'm2', name: 'b').toJson()));
      expect([plain.presence, plain.since, plain.loading, plain.gone], [Presence.watching, null, false, false]);
    });

    test('media.ref rides along, at most 2 KiB; relay sourceGone', () {
      const ref = MediaRef(kind: 'episode', title: 'Show', anilistId: 1, anilistEp: 6, tvdbId: 2, ep: 6, absolute: 30);
      const media = HelloMedia(name: 'x', size: 0, duration: 0, url: 'https://x/y', ref: ref);
      final back = HelloMedia.fromJson(rt(media.toJson()));
      expect(back.ref, ref);
      expect(back.ref!.season, isNull);
      expect(MediaRef.fromJson({'kind': 'trailer'}), isNull);
      expect(() => MediaRef.fromJson({'kind': 'movie', 'title': 'x' * 3000}), throwsA(isA<ProtocolException>()));
      final since = DateTime.utc(2026, 1, 1);
      final relay = MediaRelay(source: 'm2', sourceGone: true, sourceGoneSince: since);
      final r = MediaRelay.fromJson(rt(relay.toJson()));
      expect([r.sourceGone, r.sourceGoneSince], [true, since]);
      expect(r.copyWith(sourceGone: false).toJson().containsKey('sourceGoneSince'), isFalse);
    });

    test('state carries hold, advance, the wish and passed-over members', () {
      final at = DateTime.utc(2026);
      final s = StateBroadcast(
          eventId: 1,
          transport: 'held',
          position: 0,
          serverTime: at,
          mediaId: 1,
          members: const [],
          hold: const HoldInfo(brb: ['m2'], video: ['m3'], source: true),
          advance: QueueAdvance(id: 'q3', at: at, secs: 10),
          wantsPlay: true,
          queuePass: const ['m1']);
      final json = s.toJson();
      expect(json['wish'], 'play');
      final back = StateBroadcast.fromJson(rt(json));
      expect([back.hold!.brb, back.hold!.video, back.hold!.source, back.hold!.members],
          [['m2'], ['m3'], true, ['m2', 'm3']]);
      expect([back.advance!.id, back.advance!.secs], ['q3', 10]);
      expect([back.wantsPlay, back.queuePass], [true, ['m1']]);
      expect(HoldInfo.fromJson(const {}), isNull, reason: 'nobody waited for: no hold');
      expect(StateBroadcast.fromJson(rt({...json, 'wish': 'pause'})).wantsPlay, isFalse);
    });

    test('close codes are distinct', () {
      const codes = [
        CloseCodes.relayNotSource,
        CloseCodes.relayOtherMedia,
        CloseCodes.relayReplaced,
        CloseCodes.version,
        CloseCodes.secret,
        CloseCodes.refused,
        CloseCodes.replaced,
        CloseCodes.stale,
        CloseCodes.silent,
        CloseCodes.left,
      ];
      expect(codes.toSet(), hasLength(codes.length));
    });
  });
}
