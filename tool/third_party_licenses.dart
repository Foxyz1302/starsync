// Writes THIRD_PARTY_LICENSES.txt for a release archive from the built
// bundle: Starsync's own notices for the platform (mpv and FFmpeg, on
// Windows ANGLE and its companions, Anime4K, the uosc credit:
// packages/core/lib/src/third_party.dart, the same list the app's
// license page shows), then Flutter's NOTICES (every Dart package and
// the engine), in NOTICES' format.
// Usage: dart tool/third_party_licenses.dart <linux|windows> <bundle dir> <out file>
// The bundle dir holds the app's executable and data/ (on Windows also
// libmpv-licenses.txt). tool/package_linux.sh and tool/package_windows.ps1
// run it.
import 'dart:convert';
import 'dart:io';

import 'package:sync_relay_core/core.dart' show anime4kLicenseAsset, starsyncNotices, windowsGraphicsLicenseAssets;

/// NOTICES' entry separator.
final _rule = '-' * 80;

Future<void> main(List<String> args) async {
  if (args.length != 3 || !const ['linux', 'windows'].contains(args[0])) {
    stderr.writeln('usage: dart tool/third_party_licenses.dart <linux|windows> <bundle dir> <out file>');
    exit(64);
  }
  final windows = args[0] == 'windows';
  final bundle = args[1];
  final assets = '$bundle/data/flutter_assets';
  final notices = File('$assets/NOTICES.Z');
  if (!notices.existsSync()) {
    stderr.writeln('error: ${notices.path} missing (build first)');
    exit(1);
  }
  String? read(String path) {
    final f = File(path);
    return f.existsSync() ? utf8.decode(f.readAsBytesSync(), allowMalformed: true) : null;
  }

  final libmpv = windows ? read('$bundle/libmpv-licenses.txt') : null;
  if (windows && libmpv == null) {
    stderr.writeln('error: $bundle/libmpv-licenses.txt missing (the media_kit fork writes it)');
    exit(1);
  }
  for (final path in [anime4kLicenseAsset, if (windows) ...windowsGraphicsLicenseAssets.values]) {
    if (!File('$assets/$path').existsSync()) {
      stderr.writeln('error: $assets/$path missing (an asset of the app, apps/desktop/pubspec.yaml)');
      exit(1);
    }
  }
  final ours = await starsyncNotices(windows: windows, asset: (p) async => read('$assets/$p'), libmpvLicenses: libmpv);
  final flutter = utf8.decode(gzip.decode(notices.readAsBytesSync()), allowMalformed: true).trim();
  final out = StringBuffer()
    ..writeln('Starsync is MIT-licensed (LICENSE beside this file). It is built on the software')
    ..writeln('below; each entry names it and gives its license.')
    ..writeln(_rule);
  for (final n in ours) {
    out
      ..writeln(n.packages.join('\n'))
      ..writeln()
      ..writeln(n.text.trim())
      ..writeln(_rule);
  }
  out.writeln(flutter);
  File(args[2]).writeAsStringSync(out.toString());
  stdout.writeln('wrote ${args[2]} (${ours.length} Starsync entries + Flutter NOTICES)');
}
