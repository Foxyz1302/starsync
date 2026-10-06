import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'errors.dart';

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

  const AppConfig({
    required this.port,
    required this.secret,
    required this.name,
    this.mediaPath = '',
    this.logLevel = 'INFO',
    this.advertiseHost = '',
    this.hostKey = '',
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
      );
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
      };

  static Future<AppConfig> loadFile(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw ConfigException('config file not found: $path');
    }
    final text = await file.readAsString();
    try {
      if (path.endsWith('.json')) {
        final decoded = jsonDecode(text);
        if (decoded is! Map) throw const ConfigException('root must be a map');
        return AppConfig.fromMap(Map<String, Object?>.from(decoded));
      }
      final yamlMap = loadYaml(text);
      if (yamlMap is! YamlMap) throw const ConfigException('root must be a map');
      return AppConfig.fromMap(
          Map<String, Object?>.from(yamlMap.map((k, v) => MapEntry('$k', v))));
    } catch (e) {
      if (e is ConfigException) rethrow;
      throw ConfigException('failed to parse $path: $e');
    }
  }

  static String defaultPath(String appName) {
    final home =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '.';
    return p.join(home, '.config', appName, 'config.yaml');
  }
}
