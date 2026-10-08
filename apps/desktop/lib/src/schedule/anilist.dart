import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Color;

import 'package:path_provider/path_provider.dart';
import 'package:sync_relay_core/core.dart';

import '../update/updater.dart' show appVersion;

// AniList airing schedule (public GraphQL, no login): every episode airing
// in a time range, with covers, banners and popularity.
//
// AniList allows ~90 requests/min (sometimes degraded to 30), so the raw
// pages are cached: in memory for 10 min (tab switches) and on disk for an
// hour (restarts), keyed by range start. A 429 waits out Retry-After once;
// if AniList still refuses (or is unreachable), stale cached data is
// returned with its fetch time.

final _log = createLogger('anilist');

const aniListDefaultUrl = 'https://graphql.anilist.co';

/// One episode airing, as AniList announces it.
class Airing {
  final int anilistId;
  /// English title, else romaji.
  final String title;
  final String titleRomaji;
  final int episode;
  /// UTC.
  final DateTime airingAt;
  final String? cover;
  final String? banner;
  /// The cover's dominant color, if AniList has one.
  final Color? color;
  final int popularity;

  const Airing({
    required this.anilistId,
    required this.title,
    required this.titleRomaji,
    required this.episode,
    required this.airingAt,
    this.cover,
    this.banner,
    this.color,
    this.popularity = 0,
  });

  /// Null for adult entries, music videos and malformed rows.
  static Airing? fromJson(Object? j) {
    if (j is! Map) return null;
    final m = j['media'], at = j['airingAt'], ep = j['episode'];
    if (m is! Map || at is! int || ep is! int) return null;
    final id = m['id'];
    if (id is! int || m['isAdult'] == true || m['format'] == 'MUSIC') return null;
    final t = m['title'] is Map ? m['title'] as Map : const {};
    final romaji = t['romaji'] is String ? t['romaji'] as String : '';
    final english = t['english'] is String ? t['english'] as String : '';
    final cov = m['coverImage'] is Map ? m['coverImage'] as Map : const {};
    return Airing(
      anilistId: id,
      title: english.isNotEmpty ? english : (romaji.isNotEmpty ? romaji : '?'),
      titleRomaji: romaji,
      episode: ep,
      airingAt: DateTime.fromMillisecondsSinceEpoch(at * 1000, isUtc: true),
      cover: cov['large'] is String ? cov['large'] as String : null,
      banner: m['bannerImage'] is String ? m['bannerImage'] as String : null,
      color: parseHexColor(cov['color']),
      popularity: m['popularity'] is int ? m['popularity'] as int : 0,
    );
  }

  @override
  String toString() => 'Airing($anilistId "$title" ep $episode @ $airingAt)';
}

/// "#e4a15d" -> opaque [Color]; anything else -> null.
Color? parseHexColor(Object? s) {
  if (s is! String || s.length != 7 || !s.startsWith('#')) return null;
  final v = int.tryParse(s.substring(1), radix: 16);
  return v == null ? null : Color(0xff000000 | v);
}

class AniListException implements Exception {
  final int? statusCode;
  final String message;
  const AniListException(this.message, {this.statusCode});

  bool get isRateLimited => statusCode == 429;

  @override
  String toString() => 'AniListException: $message';
}

/// The airings of one range. [staleSince] is set when AniList refused and
/// older cached data (fetched then) is returned instead.
class AniListSchedule {
  final List<Airing> airings;
  final DateTime fetchedAt;
  final DateTime? staleSince;
  const AniListSchedule(this.airings, this.fetchedAt, {this.staleSince});

  bool get isStale => staleSince != null;
}

class _Cached {
  final DateTime fetched;
  final int from;
  final int to;
  final List<Object?> raw;
  const _Cached(this.fetched, this.from, this.to, this.raw);
}

class AniListClient {
  AniListClient({
    String url = aniListDefaultUrl,
    HttpClient? http,
    Future<Directory?> Function()? cacheDir,
    this.memoryTtl = const Duration(minutes: 10),
    this.diskTtl = const Duration(hours: 1),
    Future<void> Function(Duration)? delay,
    DateTime Function()? now,
    String? userAgent,
  })  : url = Uri.parse(url),
        _http = http ?? HttpClient(),
        _ownsHttp = http == null,
        _cacheDir = cacheDir ?? _defaultCacheDir,
        _delay = delay ?? Future<void>.delayed,
        _now = now ?? DateTime.now,
        userAgent = userAgent ?? 'watch-together/$appVersion';

  final Uri url;
  final Duration memoryTtl;
  final Duration diskTtl;
  /// AniList 403s some default agents.
  final String userAgent;
  final HttpClient _http;
  final bool _ownsHttp;
  final Future<Directory?> Function() _cacheDir;
  final Future<void> Function(Duration) _delay;
  final DateTime Function() _now;

  /// Pages per range at most (50 airings each).
  static const maxPages = 40;
  static const perPage = 50;

  static const query = r'''
query($from:Int,$to:Int,$page:Int){Page(page:$page,perPage:50){pageInfo{hasNextPage}
airingSchedules(airingAt_greater:$from,airingAt_lesser:$to,sort:TIME){airingAt episode
media{id title{romaji english} coverImage{large color} bannerImage isAdult popularity format}}}}''';

  final _mem = <int, _Cached>{};
  final _inflight = <String, Future<AniListSchedule>>{};

  static Future<Directory?> _defaultCacheDir() async {
    try {
      return await getApplicationCacheDirectory();
    } catch (_) {
      return null;
    }
  }

