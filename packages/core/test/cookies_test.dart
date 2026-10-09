// yt-dlp cookies: the JSON export -> Netscape conversion, the per-site
// filter, and what yt-dlp and mpv are given. Synthetic cookies only.
library;

import 'dart:io';

import 'package:sync_relay_core/core.dart';
import 'package:test/test.dart';

const _json = '''[
  {"domain": ".bilibili.com", "name": "SESSDATA", "value": "s1", "path": "/", "expirationDate": 1893456000.5,
   "hostOnly": false, "httpOnly": true, "secure": true, "session": false},
  {"domain": "www.youtube.com", "name": "PREF", "value": "a=b", "hostOnly": true, "session": true},
  {"domain": "accounts.google.com", "name": "SID", "value": "g", "expires": 1893456000},
  {"domain": ".example.co.uk", "name": "x", "value": "y", "path": "/p"}
]''';

void main() {
  test('JSON export converts to Netscape lines, grouped by site', () {
    final cookies = parseCookies(_json);
    expect(cookies.map((c) => c.toLine()), [
      '#HttpOnly_.bilibili.com\tTRUE\t/\tTRUE\t1893456000\tSESSDATA\ts1',
      'www.youtube.com\tFALSE\t/\tFALSE\t0\tPREF\ta=b',
      '.accounts.google.com\tTRUE\t/\tFALSE\t1893456000\tSID\tg',
      '.example.co.uk\tTRUE\t/p\tFALSE\t0\tx\ty',
    ]);
    expect(cookiesBySite(cookies).keys, ['bilibili.com', 'example.co.uk', 'youtube.com']);
    // Netscape text reads back the same.
    final again = parseCookies(netscapeCookiesText(cookies));
    expect(again.map((c) => c.toLine()), cookies.map((c) => c.toLine()));
  });

  test('kept sites become a private file yt-dlp and mpv are pointed at', () async {
    final dir = await Directory.systemTemp.createTemp('cookies_test');
    addTearDown(() => dir.delete(recursive: true));
    final src = File('${dir.path}/export.json')..writeAsStringSync(_json);
    final y = YtDlp('${dir.path}/yt-dlp, a=b');
    expect(y.resolveArgs('U'), ['-J', '--no-playlist', '--no-warnings', '--ignore-config', '--', 'U']);

    final kept = await y.cookies.import(src.path, sites: {'bilibili.com'});
    expect([kept.count, ...kept.sites], [1, 'bilibili.com']);
    final path = y.cookies.filePath;
    expect(y.resolveArgs('U'), ['-J', '--no-playlist', '--no-warnings', '--ignore-config', '--cookies', path, '--', 'U']);
    expect(y.cookies.mpvRawOptions(), 'cookies=%${path.length}%$path');
    if (!Platform.isWindows) expect(File(path).statSync().modeString(), 'rw-------');

    await y.cookies.saveBrowser('firefox', 'work');
    expect(y.resolveArgs('U').sublist(4, 6), ['--cookies-from-browser', 'firefox:work']);
    expect(File(path).existsSync(), isFalse);
    expect(y.cookies.mpvRawOptions(), 'cookies-from-browser=%12%firefox:work');

    await y.cookies.remove();
    expect(y.cookies.read(), isNull);
  });
}
