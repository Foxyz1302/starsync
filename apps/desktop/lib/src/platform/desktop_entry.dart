import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:sync_relay_core/core.dart' show findInstallRoot;

/// The app's id: GTK's application id, so the Wayland `app_id` the
/// compositor matches to [desktopFileName] for the window's icon.
const appId = 'dev.foxyz.starsync';
const desktopFileName = '$appId.desktop';

/// The app id up to 1.2.x: its entry and icons are removed (only those
/// exact files, which that version wrote).
const legacyAppId = 'moe.senkochan.watch_together';

const _iconSizes = [16, 32, 48, 64, 128, 256, 512];

/// Linux release installs (an unpacked tarball) carry no launcher entry, so
/// Wayland shows a generic icon. On start: write the `.desktop` file into
/// `~/.local/share/applications` (Exec = this binary) and the icon into
/// the hicolor theme, only when something changed (a moved install, a new
/// icon). The entry and icons of [legacyAppId] go. Never in debug runs
/// (unless [force], for tests); failures only log.
Future<void> installDesktopEntry(
    {String? executable, String? dataHome, String? home, @visibleForTesting bool force = false}) async {
  if (!Platform.isLinux || (kDebugMode && !force)) return;
  try {
    final exe = executable ?? Platform.resolvedExecutable;
    final root = findInstallRoot(exe, windows: false);
    if (root == null) return;
    final share = dataHome ?? Platform.environment['XDG_DATA_HOME'] ??
        '${home ?? Platform.environment['HOME']}/.local/share';
    final icons = '${root.path}/data/flutter_assets/assets/icon';
    await _removeLegacy(share);
    for (final size in _iconSizes) {
      final src = File('$icons/icon_$size.png');
      if (!src.existsSync()) continue;
      final dst = File('$share/icons/hicolor/${size}x$size/apps/$appId.png');
      if (dst.existsSync() && dst.lengthSync() == src.lengthSync()) continue;
      await dst.parent.create(recursive: true);
      await src.copy(dst.path);
    }
    final entry = desktopEntryText(exe);
    final file = File('$share/applications/$desktopFileName');
    if (file.existsSync() && file.readAsStringSync() == entry) return;
    await file.parent.create(recursive: true);
    await file.writeAsString(entry);
  } catch (e) {
    debugPrint('desktop entry: $e');
  }
}

Future<void> _removeLegacy(String share) async {
  for (final f in [
    File('$share/applications/$legacyAppId.desktop'),
    for (final size in _iconSizes) File('$share/icons/hicolor/${size}x$size/apps/$legacyAppId.png'),
  ]) {
    if (!f.existsSync()) continue;
    try {
      await f.delete();
      debugPrint('desktop entry: removed ${f.path}');
    } catch (e) {
      debugPrint('desktop entry: cannot remove ${f.path}: $e');
    }
  }
}

@visibleForTesting
String desktopEntryText(String exe) => '''[Desktop Entry]
Type=Application
Name=Starsync
Comment=Watch videos in sync with friends
Exec="$exe"
Icon=$appId
StartupWMClass=$appId
Categories=AudioVideo;Video;Player;Network;
Terminal=false
''';
