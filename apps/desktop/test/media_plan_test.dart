import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sync_relay_core/core.dart';
import 'package:starsync/src/session/media_plan.dart';
import 'package:starsync/src/session/relay_feeder.dart';
import 'package:starsync/src/session/status.dart';

// The plan step of the media pipeline as a table: the state, what this
// member serves and its capabilities -> where this app reads the media
// from.

const _server = ServerAddress('h', 9, 'TOK');
const _jf = JellyfinRef(serverId: 'S1', itemId: 'I1', title: 'Ep');

MemberView _m(String id, {Presence presence = Presence.watching, Map<String, bool> jf = const {}, ClientCaps caps = const ClientCaps()}) =>
    MemberView(id: id, name: id.toUpperCase(), ready: false, inSet: true, buffered: 0, presence: presence, jf: jf, caps: caps);

StateBroadcast _state(Map<String, Object?>? media,
        {List<MemberView>? members, bool relay = false, HoldInfo? hold, String transport = 'held'}) =>
    StateBroadcast(
      eventId: 1,
      transport: transport,
      position: 0,
      serverTime: DateTime.utc(2026),
      mediaId: 7,
      media: media,
      members: members ?? [_m('m1'), _m('m2')],
      relay: relay,
      hold: hold,
    );

Map<String, Object?> _relay(MediaRelay r) => r.toJson();

SourcePlan _plan(StateBroadcast r,
        {String self = 'm1', MediaOrigin? origin, bool resolve = true, Set<String> accounts = const {}}) =>
    planMedia(PlanInput(
      state: r,
      selfId: self,
      caps: ClientCaps(source: true, resolve: resolve),
      server: _server,
      origin: origin,
      ownJellyfin: accounts.contains,
    ));

