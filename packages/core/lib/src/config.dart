import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'errors.dart';
import 'jellyfin/client_info.dart';

/// A Jellyfin login the server uses to relay the current Jellyfin media to
/// viewers without their own access (`GET /j/...`). Primitives only (it is
/// part of [AppConfig.toMap]). [client], [device], [deviceId] and [version]
/// must be the ones [token] was issued with: Jellyfin overwrites a token's
/// stored device fields with whatever the request header says.
class JellyfinCredential {
  /// Server base URL, no trailing slash needed.
  final String baseUrl;
  /// The server's `ServerId`; only refs with this id are relayed. Empty:
  /// the server looks it up at start (`/System/Info/Public`).
  final String serverId;
  final String token;
  final String client;
  final String device;
  final String deviceId;
  final String version;
  const JellyfinCredential({
    required this.baseUrl,
    this.serverId = '',
    required this.token,
    required this.client,
    required this.device,
    required this.deviceId,
    required this.version,
  });

  JellyfinClientInfo get clientInfo =>
      JellyfinClientInfo(client: client, device: device, deviceId: deviceId, version: version);

  JellyfinCredential withServerId(String id) => JellyfinCredential(
      baseUrl: baseUrl,
      serverId: id,
      token: token,
      client: client,
      device: device,
      deviceId: deviceId,
      version: version);

  /// Null when [value] is absent; throws [ConfigException] (without the
  /// values: the map holds a token) when it is not a usable credential.
  static JellyfinCredential? fromMap(Object? value) {
    if (value == null) return null;
    if (value is! Map) throw const ConfigException('jellyfin must be a map');
    String field(String key, {bool required = true}) {
      final v = value[key];
      if (v == null && !required) return '';
      if (v is! String || (required && v.trim().isEmpty)) {
        throw ConfigException('jellyfin.$key must be a non-empty string');
      }
      return v.trim();
    }

    return JellyfinCredential(
      baseUrl: field('baseUrl'),
      serverId: field('serverId', required: false),
      token: field('token'),
      client: field('client'),
      device: field('device'),
      deviceId: field('deviceId'),
      version: field('version'),
    );
  }

  Map<String, Object?> toMap() => {
        'baseUrl': baseUrl,
        'serverId': serverId,
        'token': token,
        'client': client,
        'device': device,
        'deviceId': deviceId,
        'version': version,
      };

  /// A file (YAML, or JSON by `.json` extension) holding just these keys:
  /// the dedicated server's `--jellyfin` flag, keeping the token off the
  /// command line.
  static Future<JellyfinCredential> loadFile(String path) async =>
      JellyfinCredential.fromMap(await readConfigMapFile(path))!;

  /// Never prints the token.
  @override
  String toString() => 'JellyfinCredential($baseUrl, serverId: $serverId)';
}

class AppConfig {
  final int port;
  final String secret;
  final String name;
  final String mediaPath;
  final String logLevel;
  /// Optional explicit host for file-media URLs; empty means use the host the
  /// client dialled.
  final String advertiseHost;
  /// Secret the hosting app's own client sends in hello to be marked host
  /// (unkickable). Empty means no member is the host (dedicated server).
  final String hostKey;
  /// Optional login for relaying Jellyfin media to guests; null = no relay.
  final JellyfinCredential? jellyfin;

  const AppConfig({
    required this.port,
    required this.secret,
    required this.name,
    this.mediaPath = '',
    this.logLevel = 'INFO',
    this.advertiseHost = '',
    this.hostKey = '',
    this.jellyfin,
  });

  factory AppConfig.defaults() =>
      const AppConfig(port: 8080, secret: '', name: 'server');

  factory AppConfig.fromMap(Map<String, Object?> map) {
    try {
      return AppConfig(
        port: (map['port'] as num?)?.toInt() ?? 8080,
        secret: (map['secret'] as String?) ?? '',
        name: (map['name'] as String?) ?? 'server',
        mediaPath: (map['mediaPath'] as String?) ?? '',
        logLevel: (map['logLevel'] as String?) ?? 'INFO',
        advertiseHost: (map['advertiseHost'] as String?) ?? '',
        hostKey: (map['hostKey'] as String?) ?? '',
        jellyfin: JellyfinCredential.fromMap(map['jellyfin']),
      );
    } on ConfigException {
      rethrow;
    } catch (e) {
      throw ConfigException('invalid config map: $e');
    }
  }

  Map<String, Object?> toMap() => {
        'port': port,
        'secret': secret,
        'name': name,
        'mediaPath': mediaPath,
        'logLevel': logLevel,
        'advertiseHost': advertiseHost,
        'hostKey': hostKey,
        if (jellyfin != null) 'jellyfin': jellyfin!.toMap(),
      };

  static Future<AppConfig> loadFile(String path) async =>
      AppConfig.fromMap(await readConfigMapFile(path));

  static String defaultPath(String appName) {
    final home =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '.';
    return p.join(home, '.config', appName, 'config.yaml');
  }
}

/// Reads a YAML or JSON (by `.json` extension) file whose root is a map.
/// Parse errors are reported without the source excerpt: the file may hold
/// a token.
Future<Map<String, Object?>> readConfigMapFile(String path) async {
  final file = File(path);
  if (!await file.exists()) {
    throw ConfigException('config file not found: $path');
  }
  final text = await file.readAsString();
  Object? root;
  try {
    root = path.endsWith('.json') ? jsonDecode(text) : loadYaml(text);
  } on YamlException catch (e) {
    throw ConfigException('failed to parse $path: ${e.message} (line ${(e.span?.start.line ?? -1) + 1})');
  } on FormatException catch (e) {
    throw ConfigException('failed to parse $path: ${e.message}');
  }
  if (root is! Map) throw const ConfigException('root must be a map');
  return {for (final e in root.entries) '${e.key}': e.value};
}
