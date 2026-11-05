import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:sync_relay_core/core.dart' show findInstallRoot;

import '../session/invite.dart' show inviteScheme;
import 'desktop/windows_api.dart';

/// The MIME type desktops look up for a `starsync://` link (Linux).
const schemeMimeType = 'x-scheme-handler/$inviteScheme';

/// HKCU\Software\Classes\starsync: what Windows opens a link with.
const windowsSchemeKey = r'Software\Classes\' + inviteScheme;

/// The binary a link should start: `starsync.exe` next to an old-named
/// copy (`watch_together.exe`, the name up to 1.2.x: a 1.4.x update leaves
/// it until the updater's sweep removes it, and an old shortcut may start
/// it until then) when it is there, so links always start the current name.
String schemeExecutable(String exe, {bool Function(String path)? exists}) {
  final has = exists ?? (p) => File(p).existsSync();
  final sep = exe.contains(r'\') ? r'\' : '/';
  final cut = exe.lastIndexOf(sep);
  final name = exe.substring(cut + 1).toLowerCase();
  if (name != 'watch_together.exe' && name != 'watch_together') return exe;
  final current = '${exe.substring(0, cut + 1)}starsync${name.endsWith('.exe') ? '.exe' : ''}';
  return has(current) ? current : exe;
}

/// The registry values of the Windows link handler for [exe]: (key under
/// HKEY_CURRENT_USER, value name ('' = default), data).
List<(String, String, String)> windowsSchemeValues(String exe) => [
      (windowsSchemeKey, '', 'URL:Starsync invite'),
      (windowsSchemeKey, 'URL Protocol', ''),
      ('$windowsSchemeKey\\DefaultIcon', '', '"$exe",0'),
      ('$windowsSchemeKey\\shell\\open\\command', '', '"$exe" "%1"'),
    ];

/// Windows: makes `starsync://` links start this install (per user, no
/// admin: HKCU\Software\Classes), only when the command there is not this
/// one already (first start, a moved install, an update from an old
/// name). Release installs only (never a debug run); failures only log.
Future<void> registerWindowsScheme({String? executable}) async {
  if (!Platform.isWindows || kDebugMode) return;
  try {
    final exe = schemeExecutable(executable ?? Platform.resolvedExecutable);
    if (findInstallRoot(exe, windows: true) == null) return;
    final values = windowsSchemeValues(exe);
    final command = values.last;
    if (readUserRegistryString(command.$1, command.$2) == command.$3) return;
    for (final (key, name, data) in values) {
      if (!writeUserRegistryString(key, name, data)) {
        debugPrint('url scheme: cannot write HKCU\\$key');
        return;
      }
    }
    debugPrint('url scheme: starsync:// links open $exe');
  } catch (e) {
    debugPrint('url scheme: $e');
  }
}

/// Linux: makes this app the default for [schemeMimeType] (xdg-mime,
/// `~/.config/mimeapps.list`) unless it already is. [desktopFile]: the
/// launcher entry's file name, which lists the type.
Future<void> registerLinuxScheme(String desktopFile, String applicationsDir) async {
  try {
    final q = await Process.run('xdg-mime', ['query', 'default', schemeMimeType]);
    if (q.exitCode == 0 && '${q.stdout}'.trim() == desktopFile) return;
    final r = await Process.run('xdg-mime', ['default', desktopFile, schemeMimeType]);
    if (r.exitCode != 0) {
      debugPrint('url scheme: xdg-mime default failed: ${'${r.stderr}'.trim()}');
      return;
    }
    // The MIME cache some desktops read (missing on some systems: fine).
    try {
      await Process.run('update-desktop-database', ['-q', applicationsDir]);
    } catch (_) {}
    debugPrint('url scheme: starsync:// links open $desktopFile');
  } catch (e) {
    debugPrint('url scheme: $e');
  }
}
