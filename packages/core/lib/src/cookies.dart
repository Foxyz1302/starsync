import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

// Cookies for yt-dlp: some sites refuse guests (Bilibili answers HTTP 412,
// YouTube may ask to sign in). A machine's yt-dlp folder holds at most one
// source: a private Netscape cookies.txt (mode 0600) or the name of a
// browser to read them from. They only ever go to this machine's yt-dlp;
// values are never logged or sent anywhere.

/// One cookie, as a line of a Netscape cookies.txt.
class NetscapeCookie {
  /// With a leading '.' when [includeSubdomains].
  final String domain;
  final bool includeSubdomains;
  final String path;
  final bool secure;
  /// Unix seconds; 0 for a session cookie.
  final int expires;
  final String name;
  final String value;
  final bool httpOnly;
  const NetscapeCookie({
    required this.domain,
    this.includeSubdomains = true,
    this.path = '/',
    this.secure = false,
    this.expires = 0,
    required this.name,
    required this.value,
    this.httpOnly = false,
  });

  /// The host without a leading '.', lowercase.
  String get host => (domain.startsWith('.') ? domain.substring(1) : domain).toLowerCase();

  String toLine() => [
        '${httpOnly ? '#HttpOnly_' : ''}$domain',
        includeSubdomains ? 'TRUE' : 'FALSE',
        path,
        secure ? 'TRUE' : 'FALSE',
        '$expires',
        name,
        value,
      ].join('\t');
}

/// Reads a Netscape cookies.txt or the JSON array browser extensions
/// export (Cookie-Editor, "Get cookies.txt" style: objects with name,
/// value, domain, path, expirationDate or expires, httpOnly, secure,
/// hostOnly, session; also `{"cookies": [...]}`). Throws [FormatException]
/// without quoting the input (it holds logins).
List<NetscapeCookie> parseCookies(String text) {
  final t = text.trimLeft();
  if (t.startsWith('[') || t.startsWith('{')) return _fromJson(t);
  final out = <NetscapeCookie>[];
  for (var line in const LineSplitter().convert(text)) {
    var httpOnly = false;
    if (line.startsWith('#HttpOnly_')) {
      httpOnly = true;
      line = line.substring('#HttpOnly_'.length);
    } else if (line.startsWith('#') || line.trim().isEmpty) {
      continue;
    }
    final f = line.split('\t');
    if (f.length < 7) continue;
    out.add(NetscapeCookie(
      domain: f[0],
      includeSubdomains: f[1].toUpperCase() == 'TRUE',
      path: f[2],
      secure: f[3].toUpperCase() == 'TRUE',
      expires: int.tryParse(f[4]) ?? double.tryParse(f[4])?.toInt() ?? 0,
      name: f[5],
      value: f.sublist(6).join('\t'),
      httpOnly: httpOnly,
    ));
  }
  if (out.isEmpty) throw const FormatException('no cookies found (expected a cookies.txt or a JSON export)');
  return out;
}

List<NetscapeCookie> _fromJson(String text) {
  Object? root;
  try {
    root = jsonDecode(text);
  } on FormatException {
    throw const FormatException('not valid JSON');
  }
  if (root is Map && root['cookies'] is List) root = root['cookies'];
  if (root is! List) throw const FormatException('expected a JSON array of cookies');
  final out = <NetscapeCookie>[];
  for (final c in root) {
    if (c is! Map) continue;
    final name = c['name'], value = c['value'], domain = c['domain'];
    if (name is! String || value is! String || domain is! String || domain.isEmpty) continue;
    final hostOnly = c['hostOnly'] == true;
    final exp = c['expirationDate'] ?? c['expires'] ?? c['expiry'];
    final session = c['session'] == true || exp is! num || exp <= 0;
    final path = c['path'];
    out.add(NetscapeCookie(
      domain: hostOnly ? (domain.startsWith('.') ? domain.substring(1) : domain) : (domain.startsWith('.') ? domain : '.$domain'),
      includeSubdomains: !hostOnly,
      path: path is String && path.isNotEmpty ? path : '/',
      secure: c['secure'] == true,
      expires: session ? 0 : exp.toInt(),
      name: name,
      value: value,
      httpOnly: c['httpOnly'] == true,
    ));
  }
  if (out.isEmpty) throw const FormatException('no cookies found in the JSON');
  return out;
}

