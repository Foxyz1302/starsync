import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sync_relay_core/core.dart';

import '../jellyfin/accounts.dart';
import '../update/updater.dart' show appVersion;

// AnimeFlow app API: what the media server tracks, has, downloads and was
// asked for. Authenticated with the user's own Jellyfin access token
// (X-Emby-Token) on the Jellyfin server next to it.
//
// Errors are JSON {"detail","code"} ([AnimeFlowException]); nginx in front
// may answer 429 with HTML (5 req/s, burst 20), retried with backoff.
// /schedule, /series, /series/{id} and /requests send weak ETags: the last
// body is kept and revalidated with If-None-Match. Times are UTC ISO
// ("2026-10-08T19:36:32Z"). Scopes can change at runtime, so /me is cached
// for a minute at most.

final _log = createLogger('animeflow');

const animeFlowDefaultBase = 'https://anime.example.org/api/app/v1';

// ---------------------------------------------------------------- errors

enum AnimeFlowErrorCode {
  missingToken('missing_token'),
  badToken('bad_token'),
  revoked('revoked'),
  missingScope('missing_scope'),
  ownAccount('own_account'),
  jellyfinUnreachable('jellyfin_unreachable'),
  searchUnavailable('search_unavailable'),
  invalidRequest('invalid_request'),
  invalidTime('invalid_time'),
  invalidRange('invalid_range'),
  notFound('not_found'),
  seriesNotFound('series_not_found'),
  episodeNotFound('episode_not_found'),
  requestNotFound('request_not_found'),
  userNotFound('user_not_found'),
  alreadyTracked('already_tracked'),
  alreadyAvailable('already_available'),
  alreadyRequested('already_requested'),
  invalidState('invalid_state'),
  /// nginx 429 (client side, no JSON body).
  rateLimited('rate_limited'),
  /// No answer: DNS, connect, timeout (client side).
  network('network'),
  /// Anything not in this list.
  unknown('unknown');

  const AnimeFlowErrorCode(this.wire);
  final String wire;

  static AnimeFlowErrorCode parse(Object? s) =>
      values.where((c) => c.wire == s).firstOrNull ?? unknown;

  /// Best guess from the status alone (body was not JSON).
  static AnimeFlowErrorCode forStatus(int status) => switch (status) {
        401 => badToken,
        403 => missingScope,
        404 => notFound,
        409 => invalidState,
        400 => invalidRequest,
        429 => rateLimited,
        503 => jellyfinUnreachable,
        _ => unknown,
      };
}

class AnimeFlowException implements Exception {
  /// HTTP status; 0 when no answer came.
  final int statusCode;
  final AnimeFlowErrorCode code;
  final String detail;
  const AnimeFlowException(this.statusCode, this.code, this.detail);

  /// Sign in again (token missing, wrong or expired).
  bool get isUnauthorized => statusCode == 401;
  /// Revoked, missing scope or own account.
  bool get isForbidden => statusCode == 403;
  bool get isNotFound => statusCode == 404;
  bool get isConflict => statusCode == 409;
  bool get isUnavailable => statusCode == 503 || code == AnimeFlowErrorCode.network;
  bool get isRateLimited => code == AnimeFlowErrorCode.rateLimited;

  @override
  String toString() => 'AnimeFlowException($statusCode ${code.wire}): $detail';
}

// ---------------------------------------------------------------- models

DateTime? _time(Object? v) => v is String ? DateTime.tryParse(v)?.toUtc() : null;
int? _int(Object? v) => v is int ? v : (v is num ? v.toInt() : null);
String? _str(Object? v) => v is String ? v : null;
List<Map> _items(Object? j) =>
    j is Map && j['items'] is List ? (j['items'] as List).whereType<Map>().toList() : const [];

/// Formats [d] as AnimeFlow wants it: "2026-10-08T19:36:32Z".
String animeFlowTime(DateTime d) => '${d.toUtc().toIso8601String().split('.').first.replaceAll('Z', '')}Z';

enum AnimeFlowScope {
  view,
  request,
  manage;

