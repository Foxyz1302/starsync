import 'dart:io';

import '../ports/url_opener.dart';

/// [UrlOpener] without url_launcher: `xdg-open`, `open` or Windows'
/// `url.dll` handler.
class DesktopUrls implements UrlOpener {
  const DesktopUrls();

  @override
  Future<bool> open(String url) async {
    try {
      final ProcessResult r;
      if (Platform.isWindows) {
        r = await Process.run('rundll32', ['url.dll,FileProtocolHandler', url]);
      } else if (Platform.isMacOS) {
        r = await Process.run('open', [url]);
      } else {
        r = await Process.run('xdg-open', [url]);
      }
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }
}