void main() {
  group('plan: state + origin + caps -> source', () {
    final probe = LinkProbe.file(Uri.parse('https://x/v.mkv'), 10);
    final ytDlp = YtDlp('${Directory.systemTemp.path}/plan_no_ytdlp', enabled: false);
    final rows = <(String, StateBroadcast, Map<String, Object?>, String)>[
      ('nothing up', _state(null), {}, 'NoSource'),
      ('your server\'s file', _state({'name': 'Ep 1.mkv', 'size': 5}), {}, 'ServerFile http://h:9/m/default/TOK/Ep%201.mkv'),
      ('a media file link', _state({'name': 'v', 'url': 'https://cdn/v.mkv'}), {}, 'DirectLink https://cdn/v.mkv page=false'),
      ('a page link', _state({'name': 'v', 'url': 'https://site/watch?v=1'}), {}, 'DirectLink https://site/watch?v=1 page=true'),
      ('a page link, no resolver here, m2 can',
          _state({'name': 'v', 'url': 'https://site/watch?v=1'},
              members: [_m('m1'), _m('m2', caps: const ClientCaps(resolve: true))]),
          {'resolve': false},
          "Unresolvable This device can't open web pages; ask M2 to pass it on (Through me)"),
      ('another member\'s relay, live',
          _state({'name': 'f.mkv', 'relay': _relay(const MediaRelay(source: 'm2', live: true))}), {},
          'RelayedSource http://h:9/r/default/TOK/7/f.mkv waiting=false'),
      ('another member\'s relay, not live yet: wait',
          _state({'name': 'f.mkv', 'relay': _relay(const MediaRelay(source: 'm2'))}), {},
          'RelayedSource http://h:9/r/default/TOK/7/f.mkv waiting=true'),
      ('its source left: open what the server has',
          _state({'name': 'f.mkv', 'relay': _relay(const MediaRelay(source: 'm9'))}), {},
          'RelayedSource http://h:9/r/default/TOK/7/f.mkv waiting=false'),
      ('its source gone: open what the server has',
          _state({'name': 'f.mkv', 'relay': _relay(const MediaRelay(source: 'm2', sourceGone: true))}), {},
          'RelayedSource http://h:9/r/default/TOK/7/f.mkv waiting=false'),
      ('the server fetches, not read yet',
          _state({'name': 'p', 'relay': _relay(const MediaRelay(fetch: true))}), {},
          'RelayedSource http://h:9/r/default/TOK/7/p waiting=true'),
      ('a warm relay promoted: its queue id in the URL',
          _state({'name': 'p', 'relay': _relay(const MediaRelay(source: 'm2', live: true, queueId: 'q3'))}), {},
          'RelayedSource http://h:9/r/default/TOK/q3/p waiting=false'),
      ('your own file, passed on',
          _state({'name': 'f.mkv', 'relay': _relay(const MediaRelay(source: 'm1'))}), {'origin': const FileOrigin('/v/f.mkv')},
          'OwnFile /v/f.mkv'),
      ('your own link, passed on',
          _state({'name': 'p', 'relay': _relay(const MediaRelay(source: 'm1', live: true))}),
          {'origin': LinkOrigin('https://site/p', probe, ytDlp)},
          'OwnLink https://site/p'),
      ('your relay, origin forgotten (a restart): read the server\'s buffer',
          _state({'name': 'f.mkv', 'relay': _relay(const MediaRelay(source: 'm1', live: true))}), {},
          'RelayedSource http://h:9/r/default/TOK/7/f.mkv waiting=false'),
      ('Jellyfin, own account',
          _state({'name': 'Ep', 'jellyfin': _jf.toJson()}), {'accounts': {'S1'}},
          'JellyfinSource own=true login=null member=null origin=false'),
      ('Jellyfin, the server\'s login',
          _state({'name': 'Ep', 'jellyfin': _jf.toJson()}, relay: true), {},
          'JellyfinSource own=false login=http://h:9/j/default/TOK/I1 member=null origin=false'),
      ('Jellyfin, a member passes it on',
          _state({'name': 'Ep', 'jellyfin': _jf.toJson(), 'relay': _relay(const MediaRelay(source: 'm2'))}), {},
          'JellyfinSource own=false login=null member=http://h:9/r/default/TOK/7/Ep origin=false'),
      ('Jellyfin, you put it up',
          _state({'name': 'Ep', 'jellyfin': _jf.toJson(), 'relay': _relay(const MediaRelay(source: 'm1'))}),
          {'accounts': {'S1'}, 'origin': const JellyfinOrigin(null)},
          'JellyfinSource own=true login=null member=null origin=true'),
    ];
    for (final (what, r, opts, want) in rows) {
      test(what, () {
        final got = _plan(r,
            origin: opts['origin'] as MediaOrigin?,
            resolve: opts['resolve'] as bool? ?? true,
            accounts: opts['accounts'] as Set<String>? ?? const {});
        expect(_describe(got), want);
      });
    }
  });

  test('a Jellyfin relay channel only when someone present needs it', () {
    StateBroadcast with_(List<MemberView> ms, {bool relay = false}) =>
        _state({'name': 'Ep', 'jellyfin': _jf.toJson()}, members: [_m('m1'), ...ms], relay: relay);
    expect(jellyfinRelayNeeded(with_([_m('m2', jf: {'S1': true})]), _jf, 'm1'), isFalse, reason: 'everyone has an account');
    expect(jellyfinRelayNeeded(with_([_m('m2', jf: {'S1': false})]), _jf, 'm1'), isTrue);
    expect(jellyfinRelayNeeded(with_([_m('m2')]), _jf, 'm1'), isTrue, reason: 'no Jellyfin at all');
    expect(jellyfinRelayNeeded(with_([_m('m2', caps: const ClientCaps(jellyfin: true))]), _jf, 'm1'), isFalse,
        reason: 'its accounts are not reported yet: asked again with the next state');
    expect(jellyfinRelayNeeded(with_([_m('m2')], relay: true), _jf, 'm1'), isFalse, reason: "the server's login passes it on");
    expect(jellyfinRelayNeeded(with_([_m('m2', presence: Presence.away)]), _jf, 'm1'), isFalse, reason: 'sitting out');
    expect(jellyfinRelayNeeded(with_([]), _jf, 'm1'), isFalse, reason: 'alone');
  });

  test("D6: held for the source: everyone's status waits for it by name", () {
    final r = _state({'name': 'f.mkv', 'relay': _relay(const MediaRelay(source: 'm2', live: true, sourceGone: true))},
        members: [
          _m('m1'),
          MemberView(id: 'm2', name: 'Bob', ready: true, inSet: true, buffered: 0, presence: Presence.gone, goneSince: DateTime.utc(2026)),
        ],
        hold: const HoldInfo(reason: HoldReason.source, members: ['m1']));
    for (final own in [false, true]) {
      final line = statusOf(StatusFacts(state: r, selfId: 'm1', ownPlan: own, now: DateTime.utc(2026))).line!;
      expect(line.text, 'Waiting for Bob');
      expect(line.kind, StatusKind.waiting);
      expect(line.level, StatusLevel.warn);
    }
  });
}

String _describe(SourcePlan p) => switch (p) {
      NoSource() => 'NoSource',
      ServerFile(:final url) => 'ServerFile $url',
      DirectLink(:final url, :final page) => 'DirectLink $url page=$page',
      Unresolvable() => 'Unresolvable ${p.reason}',
      RelayedSource(:final url, :final waiting) => 'RelayedSource $url waiting=$waiting',
      OwnFile(:final path) => 'OwnFile $path',
      OwnLink(:final url) => 'OwnLink $url',
      JellyfinSource(:final ownAccount, :final serverLogin, :final memberRelay, :final origin) =>
        'JellyfinSource own=$ownAccount login=$serverLogin member=$memberRelay origin=${origin != null}',
    };
