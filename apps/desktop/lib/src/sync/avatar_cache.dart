import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'sync_client.dart';

/// Member pictures by content hash (`state.members[].avatarHash`), fetched
/// once from `/a/<sid>/<token>/<hash>` on the host the client dialled and
/// kept in memory. A hash names fixed bytes, so entries never go stale;
/// listeners are notified when one arrives.
class AvatarCache extends ChangeNotifier {
  final SyncClient sync;
  /// Fetches one picture; null on any failure. Injectable for tests.
  final Future<Uint8List?> Function(Uri url) _fetch;
  final Map<String, Uint8List> _bytes = {};
  final Set<String> _inFlight = {};
  final Map<String, DateTime> _failedAt = {};
  StreamSubscription? _sub;
  bool _disposed = false;

  static const _retryAfter = Duration(seconds: 10);
  /// Above this many pictures, ones nobody in the latest state uses go.
  static const _keep = 32;

  AvatarCache(this.sync, {Future<Uint8List?> Function(Uri url)? fetch})
      : _fetch = fetch ?? _httpGet {
    _sub = sync.states.listen((s) {
      final live = {for (final m in s.members) if (m.avatarHash.isNotEmpty) m.avatarHash};
      if (_bytes.length > _keep) _bytes.removeWhere((h, _) => !live.contains(h));
      live.forEach(_want);
    });
  }

  /// The picture for [hash], or null (none, or not here yet: it is fetched
  /// and listeners hear when it lands).
  Uint8List? bytesFor(String hash) {
    if (hash.isEmpty) return null;
    final hit = _bytes[hash];
    if (hit == null) _want(hash);
    return hit;
  }

  void _want(String hash) {
    if (_bytes.containsKey(hash) || _inFlight.contains(hash)) return;
    final failed = _failedAt[hash];
    if (failed != null && DateTime.now().difference(failed) < _retryAfter) return;
    final ws = sync.wsUri;
    final token = sync.token;
    if (ws == null || token.isEmpty) return;
    final url = Uri(
        scheme: ws.scheme == 'wss' ? 'https' : 'http',
        host: ws.host,
        port: ws.port,
        pathSegments: ['a', 'default', token, hash]);
    _inFlight.add(hash);
    unawaited(_fetch(url).then((bytes) {
      _inFlight.remove(hash);
      if (_disposed) return;
      if (bytes == null || bytes.isEmpty) {
        _failedAt[hash] = DateTime.now();
        return;
      }
      _failedAt.remove(hash);
      _bytes[hash] = bytes;
      notifyListeners();
    }));
  }

  static Future<Uint8List?> _httpGet(Uri url) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final resp = await (await client.getUrl(url)).close().timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) {
        await resp.drain<void>();
        return null;
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk in resp.timeout(const Duration(seconds: 15))) {
        builder.add(chunk);
      }
      return builder.takeBytes();
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_sub?.cancel());
    super.dispose();
  }
}
