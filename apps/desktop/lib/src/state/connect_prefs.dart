import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:hive_ce/hive.dart';
import 'package:signals/signals.dart';

const connectFormBoxName = 'connect_form';

const connectKeyHost = 'host';
const connectKeyPort = 'port';
const connectKeySecret = 'secret';
const connectKeyName = 'name';
const connectKeyAvatarPath = 'avatarPath';
const connectKeyMediaPath = 'mediaPath';
const connectKeyLinkUrl = 'linkUrl';

Future<Box> openConnectFormBox() => Hive.openBox(connectFormBoxName);

Box? connectFormBoxIfOpen() =>
    Hive.isBoxOpen(connectFormBoxName) ? Hive.box(connectFormBoxName) : null;

String readString(Box box, String key, String fallback) {
  final v = box.get(key);
  return v is String ? v : fallback;
}

const connectKeyHostPort = 'hostPort';
const connectKeyHostSecret = 'hostSecret';
const connectKeyRecents = 'recents';
const maxRecentServers = 6;

/// The connect form: the Join card's address ([host]/[port]/[secret]),
/// your server's port and password when shared ([hostPort]/[hostSecret]),
/// the profile name and the last media picked.
class ConnectForm {
  String host;
  String port;
  String secret;
  String hostPort;
  String hostSecret;
  String name;
  String avatarPath;
  String mediaPath;
  String linkUrl;
  ConnectForm({
    this.host = '127.0.0.1',
    this.port = '8080',
    this.secret = '',
    this.hostPort = '8080',
    this.hostSecret = '',
    this.name = '',
    this.avatarPath = '',
    this.mediaPath = '',
    this.linkUrl = '',
  });

  ConnectForm copy() => ConnectForm(
        host: host,
        port: port,
        secret: secret,
        hostPort: hostPort,
        hostSecret: hostSecret,
        name: name,
        avatarPath: avatarPath,
        mediaPath: mediaPath,
        linkUrl: linkUrl,
      );
}

/// A friend's server the user got into, shown as a Recent row on the
/// Join card (one click joins).
class RecentServer {
  final String host;
  final String port;
  final String secret;
  const RecentServer({required this.host, required this.port, this.secret = ''});

  String get key => '${host.toLowerCase()}:$port';

  Map<String, Object> toJson() => {'host': host, 'port': port, 'secret': secret};

  /// Null for anything unreadable and for the hosted entries older
  /// versions kept (your server has no recents).
  static RecentServer? fromJson(Object? j) {
    if (j is! Map || j['hosted'] == true) return null;
    final host = j['host'], port = j['port'], secret = j['secret'];
    if (host is! String || port is! String) return null;
    return RecentServer(host: host, port: port, secret: secret is String ? secret : '');
  }
}

/// Newest first, one entry per server, capped at [maxRecentServers].
List<RecentServer> pushRecent(List<RecentServer> list, RecentServer s) => [
      s,
      ...list.where((r) => r.key != s.key),
    ].take(maxRecentServers).toList();

String encodeRecents(List<RecentServer> list) => jsonEncode([for (final r in list) r.toJson()]);

List<RecentServer> decodeRecents(Object? raw) {
  if (raw is! String) return const [];
  try {
    final list = jsonDecode(raw);
    if (list is! List) return const [];
    return [
      for (final j in list) ?RecentServer.fromJson(j),
    ].take(maxRecentServers).toList();
  } catch (_) {
    return const [];
  }
}

/// Before recents existed only the last form was stored: a saved remote
/// address becomes the first Recent row.
List<RecentServer> migrateRecents(
    {required bool hadForm, required String host, required String port, required String secret}) {
  final h = host.trim().toLowerCase();
  if (!hadForm || h.isEmpty || h == '127.0.0.1' || h == 'localhost') return const [];
  return [RecentServer(host: host.trim(), port: port, secret: secret)];
}

/// The connect form and the recent servers, kept in the `connect_form`
/// box. Made by the composition root; the Join card, your server (its
/// port and password), the profile and the library read and write it.
class ConnectStore {
  final form = ConnectForm();
  final recents = signal<List<RecentServer>>(const []);

  Future<void> load() async {
    final box = await openConnectFormBox();
    form
      ..host = readString(box, connectKeyHost, '127.0.0.1')
      ..port = readString(box, connectKeyPort, '8080')
      ..secret = readString(box, connectKeySecret, '');
    // Old installs had one port/password for both modes.
    form
      ..hostPort = readString(box, connectKeyHostPort, form.port)
      ..hostSecret = readString(box, connectKeyHostSecret, form.secret)
      ..name = readString(box, connectKeyName, '')
      ..avatarPath = readString(box, connectKeyAvatarPath, '')
      ..mediaPath = readString(box, connectKeyMediaPath, '')
      ..linkUrl = readString(box, connectKeyLinkUrl, '');
    recents.value = box.containsKey(connectKeyRecents)
        ? decodeRecents(box.get(connectKeyRecents))
        : migrateRecents(
            hadForm: box.containsKey(connectKeyHost), host: form.host, port: form.port, secret: form.secret);
  }

  Future<void> save() async {
    final box = connectFormBoxIfOpen() ?? await openConnectFormBox();
    await box.putAll({
      connectKeyHost: form.host,
      connectKeyPort: form.port,
      connectKeySecret: form.secret,
      connectKeyHostPort: form.hostPort,
      connectKeyHostSecret: form.hostSecret,
      connectKeyName: form.name,
      connectKeyAvatarPath: form.avatarPath,
      connectKeyMediaPath: form.mediaPath,
      connectKeyLinkUrl: form.linkUrl,
      connectKeyRecents: encodeRecents(recents.peek()),
    });
  }

  /// [save] whatever happens (a failed join is exactly when the user
  /// wants the form back); a failure is only logged.
  Future<void> saveQuietly() async {
    try {
      await save();
    } catch (e, st) {
      debugPrint('save connect form failed: $e\n$st');
    }
  }

  Future<void> remember(RecentServer server) async {
    recents.value = pushRecent(recents.peek(), server);
    await saveQuietly();
  }

  Future<void> forget(RecentServer server) async {
    recents.value = [
      for (final r in recents.peek())
        if (r.key != server.key) r,
    ];
    await saveQuietly();
  }
}
