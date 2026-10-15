import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// The environment variable that picks a separate profile (DEVELOPMENT.md
/// "Dev loop": two instances on one machine).
const profileEnv = 'STARSYNC_PROFILE';

/// Where the app keeps its own files, resolved once in `main` ([resolve])
/// and handed on from there.
///
/// Without a profile it is exactly today's layout: Hive's boxes in Hive's
/// default folder (the documents folder) and the logs in
/// `<app support>/logs`. With `STARSYNC_PROFILE=<name>` (letters, digits,
/// `-`, `_`; at most 32) the per-install data moves to
/// `<app support>/profiles/<name>/`: the Hive boxes (settings and so the
/// profile, connect form, window bounds, folders, Jellyfin sign-ins; the
/// client id from restructure step 1 on) under `hive/`, the logs under
/// `logs/`. Downloads and caches stay shared: yt-dlp and its cookies, the
/// extracted shaders, thumbnails, the AniList cache.
class AppDirs {
  /// The profile name; null for the normal app.
  final String? profile;
  /// The app support folder (yt-dlp, shaders; logs without a profile).
  final String support;
  /// Hive's folder; null: Hive's default (`Hive.initFlutter()`).
  final String? hive;
  /// The app's log folder.
  final String logs;

  const AppDirs({required this.profile, required this.support, required this.hive, required this.logs});

  /// The layout for [support] (the app support folder) and [env]; an
  /// invalid profile name is ignored ([invalidProfile] says which).
  static AppDirs fromEnv({required String support, required Map<String, String> env}) {
    final sep = Platform.pathSeparator;
    final name = validProfile(env[profileEnv]);
    if (name == null) return AppDirs(profile: null, support: support, hive: null, logs: '$support${sep}logs');
    final root = '$support${sep}profiles$sep$name';
    return AppDirs(profile: name, support: support, hive: '$root${sep}hive', logs: '$root${sep}logs');
  }

  /// [raw] when it is a usable profile name, else null.
  static String? validProfile(String? raw) {
    final v = raw?.trim() ?? '';
    return RegExp(r'^[A-Za-z0-9_-]{1,32}$').hasMatch(v) ? v : null;
  }

  /// The env value when it is set but not a usable name (for a warning).
  static String? invalidProfile(Map<String, String> env) {
    final raw = env[profileEnv];
    return raw != null && raw.trim().isNotEmpty && validProfile(raw) == null ? raw : null;
  }

  /// Resolves the layout from the platform and the process environment.
  /// Needs Flutter's binding (path_provider).
  static Future<AppDirs> resolve() async {
    final support = (await getApplicationSupportDirectory()).path;
    final dirs = fromEnv(support: support, env: Platform.environment);
    final hive = dirs.hive;
    if (hive != null) await Directory(hive).create(recursive: true);
    return dirs;
  }
}
