import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Color;

import 'package:path_provider/path_provider.dart';
import 'package:sync_relay_core/core.dart';


// AniList airing schedule (public GraphQL, no login): every episode airing
// in a time range, with covers, banners and popularity; a title search
// (cover + banner of a show, for the media art of files and links); and
// the library's lookups (search with synonyms and relations, one entry by
// id; see ARCHITECTURE.md "Media identity").
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

  /// This airing in AniList's row shape: [fromJson] reads it back (the
  /// kept schedule, `schedule_store.dart`).
  Map<String, Object?> toJson() => {
        'airingAt': airingAt.millisecondsSinceEpoch ~/ 1000,
        'episode': episode,
        'media': {
          'id': anilistId,
          'title': {'romaji': titleRomaji, 'english': title},
          'coverImage': {
            'large': ?cover,
            if (color case final c?) 'color': '#${(c.toARGB32() & 0xffffff).toRadixString(16).padLeft(6, '0')}',
          },
          'bannerImage': ?banner,
          'popularity': popularity,
        },
      };

  @override
  String toString() => 'Airing($anilistId "$title" ep $episode @ $airingAt)';
}

/// An anime found by title ([AniListClient.searchMedia]).
class AniListMedia {
  final int id;
  /// English title, else romaji.
  final String title;
  /// Cover (portrait) URL: extraLarge, else large.
  final String? cover;
  /// The smaller cover, for when [cover] is too big to send on.
  final String? coverSmall;
  final String? banner;
  const AniListMedia({required this.id, required this.title, this.cover, this.coverSmall, this.banner});

  static AniListMedia? fromJson(Object? m) {
    if (m is! Map || m['id'] is! int) return null;
    final t = m['title'] is Map ? m['title'] as Map : const {};
    final romaji = t['romaji'] is String ? t['romaji'] as String : '';
    final english = t['english'] is String ? t['english'] as String : '';
    final cov = m['coverImage'] is Map ? m['coverImage'] as Map : const {};
    final large = cov['large'] is String ? cov['large'] as String : null;
    return AniListMedia(
      id: m['id'] as int,
      title: english.isNotEmpty ? english : romaji,
      cover: cov['extraLarge'] is String ? cov['extraLarge'] as String : large,
      coverSmall: large,
      banner: m['bannerImage'] is String ? m['bannerImage'] as String : null,
    );
  }
}

/// An anime as the library matches it ([AniListClient.searchAnime],
/// [AniListClient.anime]): titles and synonyms to match on, its format
/// and length, art, and the next TV entry of its run ([sequel]) to number
/// across split seasons and cours. JSON round-trips for the library's
/// cache ([toJson]).
class AniListEntry {
  final int id;
  final String romaji;
  final String english;
  final String native;
  final List<String> synonyms;
  /// `TV`, `TV_SHORT`, `MOVIE`, `OVA`, `ONA`, `SPECIAL`, `MUSIC`; '' unknown.
  final String format;
  /// Null while it airs with no announced count.
  final int? episodes;
  final int? year;
  final String? cover;
  final String? coverSmall;
  final String? banner;
  /// The next TV / TV_SHORT / ONA entry (`SEQUEL` relation).
  final int? sequel;
  final int? prequel;
  /// Episode titles AniList knows (its streaming episodes), by number.
  final Map<int, String> episodeTitles;

  const AniListEntry({
    required this.id,
    this.romaji = '',
    this.english = '',
    this.native = '',
    this.synonyms = const [],
    this.format = '',
    this.episodes,
    this.year,
    this.cover,
    this.coverSmall,
    this.banner,
    this.sequel,
    this.prequel,
    this.episodeTitles = const {},
  });

  /// English title, else romaji.
  String get title => english.isNotEmpty ? english : (romaji.isNotEmpty ? romaji : native);

  /// Every name it goes by, for matching.
  List<String> get names => [
        for (final t in [english, romaji, native, ...synonyms])
          if (t.trim().isNotEmpty) t,
      ];

  bool get isMovie => format == 'MOVIE';