  static Set<AnimeFlowScope> parse(Object? j) => {
        if (j is List)
          for (final s in j) ...values.where((v) => v.name == s),
      };
}

class AnimeFlowMe {
  final String userId;
  final String name;
  final Set<AnimeFlowScope> scopes;
  const AnimeFlowMe({required this.userId, required this.name, required this.scopes});

  bool can(AnimeFlowScope s) => scopes.contains(s);

  static AnimeFlowMe fromJson(Object? j) {
    final m = j is Map ? j : const {};
    return AnimeFlowMe(
      userId: _str(m['user_id']) ?? '',
      name: _str(m['name']) ?? '',
      scopes: AnimeFlowScope.parse(m['scopes']),
    );
  }
}

enum EpisodeStatus {
  upcoming,
  missing,
  downloading,
  available,
  unmonitored,
  failed;

  /// Unknown values read as upcoming.
  static EpisodeStatus parse(Object? s) => values.where((v) => v.name == s).firstOrNull ?? upcoming;
}

class AnimeFlowEpisode {
  /// 0 = specials.
  final int season;
  final int episode;
  final int? absolute;
  final String? title;
  final DateTime? airDate;
  /// The AniList entry of this episode's season (one AnimeFlow series may
  /// span several AniList entries).
  final int? anilistId;
  final EpisodeStatus status;
  /// 0..1, only while downloading.
  final double? progress;
  /// Only when failed.
  final String? reason;

  const AnimeFlowEpisode({
    required this.season,
    required this.episode,
    this.absolute,
    this.title,
    this.airDate,
    this.anilistId,
    required this.status,
    this.progress,
    this.reason,
  });

  static AnimeFlowEpisode fromJson(Map j) => AnimeFlowEpisode(
        season: _int(j['season']) ?? 0,
        episode: _int(j['episode']) ?? 0,
        absolute: _int(j['absolute']),
        title: _str(j['episode_title']),
        airDate: _time(j['air_date']),
        anilistId: _int(j['anilist_id']),
        status: EpisodeStatus.parse(j['status']),
        progress: (j['progress'] as num?)?.toDouble(),
        reason: _str(j['reason']),
      );
}

/// A /schedule row: one episode plus its series.
class AnimeFlowScheduleItem {
  final AnimeFlowEpisode episode;
  final int seriesId;
  final String title;
  final int? anidbId;
  final int? tvdbId;
  final String? jellyfinSeriesId;
  final bool followed;

  const AnimeFlowScheduleItem({
    required this.episode,
    required this.seriesId,
    required this.title,
    this.anidbId,
    this.tvdbId,
    this.jellyfinSeriesId,
    this.followed = false,
  });

  static AnimeFlowScheduleItem fromJson(Map j) => AnimeFlowScheduleItem(
        episode: AnimeFlowEpisode.fromJson(j),
        seriesId: _int(j['series_id']) ?? 0,
        title: _str(j['title']) ?? '',
        anidbId: _int(j['anidb_id']),
        tvdbId: _int(j['tvdb_id']),
        jellyfinSeriesId: _str(j['jellyfin_series_id']),
        followed: j['followed'] == true,
      );
}

class AnimeFlowScheduleWindow {
  final DateTime? from;
  final DateTime? to;
  final List<AnimeFlowScheduleItem> items;
  const AnimeFlowScheduleWindow({this.from, this.to, required this.items});
}

enum SeriesState {
  releasing,
  released;

  static SeriesState parse(Object? s) => s == 'released' ? released : releasing;
}

class AnimeFlowSeries {
  final int seriesId;
  final String title;
  final int? anidbId;
  final int? tvdbId;
  /// The series' (first) AniList entry; later seasons may have others, see
  /// [AnimeFlowEpisode.anilistId].
  final int? anilistId;
  final String? jellyfinSeriesId;
  final SeriesState state;
  final bool monitored;
  final bool followed;
  final int episodesTotal;
  final int episodesAvailable;
  final DateTime? nextAirDate;
  /// Only from [AnimeFlowClient.seriesDetail].
  final List<AnimeFlowEpisode> episodes;