  /// Every airing in [from, to), cached; see the file comment. [force]
  /// skips the fresh caches (stale data is still the fallback).
  Future<AniListSchedule> schedule(DateTime from, DateTime to, {bool force = false}) {
    final f = from.millisecondsSinceEpoch ~/ 1000, t = to.millisecondsSinceEpoch ~/ 1000;
    final k = '$f-$t-$force';
    return _inflight[k] ??= _schedule(f, t, force).whenComplete(() {
      _inflight.remove(k);
    });
  }

  Future<AniListSchedule> _schedule(int from, int to, bool force) async {
    final now = _now();
    final mem = _mem[from];
    final memHit = mem != null && mem.to == to ? mem : null;
    if (!force && memHit != null && now.difference(memHit.fetched) < memoryTtl) {
      return _result(memHit);
    }
    final disk = await _readDisk(from, to);
    if (!force && disk != null && now.difference(disk.fetched) < diskTtl) {
      _mem[from] = disk;
      return _result(disk);
    }
    try {
      final raw = await _fetch(from, to);
      final c = _mem[from] = _Cached(_now(), from, to, raw);
      await _writeDisk(c);
      return _result(c);
    } catch (e) {
      final stale = [memHit, disk].whereType<_Cached>().fold<_Cached?>(
          null, (a, b) => a == null || b.fetched.isAfter(a.fetched) ? b : a);
      if (stale == null) rethrow;
      _log.warning('AniList failed, using cache from ${stale.fetched}: $e');
      return _result(stale, stale: true);
    }
  }

  AniListSchedule _result(_Cached c, {bool stale = false}) => AniListSchedule(
        [for (final r in c.raw) ?Airing.fromJson(r)],
        c.fetched,
        staleSince: stale ? c.fetched : null,
      );

  Future<List<Object?>> _fetch(int from, int to) async {
    final out = <Object?>[];
    for (var page = 1; page <= maxPages; page++) {
      final data = await _page(from, to, page);
      final rows = data['airingSchedules'];
      if (rows is List) out.addAll(rows);
      final info = data['pageInfo'];
      if (info is! Map || info['hasNextPage'] != true) break;
    }
    return out;
  }

  Future<Map> _page(int from, int to, int page) async {
    for (var attempt = 0;; attempt++) {
      final (status, body, retryAfter) = await _post(jsonEncode({
        'query': query,
        'variables': {'from': from - 1, 'to': to, 'page': page},
      }));
      if (status == 429 && attempt == 0) {
        final wait = retryAfter ?? 60;
        _log.info('AniList rate limited, retrying in ${wait}s');
        await _delay(Duration(seconds: wait.clamp(1, 65)));
        continue;
      }
      Object? j;
      try {
        j = jsonDecode(body);
      } catch (_) {}
      if (status != 200) {
        throw AniListException('AniList HTTP $status${_errorText(j)}', statusCode: status);
      }
      final data = j is Map && j['data'] is Map ? (j['data'] as Map)['Page'] : null;
      if (data is! Map) {
        throw AniListException('AniList: bad response${_errorText(j)}', statusCode: status);
      }
      return data;
    }
  }

  static String _errorText(Object? j) {
    final errs = j is Map ? j['errors'] : null;
    if (errs is! List || errs.isEmpty) return '';
    final m = errs.first is Map ? (errs.first as Map)['message'] : null;
    return m is String ? ': $m' : '';
  }

  Future<(int, String, int?)> _post(String body) async {
    try {
      final req = await _http.postUrl(url).timeout(const Duration(seconds: 15));
      req.headers
        ..contentType = ContentType.json
        ..set(HttpHeaders.acceptHeader, 'application/json')
        ..set(HttpHeaders.userAgentHeader, userAgent);
      req.write(body);
      final res = await req.close().timeout(const Duration(seconds: 20));
      final text = await res.transform(const Utf8Decoder(allowMalformed: true)).join();
      return (
        res.statusCode,
        text,
        int.tryParse(res.headers.value(HttpHeaders.retryAfterHeader) ?? ''),
      );
    } on TimeoutException {
      throw const AniListException('AniList timed out');
    } on IOException catch (e) {
      throw AniListException('AniList unreachable: $e');
    }
  }

  // ---------------------------------------------------------------- disk

  Future<File?> _file(int from) async {
    final dir = await _cacheDir();
    return dir == null ? null : File('${dir.path}/anilist-schedule-$from.json');
  }

  Future<_Cached?> _readDisk(int from, int to) async {
    try {
      final f = await _file(from);
      if (f == null || !await f.exists()) return null;
      final j = jsonDecode(await f.readAsString());
      if (j is! Map || j['from'] != from || j['to'] != to) return null;
      final fetched = j['fetched'], raw = j['raw'];
      if (fetched is! int || raw is! List) return null;
      return _Cached(DateTime.fromMillisecondsSinceEpoch(fetched), from, to, raw);
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeDisk(_Cached c) async {
    try {
      final f = await _file(c.from);
      if (f == null) return;
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode({
        'fetched': c.fetched.millisecondsSinceEpoch,
        'from': c.from,
        'to': c.to,
        'raw': c.raw,
      }));
      // Older ranges are useless once a day has passed.
      await for (final e in f.parent.list()) {
        final name = e.uri.pathSegments.last;
        if (e is File &&
            e.path != f.path &&
            name.startsWith('anilist-schedule-') &&
            _now().difference(await e.lastModified()) > const Duration(days: 1)) {
          await e.delete();
        }
      }
    } catch (e) {
      _log.warning('AniList cache write failed: $e');
    }
  }

  /// Drops the memory cache (the disk cache stays as the stale fallback).
  void clearMemory() => _mem.clear();

  void close() {
    if (_ownsHttp) _http.close(force: true);
  }
}
