import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:sync_relay_core/core.dart';

import 'sync_client.dart';

/// Member pictures by content hash (`state.members[].avatarHash`), from `/a/`.
class AvatarCache extends PictureCache {
  AvatarCache(super.sync, {super.fetch})
      : super(route: 'a', keep: 32, live: (s) => [for (final m in s.members) m.avatarHash]);
}

/// The current media's art by content hash (`state.media.art`), from `/i/`.
class ArtCache extends PictureCache {
  ArtCache(super.sync, {super.fetch}) : super(route: 'i', keep: 8, live: artHashesOf);

  /// Poster and banner hashes of [s]'s media.
  static List<String> artHashesOf(StateBroadcast s) {
    final art = s.media?['art'];
    if (art is! Map) return const [];
    return [for (final v in art.values) if (v is String) v];
  }
}

/// Pictures by content hash, fetched once from `/<route>/<sid>/<token>/<hash>`
/// on the host the client dialled and kept in memory. A hash names fixed
/// bytes, so entries never go stale; listeners are notified when one
/// arrives. Hashes in each state ([live]) are fetched ahead of use.
class PictureCache extends ChangeNotifier {
  final SyncClient sync;
  /// First path segment of the picture route: 'a' (avatars), 'i' (art).
  final String route;
  /// Above this many pictures, ones not in the latest state go.
  final int keep;
  /// Fetches one picture; null on any failure. Injectable for tests.
  final Future<Uint8List?> Function(Uri url) _fetch;
  final Map<String, Uint8List> _bytes = {};
  final Set<String> _inFlight = {};
  final Map<String, DateTime> _failedAt = {};
  StreamSubscription? _sub;
  bool _disposed = false;

  static const _retryAfter = Duration(seconds: 10);

  PictureCache(this.sync,
      {required this.route,
      required this.keep,
      required Iterable<String> Function(StateBroadcast state) live,
      Future<Uint8List?> Function(Uri url)? fetch})
      : _fetch = fetch ?? _httpGet {
    _sub = sync.states.listen((s) {
      final hashes = {for (final h in live(s)) if (h.isNotEmpty) h};
      if (_bytes.length > keep) _bytes.removeWhere((h, _) => !hashes.contains(h));
      hashes.forEach(_want);
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
        pathSegments: [route, 'default', token, hash]);
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