  const AnimeFlowSeries({
    required this.seriesId,
    required this.title,
    this.anidbId,
    this.tvdbId,
    this.anilistId,
    this.jellyfinSeriesId,
    this.state = SeriesState.releasing,
    this.monitored = false,
    this.followed = false,
    this.episodesTotal = 0,
    this.episodesAvailable = 0,
    this.nextAirDate,
    this.episodes = const [],
  });

  static AnimeFlowSeries fromJson(Map j) => AnimeFlowSeries(
        seriesId: _int(j['series_id']) ?? 0,
        title: _str(j['title']) ?? '',
        anidbId: _int(j['anidb_id']),
        tvdbId: _int(j['tvdb_id']),
        anilistId: _int(j['anilist_id']),
        jellyfinSeriesId: _str(j['jellyfin_series_id']),
        state: SeriesState.parse(j['state']),
        monitored: j['monitored'] == true,
        followed: j['followed'] == true,
        episodesTotal: _int(j['episodes_total']) ?? 0,
        episodesAvailable: _int(j['episodes_available']) ?? 0,
        nextAirDate: _time(j['next_air_date']),
        episodes: [
          if (j['episodes'] is List)
            for (final e in (j['episodes'] as List).whereType<Map>()) AnimeFlowEpisode.fromJson(e),
        ],
      );
}

class AnimeFlowSearchHit {
  final int anidbId;
  final String title;
  final int? anilistId;
  /// Set when AnimeFlow already tracks it.
  final int? seriesId;
  const AnimeFlowSearchHit({required this.anidbId, required this.title, this.anilistId, this.seriesId});

  static AnimeFlowSearchHit fromJson(Map j) => AnimeFlowSearchHit(
        anidbId: _int(j['anidb_id']) ?? 0,
        title: _str(j['title']) ?? '',
        anilistId: _int(j['anilist_id']),
        seriesId: _int(j['series_id']),
      );
}

enum RequestKind {
  series,
  season,
  episode;

  static RequestKind parse(Object? s) => values.where((v) => v.name == s).firstOrNull ?? series;
}

enum RequestStatus {
  /// Briefly, before auto-approval or a manager decides.
  pending,
  approved,
  searching,
  done,
  rejected,
  failed;

  static RequestStatus parse(Object? s) => values.where((v) => v.name == s).firstOrNull ?? pending;
}

class AnimeFlowRequest {
  final int id;
  final RequestKind kind;
  final RequestStatus status;
  final String title;
  final int? anidbId;
  final int? seriesId;
  final int? season;
  final int? episode;
  final String? reason;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  /// Only with scope=all.
  final String? userId;
  final String? userName;

  const AnimeFlowRequest({
    required this.id,
    required this.kind,
    required this.status,
    required this.title,
    this.anidbId,
    this.seriesId,
    this.season,
    this.episode,
    this.reason,
    this.createdAt,
    this.updatedAt,
    this.userId,
    this.userName,
  });

  static AnimeFlowRequest fromJson(Map j) => AnimeFlowRequest(
        id: _int(j['id']) ?? 0,
        kind: RequestKind.parse(j['kind']),
        status: RequestStatus.parse(j['status']),
        title: _str(j['title']) ?? '',
        anidbId: _int(j['anidb_id']),
        seriesId: _int(j['series_id']),
        season: _int(j['season']),
        episode: _int(j['episode']),
        reason: _str(j['reason']),
        createdAt: _time(j['created_at']),
        updatedAt: _time(j['updated_at']),
        userId: _str(j['user_id']),
        userName: _str(j['user_name']),
      );
}

class AnimeFlowUser {
  /// The Jellyfin user id.
  final String userId;
  final String name;
  final Set<AnimeFlowScope> scopes;
  final bool revoked;
  final DateTime? lastSeenAt;
  const AnimeFlowUser({
    required this.userId,
    required this.name,
    required this.scopes,
    this.revoked = false,
    this.lastSeenAt,
  });

  static AnimeFlowUser fromJson(Map j) => AnimeFlowUser(
        userId: _str(j['user_id']) ?? '',
        name: _str(j['name']) ?? '',
        scopes: AnimeFlowScope.parse(j['scopes']),
        revoked: j['revoked'] == true,
        lastSeenAt: _time(j['last_seen_at']),
      );
}

