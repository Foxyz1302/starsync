// Live relay test against a real Jellyfin server. Skipped unless the same
// variables as packages/core/test/jellyfin_live_test.dart are set:
//
//   JELLYFIN_TEST_URL, JELLYFIN_TEST_TOKEN, JELLYFIN_TEST_CLIENT,
//   JELLYFIN_TEST_DEVICE, JELLYFIN_TEST_DEVICE_ID, JELLYFIN_TEST_VERSION
//
// The device fields must be the token's own (Jellyfin overwrites a token's
// stored device fields with the header's). Read-only: it relays 1 KiB of one
// episode and compares it with the same range fetched directly.
library;

import 'dart:convert';
import 'dart:io';

import 'package:sync_relay_core/core.dart';
import 'package:sync_relay_server/server.dart';
import 'package:test/test.dart';

void main() {
  final env = Platform.environment;
  const keys = [
    'JELLYFIN_TEST_URL',
    'JELLYFIN_TEST_TOKEN',
    'JELLYFIN_TEST_CLIENT',
    'JELLYFIN_TEST_DEVICE',
    'JELLYFIN_TEST_DEVICE_ID',
    'JELLYFIN_TEST_VERSION',
  ];
  final skip = keys.every(env.containsKey) ? null : 'JELLYFIN_TEST_* not set';

  test('relays a 1 KiB range byte-exact', () async {
    final cred = JellyfinCredential(
      baseUrl: env['JELLYFIN_TEST_URL']!,
      token: env['JELLYFIN_TEST_TOKEN']!,
      client: env['JELLYFIN_TEST_CLIENT']!,
      device: env['JELLYFIN_TEST_DEVICE']!,
      deviceId: env['JELLYFIN_TEST_DEVICE_ID']!,
      version: env['JELLYFIN_TEST_VERSION']!,
    );
    final jf = JellyfinClient(baseUrl: cred.baseUrl, clientInfo: cred.clientInfo, accessToken: cred.token);
    await jf.validateToken();
    final episode = (await jf.items(const JellyfinItemQuery(
            includeItemTypes: [JellyfinItemType.episode], recursive: true, limit: 1)))
        .items
        .single;

    final server = SyncServer(AppConfig(port: 0, secret: '', name: 'live', jellyfin: cred));
    await server.start();
    final http = HttpClient();
    final ws = await WebSocket.connect('ws://127.0.0.1:${server.boundPort}/sync');
    try {
      expect(server.hub.jellyfin!.serverId, isNotEmpty, reason: 'server id looked up');
      final frames = ws.map((m) => jsonDecode('$m') as Map).asBroadcastStream();
      ws.add(jsonEncode(HelloMessage(
              proto: RelayConstants.protoVersion,
              secret: '',
              user: const HelloUser(name: 'live'),
              media: const HelloMedia(name: '', size: 0, duration: 0))
          .toJson()));
      final welcome = await frames.firstWhere((f) => f['t'] == 'welcome').timeout(const Duration(seconds: 5));
      ws.add(jsonEncode(SwapIntent(
          media: HelloMedia(
              name: episode.name,
              size: 0,
              duration: 0,
              jellyfin: JellyfinRef(
                  serverId: server.hub.jellyfin!.serverId, itemId: episode.id, title: episode.name))).toJson()));
      await frames.firstWhere((f) => f['t'] == 'state' && f['relay'] == true).timeout(const Duration(seconds: 5));

      final req = await http.get('127.0.0.1', server.boundPort, '/j/default/${welcome['token']}/${episode.id}');
      req.headers.set('range', 'bytes=0-1023');
      final res = await req.close();
      expect(res.statusCode, 206);
      final relayed = [for (final c in await res.toList()) ...c];
      expect(relayed, hasLength(1024));

      final direct = await http.getUrl(jf.shareableStreamUrl(episode.id));
      jf.authHeaders.forEach(direct.headers.set);
      direct.headers.set('range', 'bytes=0-1023');
      final directRes = await direct.close();
      expect(res.headers.value('content-range'), directRes.headers.value('content-range'));
      expect(relayed, [for (final c in await directRes.toList()) ...c]);
      expect(server.session.totalBytesServed, 1024);
    } finally {
      await ws.close();
      http.close(force: true);
      jf.close();
      await server.stop();
    }
  }, skip: skip, timeout: const Timeout(Duration(seconds: 60)));
}
