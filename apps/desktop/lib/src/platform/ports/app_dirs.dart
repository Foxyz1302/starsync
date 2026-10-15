import 'dart:io';

/// The environment variable that picks a separate profile (DEVELOPMENT.md
/// "Dev loop": two instances on one machine).
const profileEnv = 'STARSYNC_PROFILE';

/// Where the app keeps its own files, resolved once in `main` through an
/// [AppDirsPort] and handed on from there.
///
/// Everything lives in the app support folder: Hive's boxes in
/// `<app support>/hive`, the logs in `<app support>/logs`. With
/// `STARSYNC_PROFILE=<name>` (letters, digits, `-`, `_`; at most 32) the
/// per-install data moves to `<app support>/profiles/<name>/`: the Hive
/// boxes (settings and so the profile, connect form, window bounds,
/// folders, Jellyfin sign-ins; the client id from restructure step 1 on)
/// under `hive/`, the logs under `logs/`. Downloads and caches stay
/// shared: yt-dlp and its cookies, the extracted shaders, thumbnails, the
/// AniList cache.
class AppDirs {
  /// The profile name; null for the normal app.
  final String? profile;
  /// The app support folder (yt-dlp, shaders; Hive and logs without a
  /// profile).
  final String support;
  /// Hive's folder.
  final String hive;
  /// The app's log folder.
  final String logs;
  /// What resolving copied over from before the rename, one line each
  /// (paths and counts), for the log once it is open.
  final List<String> migrated;

  const AppDirs(
      {required this.profile,
      required this.support,
      required this.hive,
      required this.logs,
      this.migrated = const []});

  /// The layout for [support] (the app support folder) and [env]; an
  /// invalid profile name is ignored ([invalidProfile] says which).
  static AppDirs fromEnv(
      {required String support, required Map<String, String> env, List<String> migrated = const []}) {
    final sep = Platform.pathSeparator;
    final name = validProfile(env[profileEnv]);
    final root = name == null ? support : '$support${sep}profiles$sep$name';
    return AppDirs(
        profile: name, support: support, hive: '$root${sep}hive', logs: '$root${sep}logs', migrated: migrated);
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
}

/// Finds the app's folders on this platform (and, the first time, brings
/// over the data of the names before the rename).
abstract interface class AppDirsPort {
  /// The layout for this process; its Hive folder exists afterwards.
  Future<AppDirs> resolve();
}