// ---------------------------------------------------------------- client

class _Etagged {
  final String etag;
  final Object? body;
  const _Etagged(this.etag, this.body);
}

class AnimeFlowClient {
  /// [token] wins over [tokenProvider]; with neither, every call fails with
  /// [AnimeFlowErrorCode.missingToken].
  AnimeFlowClient({
    String baseUrl = animeFlowDefaultBase,
    this._token,
    this._tokenProvider,
    HttpClient? http,
    Future<void> Function(Duration)? delay,
    DateTime Function()? now,
    this.meTtl = const Duration(seconds: 60),
    String? userAgent,
  })  : baseUrl = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl,
        _http = http ?? HttpClient(),
        _ownsHttp = http == null,
        _delay = delay ?? Future<void>.delayed,
        _now = now ?? DateTime.now,
        userAgent = userAgent ?? 'watch-together/$appVersion';

  /// Authenticated with the linked Jellyfin account on the same domain
  /// (see [tokenFor]), looked up on every call so a re-link applies.
  factory AnimeFlowClient.fromAccounts(
    JellyfinAccounts accounts, {
    String baseUrl = animeFlowDefaultBase,
    HttpClient? http,
  }) =>
      AnimeFlowClient(
        baseUrl: baseUrl,
        http: http,
        tokenProvider: () async {
          await accounts.ensureLoaded(validate: false);
          return tokenFor(accounts.accounts, baseUrl);
        },
      );

  final String baseUrl;
  final Duration meTtl;
  final String userAgent;
  final String? _token;
  final Future<String?> Function()? _tokenProvider;
  final HttpClient _http;
  final bool _ownsHttp;
  final Future<void> Function(Duration) _delay;
  final DateTime Function() _now;

  /// Request bodies above this are refused by the server.
  static const maxBodyBytes = 16 * 1024;
  /// Retries after an nginx 429 (backoff 1 s, 2 s unless Retry-After).
  static const rateLimitRetries = 2;
  /// The longest /schedule window.
  static const maxScheduleRange = Duration(days: 45);

  String? _lastToken;
  final _etags = <String, _Etagged>{};
  ({DateTime at, AnimeFlowMe me})? _me;

  /// The token of the linked Jellyfin account whose host shares
  /// [animeFlowBase]'s parent domain (anime.example.org -> example.org,
  /// jellyfin.example.org, ...).
  static String? tokenFor(Iterable<JellyfinAccount> accounts, String animeFlowBase) {
    final host = Uri.tryParse(animeFlowBase)?.host.toLowerCase() ?? '';
    if (host.isEmpty) return null;
    final labels = host.split('.');
    final parent = labels.length > 2 ? labels.skip(1).join('.') : host;
    bool matches(String url) {
      final h = Uri.tryParse(url)?.host.toLowerCase() ?? '';
      return h.isNotEmpty && (h == parent || h.endsWith('.$parent'));
    }

    for (final a in accounts) {
      if (a.urls.any(matches)) return a.token;
    }
    return null;
  }

  Future<String> _authToken() async {
    final t = _token ?? await _tokenProvider?.call();
    if (t == null || t.isEmpty) {
      throw const AnimeFlowException(
          401, AnimeFlowErrorCode.missingToken, 'No linked Jellyfin account for AnimeFlow');
    }
    if (t != _lastToken) {
      // Another user: nothing cached belongs to them.
      _lastToken = t;
      _etags.clear();
      _me = null;
    }
    return t;
  }

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('$baseUrl$path').replace(queryParameters: query);