  /// A run of episodes a season or cour is made of.
  bool get isSeries => format == 'TV' || format == 'TV_SHORT' || format == 'ONA';

  static const graphQLFields = 'id title{romaji english native} synonyms format episodes seasonYear '
      'coverImage{extraLarge large} bannerImage '
      'relations{edges{relationType node{id format type}}} streamingEpisodes{title}';

  static final _streamingTitle = RegExp(r'^\s*(?:Episode|Ep\.?)\s*(\d{1,4})\s*[-–:]\s*(.+)$', caseSensitive: false);

  /// From an AniList `Media` object; null when it has no id.
  static AniListEntry? fromGraphQL(Object? m) {
    if (m is! Map || m['id'] is! int) return null;
    String str(Object? v) => v is String ? v : '';
    final t = m['title'] is Map ? m['title'] as Map : const {};
    final cov = m['coverImage'] is Map ? m['coverImage'] as Map : const {};
    final large = cov['large'] is String ? cov['large'] as String : null;
    int? related(String type) {
      final edges = m['relations'] is Map ? (m['relations'] as Map)['edges'] : null;
      if (edges is! List) return null;
      for (final e in edges) {
        if (e is! Map || e['relationType'] != type) continue;
        final node = e['node'];
        if (node is Map && node['id'] is int && node['type'] != 'MANGA' &&
            const {'TV', 'TV_SHORT', 'ONA'}.contains(node['format'])) {
          return node['id'] as int;
        }
      }
      return null;
    }

    final titles = <int, String>{};
    final streaming = m['streamingEpisodes'];
    if (streaming is List) {
      for (final s in streaming) {
        final match = s is Map && s['title'] is String ? _streamingTitle.firstMatch(s['title'] as String) : null;
        if (match != null) titles.putIfAbsent(int.parse(match.group(1)!), () => match.group(2)!.trim());
      }
    }
    return AniListEntry(
      id: m['id'] as int,
      romaji: str(t['romaji']),
      english: str(t['english']),
      native: str(t['native']),
      synonyms: [
        if (m['synonyms'] is List)
          for (final s in m['synonyms'] as List)
            if (s is String && s.trim().isNotEmpty) s.trim(),
      ],
      format: str(m['format']),
      episodes: m['episodes'] is int ? m['episodes'] as int : null,
      year: m['seasonYear'] is int ? m['seasonYear'] as int : null,
      cover: cov['extraLarge'] is String ? cov['extraLarge'] as String : large,
      coverSmall: large,
      banner: m['bannerImage'] is String ? m['bannerImage'] as String : null,
      sequel: related('SEQUEL'),
      prequel: related('PREQUEL'),
      episodeTitles: titles,
    );
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'romaji': romaji,
        'english': english,
        'native': native,
        'synonyms': synonyms,
        'format': format,
        'episodes': episodes,
        'year': year,
        'cover': cover,
        'coverSmall': coverSmall,
        'banner': banner,
        'sequel': sequel,
        'prequel': prequel,
        'episodeTitles': {for (final e in episodeTitles.entries) '${e.key}': e.value},
      };

  static AniListEntry? fromJson(Object? j) {
    if (j is! Map || j['id'] is! int) return null;
    String str(Object? v) => v is String ? v : '';
    String? opt(Object? v) => v is String ? v : null;
    int? n(Object? v) => v is int ? v : null;
    final titles = j['episodeTitles'];
    return AniListEntry(
      id: j['id'] as int,
      romaji: str(j['romaji']),
      english: str(j['english']),
      native: str(j['native']),
      synonyms: [if (j['synonyms'] is List) ...(j['synonyms'] as List).whereType<String>()],
      format: str(j['format']),
      episodes: n(j['episodes']),
      year: n(j['year']),
      cover: opt(j['cover']),
      coverSmall: opt(j['coverSmall']),
      banner: opt(j['banner']),
      sequel: n(j['sequel']),
      prequel: n(j['prequel']),
      episodeTitles: {
        if (titles is Map)
          for (final e in titles.entries)
            if (int.tryParse('${e.key}') case final k? when e.value is String) k: e.value as String,
      },
    );
  }

