import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sync_relay_core/core.dart';

/// Fetches a URL body; injectable so tests fake the server's `/health`.
typedef HealthGetter = Future<String> Function(Uri uri);

const healthPollEvery = Duration(seconds: 10);
const _timeout = Duration(seconds: 4);

/// Whether this app and a server have a wire version in common.
enum VersionFit {
  /// Their ranges meet: the join can go ahead.
  ok,
  /// The server's newest version is older than anything this app speaks.
  theyUpdate,
  /// The server's oldest version is newer than anything this app speaks.
  youUpdate,
}

/// [VersionFit] of a server that speaks [min] .. [max] (`/health`
/// `protoMin` / `protoMax`), against this build's
/// [RelayConstants.protoMin] .. [RelayConstants.protoMax].
VersionFit versionFit(int min, int max,
    {int ownMin = RelayConstants.protoMin, int ownMax = RelayConstants.protoMax}) {
  if (max < ownMin) return VersionFit.theyUpdate;
  if (min > ownMax) return VersionFit.youUpdate;
  return VersionFit.ok;
}

/// What a recent-server row and the version gate read from `/health`:
/// unknown until the first probe answers.
class ServerHealth {
  final bool online;
  final String name;
  /// The server's wire range (`protoMin` .. `protoMax`; a server too old
  /// to say has only `proto`, used for both). Null when it says nothing.
  final int? protoMin;
  final int? protoMax;
  final int viewers;
  /// Its Starsync version (`version`), '' from a server too old to say.
  final String version;
  const ServerHealth.offline()
      : online = false,
        name = '',
        protoMin = null,
        protoMax = null,
        viewers = 0,
        version = '';
  const ServerHealth.online({required this.name, this.protoMin, this.protoMax, this.viewers = 0, this.version = ''})
      : online = true;

  /// Null while unknown (offline, or no version given).
  VersionFit? get fit {
    final min = protoMin, max = protoMax;
    if (!online || min == null || max == null) return null;
    return versionFit(min, max);
  }

  /// True when the server and this app have no version in common.
  bool get needsUpdate => fit != null && fit != VersionFit.ok;

  /// The server's own name for people ('' for the dedicated server's
  /// default `server`).
  String get label => name.isNotEmpty && name != 'server' ? name : '';

  /// Lenient parse of `GET /health`; anything unexpected reads as offline.
  static ServerHealth parse(String body) {
    try {
      final j = jsonDecode(body);
      if (j is! Map || j['ok'] != true) return const ServerHealth.offline();
      final name = j['name'], proto = j['proto'], viewers = j['viewers'], version = j['version'];
      final min = j['protoMin'], max = j['protoMax'];
      final p = proto is num ? proto.toInt() : null;
      return ServerHealth.online(
        name: name is String ? name.trim() : '',
        protoMin: min is num ? min.toInt() : p,
        protoMax: max is num ? max.toInt() : p,
        viewers: viewers is num ? viewers.toInt() : 0,
        version: version is String ? version.trim() : '',
      );
    } catch (_) {
      return const ServerHealth.offline();
    }
  }
}

/// The version gate's message for a server that does not fit: who has
/// to update, in plain words ("Bob's server runs Starsync 1.2.1 — they
/// need to update").
String versionGateText(ServerHealth h) {
  final who = h.label.isNotEmpty ? h.label : 'The server';
  final runs = h.version.isNotEmpty ? '$who runs Starsync ${h.version}' : '$who runs ${h.fit == VersionFit.youUpdate ? 'a newer' : 'an older'} Starsync';
  return h.fit == VersionFit.youUpdate ? '$runs — you need to update' : '$runs — they need to update';
}

/// A join stopped before connecting: the server and this app have no
/// version in common ([versionGateText]). [youUpdate]: this app is the
/// older one, so the updater can help.
class VersionGateRefused implements Exception {
  final String message;
  final bool youUpdate;
  const VersionGateRefused(this.message, {required this.youUpdate});
  @override
  String toString() => message;
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