/// [cookies] as a Netscape cookies.txt (what yt-dlp's `--cookies` reads).
String netscapeCookiesText(Iterable<NetscapeCookie> cookies) => [
      '# Netscape HTTP Cookie File',
      '# Written by Starsync for yt-dlp. Holds logins: keep it private.',
      '',
      for (final c in cookies) c.toLine(),
      '',
    ].join('\n');

// Second-level labels under which a country code needs a third label
// (bbc.co.uk, example.com.cn).
const _secondLevel = {'co', 'com', 'net', 'org', 'ac', 'gov', 'edu', 'ne', 'or', 'go'};

// Domains one login spans, filed under one site.
const _siteAlias = {
  'google.com': 'youtube.com',
  'youtu.be': 'youtube.com',
  'hdslb.com': 'bilibili.com',
  'bilivideo.com': 'bilibili.com',
  'biliapi.net': 'bilibili.com',
  'b23.tv': 'bilibili.com',
  'x.com': 'twitter.com',
};

/// The registrable domain of [host] (`www.bilibili.com` -> `bilibili.com`,
/// `a.bbc.co.uk` -> `bbc.co.uk`), by a short rule rather than the full
/// public suffix list.
String registrableDomain(String host) {
  final labels = host.toLowerCase().replaceFirst(RegExp(r'^\.+'), '').split('.').where((l) => l.isNotEmpty).toList();
  if (labels.length <= 2) return labels.join('.');
  final n = labels.length;
  final keep = labels[n - 1].length == 2 && _secondLevel.contains(labels[n - 2]) ? 3 : 2;
  return labels.sublist(n - keep).join('.');
}

/// The site a cookie of [host] belongs to: its registrable domain, with the
/// domains one login spans folded together (google.com under youtube.com).
String cookieSite(String host) {
  final d = registrableDomain(host);
  return _siteAlias[d] ?? d;
}

/// [cookies] grouped by [cookieSite], sites sorted by name.
Map<String, List<NetscapeCookie>> cookiesBySite(Iterable<NetscapeCookie> cookies) {
  final m = <String, List<NetscapeCookie>>{};
  for (final c in cookies) {
    m.putIfAbsent(cookieSite(c.host), () => []).add(c);
  }
  return {for (final k in m.keys.toList()..sort()) k: m[k]!};
}

/// [parseCookies], or none for a file without any.
List<NetscapeCookie> parseCookiesOrEmpty(String text) {
  try {
    return parseCookies(text);
  } on FormatException {
    return const [];
  }
}

/// "Firefox", "Chrome", "Firefox (work)": a browser and its profile.
String browserLabel(CookieBrowser b) {
  final name = b.browser.isEmpty ? b.browser : '${b.browser[0].toUpperCase()}${b.browser.substring(1)}';
  return b.profile.isEmpty ? name : '$name (${b.profile})';
}

/// The cookies part of a sign-in error (D11): which cookies were used and
/// how many of them are for [site] ([count] -1: unknown; [read]: what
/// reading a browser's gave).
String cookieNoteText(CookieSource? source, String site, int count, {({int count, String? error})? read}) {
  switch (source) {
    case null:
      return 'no cookies were used';
    case CookieFile():
      if (count < 0) return 'used the cookies file';
      return count == 0
          ? 'used the cookies file, which has none for $site'
          : 'used the cookies file ($count for $site: signed out or expired?)';
    case CookieBrowser():
      final who = "${browserLabel(source)}'s cookies";
      final error = read?.error;
      if (error != null) return "used $who, but yt-dlp couldn't read them: $error";
      final n = read?.count ?? count;
      if (n < 0) return 'used $who';
      return n == 0
          ? 'used $who, which have none for $site: sign in to $site there'
          : 'used $who ($n for $site: that account may not see it)';
  }
}

/// Sites ticked by default after an import: those yt-dlp is usually given
/// cookies for.
const suggestedCookieSites = {'bilibili.com', 'youtube.com'};

/// Browsers `--cookies-from-browser` reads.
const cookieBrowsers = ['firefox', 'chrome', 'chromium', 'brave', 'edge', 'opera', 'vivaldi'];

/// Where a machine's yt-dlp gets cookies: a private file or a browser.
sealed class CookieSource {
  const CookieSource();
}

