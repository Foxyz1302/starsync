import 'dart:io';
import 'dart:math';

import 'package:sync_relay_core/core.dart';

enum MediaGate { ok, gone, unauthorized, forbidden, offline }

class ViewerToken {
  final String token;
  final String name;
  final String avatar;
  bool kicked = false;
  /// Sent the server's host key in hello: the hosting app's own client.
  bool isHost = false;
  int bytesServed = 0;
  DateTime lastSeen;
  Future<void> Function(String reason)? onKick;
  ViewerToken({required this.token, required this.name, this.avatar = ''})
      : lastSeen = DateTime.now().toUtc();

  bool isStale(Duration timeout, [DateTime? now]) =>
      (now ?? DateTime.now().toUtc()).difference(lastSeen) > timeout;

  void touch([DateTime? now]) => lastSeen = now ?? DateTime.now().toUtc();
}

class SessionMedia {
  final String name;
  final int size;
  final double duration;
  final String? url;
  final File? file;
  /// Jellyfin media by reference; never together with [url] or [file].
  final JellyfinRef? jellyfin;
  final int mediaId;
  const SessionMedia({
    required this.name,
    required this.size,
    required this.duration,
    this.url,
    this.file,
    this.jellyfin,
    this.mediaId = 1,
  });
}

class Session {
  final String id;
  final String secret;
  final Map<String, ViewerToken> tokens = {};
  SessionMedia? media;
  final _random = Random.secure();

  Session({required this.id, required this.secret});

  String issueToken(String name, String avatar) {
    if (avatar.length > RelayConstants.maxAvatarBytes) {
      throw const AuthException('avatar too large');
    }
    final trimmed = name.trim();
    final cleanName = trimmed.isEmpty
        ? '?'
        : trimmed.substring(
            0, trimmed.length.clamp(0, RelayConstants.maxNameLength));
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    final token = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    tokens[token] = ViewerToken(token: token, name: cleanName, avatar: avatar);
    return token;
  }

  MediaGate gate(String? token) {
    if (token == null || !tokens.containsKey(token)) return MediaGate.unauthorized;
    if (tokens[token]!.kicked) return MediaGate.forbidden;
    return MediaGate.ok;
  }

  Future<void> kick(String token, {String reason = ''}) async {
    final viewer = tokens[token];
    if (viewer == null) throw const AuthException('unknown token');
    viewer.kicked = true;
    await viewer.onKick?.call(reason);
  }

  void addBytes(String? token, int n) {
    if (token != null) tokens[token]?.bytesServed += n;
  }

  int get totalBytesServed => tokens.values.fold(0, (a, v) => a + v.bytesServed);
}

class SessionMap {
  final Map<String, Session> _sessions = {};

  Session getOrCreate(String id, String secret) =>
      _sessions.putIfAbsent(id, () => Session(id: id, secret: secret));

  Session? get(String id) => _sessions[id];

  void drop(String id) => _sessions.remove(id);
}