  @override
  String toString() => 'AniListEntry($id "$title" $format ${episodes ?? '?'} eps)';
}

/// What the library asks AniList ([AniListClient]; tests fake it).
abstract interface class AniListLookup {
  /// Anime matching [query], AniList's best first.
  Future<List<AniListEntry>> searchAnime(String query);

  /// One anime by id; null when AniList has none.
  Future<AniListEntry?> anime(int id);
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

class AniListClient implements AniListLookup {
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
        userAgent = userAgent ?? 'Starsync/$appVersion';

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
    final (data, status, j) = await _graphql(query, {'from': from - 1, 'to': to, 'page': page});
    final p = data?['Page'];
    if (p is! Map) {
      throw AniListException('AniList: bad response${_errorText(j)}', statusCode: status);
    }
    return p;
  }

  /// One GraphQL request: `data` (null when missing), status and body. A
  /// 429 waits out Retry-After once; other non-200s throw.
  Future<(Map?, int, Object?)> _graphql(String query, Map<String, Object?> variables) async {
    for (var attempt = 0;; attempt++) {
      final (status, body, retryAfter) = await _post(jsonEncode({'query': query, 'variables': variables}));
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
      final data = j is Map && j['data'] is Map ? j['data'] as Map : null;
      return (data, status, j);
    }
  }

  static const searchQuery = r'''
query($search:String){Media(search:$search,type:ANIME,isAdult:false){id title{romaji english}
coverImage{extraLarge large} bannerImage}}''';

  final _search = <String, Future<AniListMedia?>>{};

  /// AniList's best anime match for [title], or null when there is none.
  /// One request per title for this client's life (a failure is not kept,
  /// so a later call asks again).
  Future<AniListMedia?> searchMedia(String title) {
    final key = title.trim();
    if (key.isEmpty) return Future.value(null);
    return _search[key] ??= _searchMedia(key).catchError((Object e) {
      _search.remove(key);
      throw e;
    });
  }

  Future<AniListMedia?> _searchMedia(String title) async {
    try {
      final (data, _, _) = await _graphql(searchQuery, {'search': title});
      return AniListMedia.fromJson(data?['Media']);
    } on AniListException catch (e) {
      // No match is a 404 with "Not Found." in errors.
      if (e.statusCode == 404) return null;
      rethrow;
    }
  }

  static final _listQuery = 'query(\$search:String){Page(perPage:8){media(search:\$search,type:ANIME,'
      'isAdult:false,sort:SEARCH_MATCH){${AniListEntry.graphQLFields}}}}';
  static final _byIdQuery = 'query(\$id:Int){Media(id:\$id,type:ANIME){${AniListEntry.graphQLFields}}}';

  /// Up to 8 anime matching [query], AniList's best first (the library's
  /// matching and its "Wrong show?" search). Not cached here: the library
  /// keeps what it needs.
  @override
  Future<List<AniListEntry>> searchAnime(String query) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final (data, _, _) = await _graphql(_listQuery, {'search': q});
    final page = data?['Page'];
    final media = page is Map ? page['media'] : null;
    return [if (media is List) for (final m in media) ?AniListEntry.fromGraphQL(m)];
  }

  @override
  Future<AniListEntry?> anime(int id) async {
    try {
      final (data, _, _) = await _graphql(_byIdQuery, {'id': id});
      return AniListEntry.fromGraphQL(data?['Media']);
    } on AniListException catch (e) {
      if (e.statusCode == 404) return null;
      rethrow;
    }
  }

  static const byIdArtQuery = r'''
query($id:Int){Media(id:$id,type:ANIME){id title{romaji english} coverImage{extraLarge large} bannerImage}}''';

  /// Cover and banner of AniList entry [id] (the media art of a file the
  /// library matched); null when there is none.
  Future<AniListMedia?> mediaById(int id) async {
    try {
      final (data, _, _) = await _graphql(byIdArtQuery, {'id': id});
      return AniListMedia.fromJson(data?['Media']);
    } on AniListException catch (e) {
      if (e.statusCode == 404) return null;
      rethrow;
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