/// [path] is the private copy in the yt-dlp folder.
class CookieFile extends CookieSource {
  final String path;
  final int count;
  /// [cookieSite]s in it, sorted.
  final List<String> sites;
  const CookieFile(this.path, this.count, this.sites);
}

class CookieBrowser extends CookieSource {
  final String browser;
  /// Empty: the browser's default profile.
  final String profile;
  const CookieBrowser(this.browser, [this.profile = '']);
  /// `BROWSER[:PROFILE]`, as `--cookies-from-browser` takes it.
  String get spec => profile.isEmpty ? browser : '$browser:$profile';
}

/// The cookie setting kept in a yt-dlp folder ([dir]): `cookies.txt`
/// (mode 0600) or `cookies-browser` (the `BROWSER[:PROFILE]` spec), never
/// both.
class YtDlpCookies {
  final String dir;
  const YtDlpCookies(this.dir);

  String get filePath => p.join(dir, 'cookies.txt');
  String get _browserPath => p.join(dir, 'cookies-browser');

  /// The current source, or null for none. Without [count] a file is not
  /// parsed ([CookieFile.count] -1, no sites).
  CookieSource? read({bool count = true}) {
    try {
      final b = File(_browserPath);
      if (b.existsSync()) {
        final spec = b.readAsStringSync().trim();
        if (spec.isNotEmpty) {
          final i = spec.indexOf(':');
          return i < 0 ? CookieBrowser(spec) : CookieBrowser(spec.substring(0, i), spec.substring(i + 1));
        }
      }
      final f = File(filePath);
      if (f.existsSync()) {
        if (!count) return CookieFile(filePath, -1, const []);
        final cookies = parseCookies(f.readAsStringSync());
        return CookieFile(filePath, cookies.length, cookiesBySite(cookies).keys.toList());
      }
    } catch (_) {}
    return null;
  }

  /// yt-dlp arguments for [source] (default: [read]).
  List<String> args([CookieSource? source]) => switch (source ?? read(count: false)) {
        CookieFile(:final path) => ['--cookies', path],
        CookieBrowser b => ['--cookies-from-browser', b.spec],
        null => const [],
      };

  /// Keeps [cookies] as the private copy, replacing any browser setting.
  Future<CookieFile> saveFile(List<NetscapeCookie> cookies) async {
    await Directory(dir).create(recursive: true);
    final part = File('$filePath.part$pid');
    try {
      // Private before anything is written into it.
      await part.writeAsString('');
      if (!Platform.isWindows) {
        final r = await Process.run('chmod', ['600', part.path]);
        if (r.exitCode != 0) throw FileSystemException('chmod failed', part.path);
      }
      await part.writeAsString(netscapeCookiesText(cookies), flush: true);
      final target = File(filePath);
      if (Platform.isWindows && await target.exists()) await target.delete();
      await part.rename(filePath);
    } finally {
      if (await part.exists()) await part.delete().catchError((_) => part);
    }
    await _delete(_browserPath);
    return CookieFile(filePath, cookies.length, cookiesBySite(cookies).keys.toList());
  }

  /// Converts the cookies.txt or JSON export at [source] into the private
  /// copy, keeping only [sites] ([cookieSite]s; null: all).
  Future<CookieFile> import(String source, {Set<String>? sites}) async {
    final all = parseCookies(await File(source).readAsString());
    final kept = sites == null ? all : [for (final c in all) if (sites.contains(cookieSite(c.host))) c];
    if (kept.isEmpty) throw const FormatException('no cookies for the chosen sites');
    return saveFile(kept);
  }

  /// Reads cookies from [browser] (one of [cookieBrowsers]) from now on,
  /// replacing any file.
  Future<void> saveBrowser(String browser, [String profile = '']) async {
    if (!cookieBrowsers.contains(browser)) throw ArgumentError.value(browser, 'browser');
    await Directory(dir).create(recursive: true);
    await File(_browserPath).writeAsString(CookieBrowser(browser, profile.trim()).spec);
    await _delete(filePath);
  }

  /// No cookies any more.
  Future<void> remove() async {
    await _delete(filePath);
    await _delete(_browserPath);
  }

  static Future<void> _delete(String path) async {
    final f = File(path);
    if (await f.exists()) await f.delete();
  }
}