  /// Sends one call; JSON body or null (204). [etag]: revalidate the last
  /// body of this URL.
  Future<Object?> _call(String method, String path,
      {Map<String, String>? query, Object? body, bool etag = false}) async {
    final token = await _authToken();
    final uri = _uri(path, query);
    final key = uri.toString();
    List<int>? bytes;
    if (body != null) {
      bytes = utf8.encode(jsonEncode(body));
      if (bytes.length > maxBodyBytes) {
        throw const AnimeFlowException(400, AnimeFlowErrorCode.invalidRequest, 'Request body too large');
      }
    }
    for (var attempt = 0;; attempt++) {
      final cached = etag ? _etags[key] : null;
      final (status, text, retryAfter, tag) = await _send(method, uri, token, bytes, cached?.etag);
      if (status == 304 && cached != null) return cached.body;
      if (status >= 200 && status < 300) {
        final j = text.trim().isEmpty ? null : _decode(text, status);
        if (etag && tag != null && tag.isNotEmpty) _etags[key] = _Etagged(tag, j);
        return j;
      }
      final err = _error(status, text);
      if (err.isRateLimited && attempt < rateLimitRetries) {
        final wait = retryAfter != null ? Duration(seconds: retryAfter.clamp(1, 30)) : Duration(seconds: 1 << attempt);
        _log.info('AnimeFlow rate limited on $path, retrying in ${wait.inSeconds}s');
        await _delay(wait);
        continue;
      }
      throw err;
    }
  }

  static Object? _decode(String text, int status) {
    try {
      return jsonDecode(text);
    } catch (_) {
      throw AnimeFlowException(status, AnimeFlowErrorCode.unknown, 'Response is not JSON');
    }
  }

  static AnimeFlowException _error(int status, String text) {
    Object? j;
    try {
      j = jsonDecode(text);
    } catch (_) {}
    if (j is Map && j['code'] is String) {
      final code = AnimeFlowErrorCode.parse(j['code']);
      return AnimeFlowException(status, code == AnimeFlowErrorCode.unknown ? AnimeFlowErrorCode.forStatus(status) : code,
          _str(j['detail']) ?? 'HTTP $status');
    }
    // Not ours: nginx (HTML 429/502), a proxy, ...
    return AnimeFlowException(status, AnimeFlowErrorCode.forStatus(status),
        status == 429 ? 'Too many requests, try again shortly' : 'HTTP $status');
  }

