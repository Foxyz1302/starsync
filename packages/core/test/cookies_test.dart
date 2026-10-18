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

  test('kept sites become a private file yt-dlp is pointed at', () async {
    final dir = await Directory.systemTemp.createTemp('cookies_test');
    addTearDown(() => dir.delete(recursive: true));
    final src = File('${dir.path}/export.json')..writeAsStringSync(_json);
    final y = YtDlp('${dir.path}/yt-dlp, a=b');
    expect(y.resolveArgs('U'), ['-J', '--no-playlist', '--no-warnings', '--ignore-config', '-f', playFormat, '--write-subs', '--sub-langs', playSubLangs, '--', 'U']);

    final kept = await y.cookies.import(src.path, sites: {'bilibili.com'});
    expect([kept.count, ...kept.sites], [1, 'bilibili.com']);
    final path = y.cookies.filePath;
    expect(y.resolveArgs('U'), ['-J', '--no-playlist', '--no-warnings', '--ignore-config', '-f', playFormat, '--write-subs', '--sub-langs', playSubLangs, '--cookies', path, '--', 'U']);
    if (!Platform.isWindows) expect(File(path).statSync().modeString(), 'rw-------');

    await y.cookies.saveBrowser('firefox', 'work');
    expect(y.resolveArgs('U').sublist(9, 11), ['--cookies-from-browser', 'firefox:work']);
    expect(File(path).existsSync(), isFalse);

    await y.cookies.remove();
    expect(y.cookies.read(), isNull);
  });

  // D11: a sign-in error says which cookies were used and what they hold
  // for the site.
  group('cookie notes', () {
    test('the texts', () {
      expect(cookieNoteText(null, 'bilibili.com', -1), 'no cookies were used');
      const file = CookieFile('/x', 3, ['youtube.com']);
      expect(cookieNoteText(file, 'bilibili.com', 0), 'used the cookies file, which has none for bilibili.com');
      expect(cookieNoteText(file, 'bilibili.com', 4),
          'used the cookies file (4 for bilibili.com: signed out or expired?)');
      const ff = CookieBrowser('firefox', 'work');
      expect(cookieNoteText(ff, 'bilibili.com', -1, read: (count: 0, error: null)),
          "used Firefox (work)'s cookies, which have none for bilibili.com: sign in to bilibili.com there");
      expect(cookieNoteText(ff, 'bilibili.com', -1, read: (count: 12, error: null)),
          "used Firefox (work)'s cookies (12 for bilibili.com: that account may not see it)");
      expect(cookieNoteText(const CookieBrowser('chrome'), 'x.com', -1, read: (count: -1, error: 'locked')),
          "used Chrome's cookies, but yt-dlp couldn't read them: locked");
      expect(withCookieNote(noFormatsText, 'no cookies were used'),
          'No video found: it may need signing in (no cookies were used)');
      expect(withCookieNote(needsCookiesText, 'x'), 'This site needs cookies (x) — Settings → Library & accounts → Web links → Cookies');
      expect(withCookieNote(notFoundText, 'x'), notFoundText);
      expect(mayNeedSignIn('No video formats found!'), isTrue);
      expect(mayNeedSignIn('HTTP Error 404'), isFalse);
    });

    test("a failed resolve names the file's cookies for the site; a browser's are counted by yt-dlp",
        () async {
      final dir = await Directory.systemTemp.createTemp('cookie_note');
      addTearDown(() => dir.delete(recursive: true));
      // A stand-in yt-dlp: a version, a resolve that finds no formats, and
      // the browser read (no URL) that writes the jar it is given.
      final fake = File('${dir.path}/yt-dlp');
      await fake.writeAsString(r'''#!/bin/sh
case "$1" in --version) echo 2099.01.01; exit 0;; esac
jar=""; prev=""
for a in "$@"; do [ "$prev" = "--cookies" ] && jar="$a"; prev="$a"; done
case "$*" in *-J*) echo "ERROR: [BiliBili] BV1: No video formats found!" >&2; exit 1;; esac
printf '# Netscape HTTP Cookie File\n.bilibili.com\tTRUE\t/\tTRUE\t2000000000\tSESSDATA\tx\n.bilibili.com\tTRUE\t/\tFALSE\t2000000000\tbuvid3\ty\n.other.org\tTRUE\t/\tFALSE\t0\ta\tb\n' > "$jar"
echo "Extracted 3 cookies from firefox" >&2
echo "yt-dlp: error: You must provide at least one URL." >&2; exit 2
''');
      await Process.run('chmod', ['+x', fake.path]);
      final y = YtDlp(dir.path, updateEvery: const Duration(days: 9999));
      await File('${dir.path}/last-check').writeAsString(DateTime.now().toIso8601String());
      const page = 'https://www.bilibili.com/video/BV1';

      Future<YtDlpException> fail() async {
        try {
          await y.resolve(page);
        } on YtDlpException catch (e) {
          return e;
        }
        throw StateError('resolved');
      }

      expect((await fail()).cookies, 'no cookies were used');
      await y.cookies.saveFile(parseCookies('.youtube.com\tTRUE\t/\tFALSE\t0\tSID\tv\n'));
      expect((await fail()).cookies, 'used the cookies file, which has none for bilibili.com');
      await y.cookies.saveBrowser('firefox');
      final e = await fail();
      expect(e.message, contains('No video formats found'));
      expect(e.cookies, "used Firefox's cookies (2 for bilibili.com: that account may not see it)");
      expect(dir.listSync().map((f) => f.path).where((p) => p.contains('cookie-check')), isEmpty,
          reason: 'the browser jar is deleted at once');
      // The probe carries it into the plain words.
      expect(LinkProbe.page(Uri.parse(page), ytDlpError: e.message, cookies: e.cookies).problem,
          "No video found: it may need signing in (used Firefox's cookies (2 for bilibili.com: that account may not see it))");
    }, skip: Platform.isWindows ? 'the stand-in yt-dlp is a shell script' : false);
  });
}
