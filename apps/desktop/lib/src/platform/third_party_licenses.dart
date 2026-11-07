import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:sync_relay_core/core.dart' show starsyncNotices;

/// Adds Starsync's own entries (mpv and FFmpeg, on Windows ANGLE and its
/// companions, Anime4K, the uosc credit) to the license page that
/// Settings → Help & about → Open-source licenses opens. Read only when
/// the page asks.
void registerThirdPartyLicenses() {
  LicenseRegistry.addLicense(() async* {
    final windows = Platform.isWindows;
    final notices = await starsyncNotices(
      windows: windows,
      asset: (path) async {
        try {
          return await rootBundle.loadString(path, cache: false);
        } catch (_) {
          return null;
        }
      },
      libmpvLicenses: windows ? await _besideExe('libmpv-licenses.txt') : null,
    );
    for (final n in notices) {
      yield LicenseEntryWithLineBreaks(n.packages, n.text);
    }
  });
}

/// A text file next to the executable, or null.
Future<String?> _besideExe(String name) async {
  try {
    final file = File('${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}$name');
    return await file.exists() ? utf8.decode(await file.readAsBytes(), allowMalformed: true) : null;
  } catch (_) {
    return null;
  }
}
