import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sync_relay_core/core.dart';

/// Fetches a URL body; injectable so tests fake the server's `/health`.
typedef HealthGetter = Future<String> Function(Uri uri);

const healthPollEvery = Duration(seconds: 10);
const _timeout = Duration(seconds: 4);

/// What a recent-server tile shows: unknown until the first probe answers.
class ServerHealth {
  final bool online;
  final String name;
  final int? proto;
  final int viewers;
  const ServerHealth.offline()
      : online = false,
        name = '',
        proto = null,
        viewers = 0;
  const ServerHealth.online({required this.name, this.proto, this.viewers = 0})
      : online = true;

  /// True when the server speaks another protocol than this build.
  bool get needsUpdate =>
      online && proto != null && proto != RelayConstants.protoVersion;

  /// Lenient parse of `GET /health`; anything unexpected reads as offline.
  static ServerHealth parse(String body) {
    try {
      final j = jsonDecode(body);
      if (j is! Map || j['ok'] != true) return const ServerHealth.offline();
      final name = j['name'], proto = j['proto'], viewers = j['viewers'];
      return ServerHealth.online(
        name: name is String ? name.trim() : '',
        proto: proto is num ? proto.toInt() : null,
        viewers: viewers is num ? viewers.toInt() : 0,
      );
    } catch (_) {
      return const ServerHealth.offline();
    }
  }
}

Uri healthUri(String host, String port) {
  final h = host.trim();
  // Bare IPv6 literals need brackets in a URL.
  final authority = h.contains(':') && !h.startsWith('[') ? '[$h]' : h;
  return Uri.parse('http://$authority:${port.trim()}/health');
}

Future<ServerHealth> probeHealth(String host, String port, HealthGetter get) async {
  try {
    return ServerHealth.parse(await get(healthUri(host, port)).timeout(_timeout));
  } catch (_) {
    return const ServerHealth.offline();
  }
}

/// Plain dart:io GET; non-200 throws.
Future<String> defaultHealthGet(Uri uri) async {
  final client = HttpClient()..connectionTimeout = _timeout;
  try {
    final req = await client.getUrl(uri);
    final res = await req.close().timeout(_timeout);
    if (res.statusCode != 200) {
      await res.drain<void>();
      throw HttpException('status ${res.statusCode}', uri: uri);
    }
    return await res.transform(utf8.decoder).join().timeout(_timeout);
  } finally {
    client.close(force: true);
  }
}
