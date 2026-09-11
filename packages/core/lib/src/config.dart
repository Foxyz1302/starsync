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
  final String advertiseHost;

  const AppConfig({
    required this.port,
    required this.secret,
    required this.name,
    this.mediaPath = '',
    this.logLevel = 'INFO',
    this.advertiseHost = '127.0.0.1',
  });

  factory AppConfig.defaults() =>
      const AppConfig(port: 8080, secret: 'change-me', name: 'room');

  factory AppConfig.fromMap(Map<String, Object?> map) {
    try {
      return AppConfig(
        port: (map['port'] as num?)?.toInt() ?? 8080,
        secret: (map['secret'] as String?) ?? 'change-me',
        name: (map['name'] as String?) ?? 'room',
        mediaPath: (map['mediaPath'] as String?) ?? '',
        logLevel: (map['logLevel'] as String?) ?? 'INFO',
        advertiseHost: (map['advertiseHost'] as String?) ?? '127.0.0.1',
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