  Future<(int, String, int?, String?)> _send(
      String method, Uri uri, String token, List<int>? body, String? ifNoneMatch) async {
    try {
      final req = await _http.openUrl(method, uri).timeout(const Duration(seconds: 15));
      req.headers
        ..set(HttpHeaders.acceptHeader, 'application/json')
        ..set(HttpHeaders.userAgentHeader, userAgent)
        ..set('X-Emby-Token', token);
      if (ifNoneMatch != null) req.headers.set(HttpHeaders.ifNoneMatchHeader, ifNoneMatch);
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.contentLength = body.length;
        req.add(body);
      }
      final res = await req.close().timeout(const Duration(seconds: 20));
      final text = await res.transform(const Utf8Decoder(allowMalformed: true)).join();
      return (
        res.statusCode,
        text,
        int.tryParse(res.headers.value(HttpHeaders.retryAfterHeader) ?? ''),
        res.headers.value(HttpHeaders.etagHeader),
      );
    } on TimeoutException {
      throw const AnimeFlowException(0, AnimeFlowErrorCode.network, 'AnimeFlow timed out');
    } on IOException catch (e) {
      throw AnimeFlowException(0, AnimeFlowErrorCode.network, 'AnimeFlow unreachable: $e');
    }
  }

  // ------------------------------------------------------------ endpoints

  /// Who the token belongs to and what they may do. Cached for [meTtl]
  /// (scopes change at runtime).
  Future<AnimeFlowMe> me({bool force = false}) async {
    await _authToken();
    final c = _me;
    if (!force && c != null && _now().difference(c.at) < meTtl) return c.me;
    final me = AnimeFlowMe.fromJson(await _call('GET', '/me'));
    _me = (at: _now(), me: me);
    return me;
  }

  /// Episodes airing in [from, to) (at most 45 days) [view].
  Future<AnimeFlowScheduleWindow> schedule(DateTime from, DateTime to) async {
    if (!from.isBefore(to) || to.difference(from) > maxScheduleRange) {
      throw const AnimeFlowException(400, AnimeFlowErrorCode.invalidRange, 'from must be before to, at most 45 days');
    }
    final j = await _call('GET', '/schedule',
        query: {'from': animeFlowTime(from), 'to': animeFlowTime(to)}, etag: true);
    final m = j is Map ? j : const {};
    return AnimeFlowScheduleWindow(
      from: _time(m['from']),
      to: _time(m['to']),
      items: [for (final e in _items(j)) AnimeFlowScheduleItem.fromJson(e)],
    );
  }

  /// Every tracked series [view].
  Future<List<AnimeFlowSeries>> series() async =>
      [for (final s in _items(await _call('GET', '/series', etag: true))) AnimeFlowSeries.fromJson(s)];

  /// One series with all its episodes [view].
  Future<AnimeFlowSeries> seriesDetail(int seriesId) async {
    final j = await _call('GET', '/series/$seriesId', etag: true);
    return AnimeFlowSeries.fromJson(j is Map ? j : const {});
  }

  /// Follow (or unfollow) a series [view].
  Future<void> setFollowed(int seriesId, bool followed) =>
      _call(followed ? 'PUT' : 'DELETE', '/series/$seriesId/follow');

  /// Titles that can be requested [request].
  Future<List<AnimeFlowSearchHit>> search(String q) async => [
        for (final h in _items(await _call('GET', '/search', query: {'q': q}))) AnimeFlowSearchHit.fromJson(h),
      ];

  /// Asks for a whole new series by its AniDB id [request].
  Future<AnimeFlowRequest> requestSeries(int anidbId) => _request({'anidb_id': anidbId});

  /// Asks for one season of a tracked series [request].
  Future<AnimeFlowRequest> requestSeason(int seriesId, int season) =>
      _request({'series_id': seriesId, 'season': season});

  /// Asks for one episode of a tracked series [request].
  Future<AnimeFlowRequest> requestEpisode(int seriesId, int season, int episode) =>
      _request({'series_id': seriesId, 'season': season, 'episode': episode});

  Future<AnimeFlowRequest> _request(Map<String, Object> body) async {
    final j = await _call('POST', '/requests', body: body);
    return AnimeFlowRequest.fromJson(j is Map ? j : const {});
  }

  /// Own requests, newest first [view]; [all] = everyone's, with the user
  /// [manage].
  Future<List<AnimeFlowRequest>> requests({bool all = false}) async => [
        for (final r in _items(await _call('GET', '/requests', query: all ? {'scope': 'all'} : null, etag: true)))
          AnimeFlowRequest.fromJson(r),
      ];

  /// [manage]. Returns the updated request when the server sends one.
  Future<AnimeFlowRequest?> approve(int requestId) async =>
      _maybeRequest(await _call('POST', '/requests/$requestId/approve'));

  /// [manage].
  Future<AnimeFlowRequest?> reject(int requestId, {String? reason}) async => _maybeRequest(
      await _call('POST', '/requests/$requestId/reject', body: {'reason': ?reason}));

  static AnimeFlowRequest? _maybeRequest(Object? j) =>
      j is Map && j['id'] != null ? AnimeFlowRequest.fromJson(j) : null;

  /// [manage].
  Future<List<AnimeFlowUser>> users() async =>
      [for (final u in _items(await _call('GET', '/users'))) AnimeFlowUser.fromJson(u)];

  /// Sets a user's scopes (and revocation) [manage]. Returns the updated
  /// user when the server sends one.
  Future<AnimeFlowUser?> setScopes(String jellyfinUserId, Set<AnimeFlowScope> scopes, {bool? revoked}) async {
    final j = await _call('PUT', '/users/${Uri.encodeComponent(jellyfinUserId)}/scopes', body: {
      'scopes': [for (final s in AnimeFlowScope.values) if (scopes.contains(s)) s.name],
      'revoked': ?revoked,
    });
    _me = null; // could be our own
    return j is Map && j['user_id'] != null ? AnimeFlowUser.fromJson(j) : null;
  }

  /// Forgets cached bodies and /me (e.g. on a manual refresh).
  void clearCache() {
    _etags.clear();
    _me = null;
  }

  void close() {
    if (_ownsHttp) _http.close(force: true);
  }
}
