import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:sync_relay_core/core.dart';

import '../screens/home/ui.dart' show appName, displayVersion;
import 'ports/app_dirs.dart';
import '../app/app_graph.dart';

// The app's log on disk (<app support>/logs/app-YYYY-MM-DD.log; core's
// logging.dart writes, rotates and redacts it), debugPrint routed into it,
// and the "Copy diagnostics" text of Settings → About.

final _appLog = createLogger('app');

/// The logs folder, once [startAppLogging] ran.
String? appLogDir;

/// Opens the log files in [dirs]' log folder and routes `debugPrint` and
/// uncaught errors into the log.
Future<void> startAppLogging(AppDirs dirs) async {
  try {
    if (startLogFiles(dirs.logs) != null) appLogDir = dirs.logs;
  } catch (e) {
    _appLog.warning('no log files: $e');
  }
  // Everything the app prints for diagnosis lands in the file too (the
  // log's console output replaces the print).
  debugPrint = (String? message, {int? wrapWidth}) {
    if (message == null || message.isEmpty) return;
    final bad = RegExp(r'fail|error|crash|exception', caseSensitive: false).hasMatch(message);
    bad ? _appLog.warning(message) : _appLog.info(message);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    _appLog.severe('uncaught: $error', error, stack);
    return false;
  };
  _appLog.info('$appName ${displayVersion()} on ${Platform.operatingSystem} '
      '${Platform.operatingSystemVersion}, pid $pid, Dart ${Platform.version.split(' ').first}'
      '${dirs.profile == null ? '' : ', profile ${dirs.profile}'}');
  for (final line in dirs.migrated) {
    _appLog.info(line);
  }
  final bad = AppDirs.invalidProfile(Platform.environment);
  if (bad != null) _appLog.warning('$profileEnv="$bad" ignored: use letters, digits, - and _ (at most 32)');
}

/// The text "Copy diagnostics" gives: versions, then the last [since] of
/// the app log (its hosted server's records included), already redacted;
/// with [sessionLog], the server's session log of the same hours after it
/// (every member's shared lines and the server's, merged).
Future<String> diagnosticsText(AppGraph graph, {Duration since = const Duration(hours: 6), bool sessionLog = false}) async {
  final b = StringBuffer()
    ..writeln('$appName ${displayVersion()}')
    ..writeln('OS: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}')
    ..writeln('Dart: ${Platform.version.split(' ').first}');
  try {
    final mpv = await graph.coordinator.playback.mpvVersion().timeout(const Duration(seconds: 2));
    b.writeln('mpv: ${mpv ?? 'no player yet'}');
  } catch (_) {
    b.writeln('mpv: unknown');
  }
  try {
    final y = await graph.ports.links.ytDlp.timeout(const Duration(seconds: 2));
    final cookies = y.cookies.read(count: false);
    b.writeln('yt-dlp: ${y.version ?? 'not ready'}${y.lastError == null ? '' : ' (${y.lastError})'}, '
        'cookies: ${cookies == null ? 'none' : 'set'}');
  } catch (_) {
    b.writeln('yt-dlp: unknown');
  }
  final files = logFiles;
  b.writeln('Log: ${files?.currentPath ?? 'none (console only)'}');
  b.writeln('--- last ${since.inHours} h of the log ---');
  b.write(files?.recent(since) ?? '');
  if (sessionLog) {
    final server = await graph.coordinator.sessionLog(hours: since.inHours);
    b
      ..writeln()
      ..writeln("--- last ${since.inHours} h of the server's session log ---")
      ..write(server ?? "(none: the server keeps no session log, or it couldn't be reached)");
  }
  return redactLog(b.toString());
}

/// Saves [text] next to the logs as `diagnostics-<time>.txt`; its path,
/// or null when it could not be written.
Future<String?> saveDiagnostics(String text) async {
  final dir = appLogDir;
  if (dir == null) return null;
  final t = DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  final path = '$dir${Platform.pathSeparator}diagnostics-${t.year}${two(t.month)}${two(t.day)}-'
      '${two(t.hour)}${two(t.minute)}${two(t.second)}.txt';
  try {
    // Older ones go after the log files' week.
    for (final e in Directory(dir).listSync()) {
      if (e is File &&
          e.uri.pathSegments.last.startsWith('diagnostics-') &&
          t.difference(e.statSync().modified) > const Duration(days: 7)) {
        e.deleteSync();
      }
    }
    await File(path).writeAsString(text);
    return path;
  } catch (e) {
    _appLog.warning('cannot save diagnostics: $e');
    return null;
  }
}
