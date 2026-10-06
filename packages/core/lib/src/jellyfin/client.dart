import 'dart:async';
import 'dart:convert';

import 'client_info.dart';
import 'http.dart';
import 'links.dart';
import 'models.dart';

/// Sort keys for [JellyfinItemQuery.sortBy] (Jellyfin `ItemSortBy`).
abstract final class JellyfinSortBy {
  static const sortName = 'SortName';
  static const name = 'Name';
  static const dateCreated = 'DateCreated';
  static const datePlayed = 'DatePlayed';
  static const premiereDate = 'PremiereDate';
  static const productionYear = 'ProductionYear';
  static const communityRating = 'CommunityRating';
  static const runtime = 'Runtime';
  static const random = 'Random';
  static const dateLastContentAdded = 'DateLastContentAdded';
  static const seriesDatePlayed = 'SeriesDatePlayed';
}

/// Filters for [JellyfinItemQuery.filters] (Jellyfin `ItemFilter`).
abstract final class JellyfinFilter {
  static const isFolder = 'IsFolder';
  static const isNotFolder = 'IsNotFolder';
  static const isPlayed = 'IsPlayed';
  static const isUnplayed = 'IsUnplayed';
  static const isFavorite = 'IsFavorite';
  static const isResumable = 'IsResumable';
}

/// Item types for [JellyfinItemQuery.includeItemTypes].
abstract final class JellyfinItemType {
  static const movie = 'Movie';
  static const series = 'Series';
  static const season = 'Season';
  static const episode = 'Episode';
  static const folder = 'Folder';
  static const boxSet = 'BoxSet';
  static const video = 'Video';
}

/// A library listing (`GET /Items`). Typical uses:
/// - all series of a TV library: `parentId: libId, includeItemTypes:
///   [JellyfinItemType.series], recursive: true`;
/// - all movies: same with `[JellyfinItemType.movie]`;
/// - browsing a folder library level by level: `parentId: folderId`,
///   `recursive: false` (sub-folders and videos mixed; tell them apart by
///   [JellyfinItem.isFolder]);
/// - paging: `query.page(startIndex, limit)` until [JellyfinItemPage.hasMore]
///   is false.
class JellyfinItemQuery {
  final String? parentId;
  final List<String> includeItemTypes;
  final bool recursive;
  final String? searchTerm;
  final List<String> sortBy;
  final bool descending;
  final List<String> filters;
  final int startIndex;
  final int? limit;
  const JellyfinItemQuery({
    this.parentId,
    this.includeItemTypes = const [],
    this.recursive = false,
    this.searchTerm,
    this.sortBy = const [JellyfinSortBy.sortName],
    this.descending = false,
    this.filters = const [],
    this.startIndex = 0,
    this.limit,
  });

  JellyfinItemQuery page(int startIndex, int limit) => JellyfinItemQuery(
        parentId: parentId,
        includeItemTypes: includeItemTypes,
        recursive: recursive,
        searchTerm: searchTerm,
        sortBy: sortBy,
        descending: descending,
        filters: filters,
        startIndex: startIndex,
        limit: limit,
      );
}

/// One Playing / Progress / Stopped report. Build it from
/// [JellyfinPlaybackInfo] (playSessionId, source id) and the player state.
class JellyfinPlaybackReport {
  final String itemId;
  final String mediaSourceId;
  final String playSessionId;
  final int positionTicks;
  final bool isPaused;
  /// Jellyfin stream index ([JellyfinMediaStream.index]) of the audio track.
  final int? audioStreamIndex;
  /// Jellyfin stream index of the subtitle track; -1 = subtitles off.
  final int? subtitleStreamIndex;
  final bool canSeek;
  /// Always "DirectPlay" for this app (no transcoding).
  final String playMethod;
  const JellyfinPlaybackReport({
    required this.itemId,
    required this.mediaSourceId,
    required this.playSessionId,
    this.positionTicks = 0,
    this.isPaused = false,
    this.audioStreamIndex,
    this.subtitleStreamIndex,
    this.canSeek = true,
    this.playMethod = 'DirectPlay',
  });

  JellyfinPlaybackReport copyWith({
    int? positionTicks,
    bool? isPaused,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
  }) =>
      JellyfinPlaybackReport(
        itemId: itemId,
        mediaSourceId: mediaSourceId,
        playSessionId: playSessionId,
        positionTicks: positionTicks ?? this.positionTicks,
        isPaused: isPaused ?? this.isPaused,
        audioStreamIndex: audioStreamIndex ?? this.audioStreamIndex,
        subtitleStreamIndex: subtitleStreamIndex ?? this.subtitleStreamIndex,
        canSeek: canSeek,
        playMethod: playMethod,
      );

  /// Body of /Sessions/Playing and /Sessions/Playing/Progress.
  Map<String, dynamic> toProgressJson() => {
        'ItemId': itemId,
        'MediaSourceId': mediaSourceId,
        'PlaySessionId': playSessionId,
        'PositionTicks': positionTicks,
        'IsPaused': isPaused,
        'CanSeek': canSeek,
        'PlayMethod': playMethod,
        if (audioStreamIndex != null) 'AudioStreamIndex': audioStreamIndex,
        if (subtitleStreamIndex != null) 'SubtitleStreamIndex': subtitleStreamIndex,
      };

  /// Body of /Sessions/Playing/Stopped.
  Map<String, dynamic> toStoppedJson() => {
        'ItemId': itemId,
        'MediaSourceId': mediaSourceId,
        'PlaySessionId': playSessionId,
        'PositionTicks': positionTicks,
      };
}

/// Jellyfin REST client for one server and (once signed in) one user.
///
/// Lifecycle:
/// 1. `JellyfinClient(baseUrl: normalizeServerUrl(input)!, clientInfo: ...)`;
///    [publicInfo] gives the ServerId to key the account by.
/// 2. Sign in with [quickConnectInitiate] + [waitForQuickConnect], or
///    [authenticateByName]. Both store the token and user id on the client
///    and return them in a [JellyfinAuthResult] to persist. A saved login is
///    restored with the constructor's [accessToken] / [userId] and checked
///    with [validateToken].
/// 3. Browse, get [playbackInfo], play [streamUrl] in mpv, report with
///    [reportPlaybackStart] / [reportPlaybackProgress] /
///    [reportPlaybackStopped] (progress every ~10 s and on pause/seek/track
///    change, like Jellyfin's own clients).
///
/// Every user-scoped call needs [userId]; calls that need a token throw
/// [JellyfinException] (401) from the server when it is missing or revoked.
/// [close] releases the HTTP client.
class JellyfinClient {
  /// Normalised server base URL, no trailing slash.
  final String baseUrl;
  final JellyfinClientInfo clientInfo;
  String? accessToken;
  String? userId;
  final JellyfinHttp _http;

  /// Fields requested for list items: enough for cards and detail headers.
  static const listFields = 'PrimaryImageAspectRatio,Overview,ChildCount,RecursiveItemCount';
  static const _imageParams = {
    'enableImageTypes': 'Primary,Backdrop,Thumb,Logo',
    'imageTypeLimit': '1',
  };

  JellyfinClient({
    required String baseUrl,
    required this.clientInfo,
    this.accessToken,
    this.userId,
    JellyfinHttp? http,
  })  : baseUrl = normalizeServerUrl(baseUrl) ?? baseUrl,
        _http = http ?? IoJellyfinHttp();

  bool get isAuthenticated => accessToken != null && userId != null;

  void close() => _http.close();

  // ---------------------------------------------------------------- server

  /// `GET /System/Info/Public` (no auth): ServerId, name, version. Also the
  /// cheap way to check that an address is a Jellyfin server.
  Future<JellyfinServerInfo> publicInfo() async =>
      JellyfinServerInfo.fromJson(_map(await _json('GET', '/System/Info/Public', auth: false)));

  // ------------------------------------------------------------------ auth

  /// Whether the server has Quick Connect turned on.
  Future<bool> quickConnectEnabled() async =>
      await _json('GET', '/QuickConnect/Enabled', auth: false) == true;

  /// `POST /QuickConnect/Initiate`: starts a request and returns the code
  /// to show. Needs the full client header (see [JellyfinClientInfo]) and a
  /// Content-Length (see [JellyfinHttp.send]); 401 means Quick Connect is
  /// disabled on the server.
  Future<QuickConnectSession> quickConnectInitiate() async =>
      QuickConnectSession.fromJson(_map(await _json('POST', '/QuickConnect/Initiate', auth: false)));

  /// `GET /QuickConnect/Connect?secret=`: current state of the request.
  /// Throws 404 once the request expired (Jellyfin drops them after ~10 min).
  Future<QuickConnectSession> quickConnectCheck(String secret) async =>
      QuickConnectSession.fromJson(_map(await _json('GET', '/QuickConnect/Connect',
          query: {'secret': secret}, auth: false)));

  /// `POST /Users/AuthenticateWithQuickConnect` once the request is
  /// authorised. Stores the token on this client.
  Future<JellyfinAuthResult> authenticateWithQuickConnect(String secret) async =>
      _applyAuth(JellyfinAuthResult.fromJson(_map(await _json(
          'POST', '/Users/AuthenticateWithQuickConnect',
          body: {'Secret': secret}, auth: false))));

  /// Polls [quickConnectCheck] every [interval] until the user approves the
  /// code, then signs in. Returns null if [isCancelled] turns true (checked
  /// before each poll); throws [TimeoutException] after [timeout].
  Future<JellyfinAuthResult?> waitForQuickConnect(
    QuickConnectSession session, {
    Duration interval = const Duration(seconds: 3),
    Duration timeout = const Duration(minutes: 10),
    bool Function()? isCancelled,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      if (isCancelled?.call() ?? false) return null;
      final state = await quickConnectCheck(session.secret);
      if (isCancelled?.call() ?? false) return null;
      if (state.authenticated) return authenticateWithQuickConnect(session.secret);
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('Quick Connect code was not approved', timeout);
      }
      await Future<void>.delayed(interval);
    }
  }

  /// `POST /Users/AuthenticateByName`. Stores the token on this client.
  /// Wrong credentials give a [JellyfinException] with status 401.
  Future<JellyfinAuthResult> authenticateByName(String username, String password) async =>
      _applyAuth(JellyfinAuthResult.fromJson(_map(await _json(
          'POST', '/Users/AuthenticateByName',
          body: {'Username': username, 'Pw': password}, auth: false))));

  /// `GET /Users/Me`: the token's user. Also sets [userId].
  Future<JellyfinUser> currentUser() async {
    final user = JellyfinUser.fromJson(_map(await _json('GET', '/Users/Me')));
    userId = user.id;
    return user;
  }

  /// Checks a saved token: the user, or null when the server says 401
  /// (expired or revoked; sign in again). Other failures throw, so an
  /// offline server does not look like a logout.
  Future<JellyfinUser?> validateToken() async {
    try {
      return await currentUser();
    } on JellyfinException catch (e) {
      if (e.isUnauthorized) return null;
      rethrow;
    }
  }

  /// `POST /Sessions/Logout`: revokes the token server-side, then forgets it.
  Future<void> logout() async {
    try {
      await _json('POST', '/Sessions/Logout');
    } finally {
      accessToken = null;
      userId = null;
    }
  }

  JellyfinAuthResult _applyAuth(JellyfinAuthResult r) {
    accessToken = r.accessToken;
    userId = r.user.id;
    return r;
  }

  // -------------------------------------------------------------- browsing

  /// The user's libraries (`GET /UserViews`). [JellyfinItem.collectionType]
  /// tells movies / tvshows / homevideos / ... apart.
  Future<List<JellyfinItem>> userViews() async =>
      JellyfinItemPage.fromJson(_map(await _json('GET', '/UserViews', query: {'userId': _uid}))).items;

  /// Continue Watching: videos with a resume position, most recent first.
  Future<List<JellyfinItem>> resume({int limit = 24, String? parentId}) async =>
      JellyfinItemPage.fromJson(_map(await _json('GET', '/UserItems/Resume', query: {
        'userId': _uid,
        'mediaTypes': 'Video',
        'limit': '$limit',
        if (parentId != null) 'parentId': parentId,
        'fields': listFields,
        ..._imageParams,
      }))).items;

  /// Next Up: per series, the first unwatched episode after the last
  /// watched one. Not "the episode after X": use [nextEpisode] for that.
  /// [enableResumable] false leaves out episodes already in [resume].
  Future<List<JellyfinItem>> nextUp({
    int limit = 24,
    String? seriesId,
    String? parentId,
    bool enableResumable = false,
  }) async =>
      JellyfinItemPage.fromJson(_map(await _json('GET', '/Shows/NextUp', query: {
        'userId': _uid,
        'limit': '$limit',
        if (seriesId != null) 'seriesId': seriesId,
        if (parentId != null) 'parentId': parentId,
        'enableResumable': '$enableResumable',
        'fields': listFields,
        ..._imageParams,
      }))).items;

  /// Recently added in one library. Episodes are grouped into their series
  /// (as the web UI shows them) unless [groupItems] is false.
  Future<List<JellyfinItem>> latest(String parentId, {int limit = 16, bool groupItems = true}) async {
    final list = await _json('GET', '/Items/Latest', query: {
      'userId': _uid,
      'parentId': parentId,
      'limit': '$limit',
      'groupItems': '$groupItems',
      'fields': listFields,
      ..._imageParams,
    });
    return (list as List? ?? const [])
        .whereType<Map>()
        .map((e) => JellyfinItem.fromJson(e.cast<String, dynamic>()))
        .toList();
  }

  /// A page of library items; see [JellyfinItemQuery].
  Future<JellyfinItemPage> items(JellyfinItemQuery q) async {
    final page = JellyfinItemPage.fromJson(_map(await _json('GET', '/Items', query: {
      'userId': _uid,
      if (q.parentId != null) 'parentId': q.parentId!,
      if (q.includeItemTypes.isNotEmpty) 'includeItemTypes': q.includeItemTypes.join(','),
      'recursive': '${q.recursive}',
      if (q.searchTerm != null && q.searchTerm!.isNotEmpty) 'searchTerm': q.searchTerm!,
      if (q.sortBy.isNotEmpty) 'sortBy': q.sortBy.join(','),
      'sortOrder': q.descending ? 'Descending' : 'Ascending',
      if (q.filters.isNotEmpty) 'filters': q.filters.join(','),
      'startIndex': '${q.startIndex}',
      if (q.limit != null) 'limit': '${q.limit}',
      'enableTotalRecordCount': 'true',
      'fields': listFields,
      ..._imageParams,
    })));
    // Jellyfin echoes StartIndex; older servers omit it.
    return JellyfinItemPage(page.items,
        totalRecordCount: page.totalRecordCount, startIndex: q.startIndex);
  }

  /// Search movies, series and episodes by name across all libraries.
  Future<List<JellyfinItem>> search(
    String term, {
    int limit = 30,
    List<String> types = const [
      JellyfinItemType.movie,
      JellyfinItemType.series,
      JellyfinItemType.episode,
    ],
  }) async =>
      (await items(JellyfinItemQuery(
        searchTerm: term,
        recursive: true,
        includeItemTypes: types,
        limit: limit,
      )))
          .items;

  /// Full item (detail page): overview, user data, media sources/streams.
  Future<JellyfinItem> item(String itemId) async =>
      JellyfinItem.fromJson(_map(await _json('GET', '/Items/$itemId', query: {'userId': _uid})));

  /// Seasons of a series, with user data (played, unplayed count).
  Future<List<JellyfinItem>> seasons(String seriesId) async =>
      JellyfinItemPage.fromJson(_map(await _json('GET', '/Shows/$seriesId/Seasons', query: {
        'userId': _uid,
        'enableUserData': 'true',
        'fields': listFields,
        ..._imageParams,
      }))).items;

  /// Episodes of a series in airing order (all seasons, or one
  /// [seasonId]), with user data. Missing (virtual) episodes are left out.
  /// Pass [withMediaStreams] to get each episode's tracks in the same call.
  Future<List<JellyfinItem>> episodes(String seriesId,
          {String? seasonId, bool withMediaStreams = false}) async =>
      JellyfinItemPage.fromJson(_map(await _json('GET', '/Shows/$seriesId/Episodes', query: {
        'userId': _uid,
        if (seasonId != null) 'seasonId': seasonId,
        'isMissing': 'false',
        'enableUserData': 'true',
        'fields': withMediaStreams ? '$listFields,MediaStreams' : listFields,
        ..._imageParams,
      }))).items;

  /// The episode after [episode] in its series (crossing seasons), or null
  /// for the last one. See [episodeAfter] for the rule.
  Future<JellyfinItem?> nextEpisode(JellyfinItem episode, {bool withMediaStreams = false}) async {
    final seriesId = episode.seriesId;
    if (seriesId == null) return null;
    return episodeAfter(
        await episodes(seriesId, withMediaStreams: withMediaStreams), episode.id);
  }

  /// The episodes before and after [episode] in its series (one
  /// `/Shows/{id}/Episodes` call; see [episodeBefore] / [episodeAfter]).
  Future<({JellyfinItem? previous, JellyfinItem? next})> adjacentEpisodes(
      JellyfinItem episode) async {
    final seriesId = episode.seriesId;
    if (seriesId == null) return (previous: null, next: null);
    final list = await episodes(seriesId);
    return (previous: episodeBefore(list, episode.id), next: episodeAfter(list, episode.id));
  }

  // -------------------------------------------------------------- images

  /// Image URL for caching and display. Images need no token on Jellyfin,
  /// so this URL is safe to share. [tag] makes the URL change when the image
  /// does; [maxWidth] / [maxHeight] let the server scale down.
  Uri imageUrl(JellyfinImageRef ref, {int? maxWidth, int? maxHeight, int quality = 90}) {
    final idx = ref.type == JellyfinImageType.backdrop ? '/${ref.index}' : '';
    return _uri('/Items/${ref.itemId}/Images/${ref.type.apiName}$idx', {
      'tag': ref.tag,
      if (maxWidth != null) 'maxWidth': '$maxWidth',
      if (maxHeight != null) 'maxHeight': '$maxHeight',
      'quality': '$quality',
    });
  }

  /// User avatar URL, or null if the user has none.
  Uri? userImageUrl(JellyfinUser user, {int maxWidth = 96}) => user.primaryImageTag == null
      ? null
      : _uri('/Users/${user.id}/Images/Primary', {'tag': user.primaryImageTag!, 'maxWidth': '$maxWidth'});

  // ------------------------------------------------------------ playback

  /// `POST /Items/{id}/PlaybackInfo` asking for direct play only. The
  /// [JellyfinPlaybackInfo.playSessionId] ties the progress reports
  /// together; pick the source with [JellyfinPlaybackInfo.primarySource].
  Future<JellyfinPlaybackInfo> playbackInfo(String itemId, {String? mediaSourceId}) async =>
      JellyfinPlaybackInfo.fromJson(_map(await _json('POST', '/Items/$itemId/PlaybackInfo', query: {
        'userId': _uid,
        if (mediaSourceId != null) 'mediaSourceId': mediaSourceId,
      }, body: {
        'UserId': _uid,
        if (mediaSourceId != null) 'MediaSourceId': mediaSourceId,
        'EnableDirectPlay': true,
        'EnableDirectStream': true,
        'EnableTranscoding': false,
      })));

  /// The original file, byte-range capable (206), for mpv:
  /// `/Videos/{id}/stream?static=true&mediaSourceId=...&api_key=TOKEN`.
  /// The token is in the URL, so do not log or share it; mpv can instead
  /// take [shareableStreamUrl] plus [authHeaders] as http-header-fields.
  Uri streamUrl(String itemId, {String? mediaSourceId}) =>
      authorizeUrl(shareableStreamUrl(itemId, mediaSourceId: mediaSourceId));

  /// Same as [streamUrl] without credentials: safe to send to other viewers
  /// or the sync server, each of which adds its own ([authorizeUrl]).
  Uri shareableStreamUrl(String itemId, {String? mediaSourceId}) =>
      _uri('/Videos/$itemId/stream', {
        'static': 'true',
        'mediaSourceId': mediaSourceId ?? itemId,
      });

  /// [url] plus this client's token as `api_key` (replacing any present).
  Uri authorizeUrl(Uri url) {
    final token = accessToken;
    if (token == null) throw const JellyfinException('not signed in', statusCode: 401);
    return url.replace(queryParameters: {...url.queryParameters, 'api_key': token});
  }

  /// Headers that authenticate a request without a token in the URL.
  Map<String, String> get authHeaders =>
      {'Authorization': clientInfo.authorizationHeader(accessToken)};

  // ------------------------------------------------------------ progress

  /// `POST /Sessions/Playing`: playback started (Jellyfin shows the session
  /// as playing and starts tracking the item).
  Future<void> reportPlaybackStart(JellyfinPlaybackReport r) =>
      _json('POST', '/Sessions/Playing', body: r.toProgressJson());

  /// `POST /Sessions/Playing/Progress`: position, pause state and tracks.
  /// Jellyfin saves the resume position from these.
  Future<void> reportPlaybackProgress(JellyfinPlaybackReport r) =>
      _json('POST', '/Sessions/Playing/Progress', body: r.toProgressJson());

  /// `POST /Sessions/Playing/Stopped`: ends the session. The server then
  /// marks the item played if the position is past its "max resume" share
  /// (90% by default), keeps it as a resume point between 5% and 90%, and
  /// clears the position below 5%.
  Future<void> reportPlaybackStopped(JellyfinPlaybackReport r) =>
      _json('POST', '/Sessions/Playing/Stopped', body: r.toStoppedJson());

  /// The user's state for one item.
  Future<JellyfinUserData> userData(String itemId) async => JellyfinUserData.fromJson(
      _map(await _json('GET', '/UserItems/$itemId/UserData', query: {'userId': _uid})));

  /// Marks an item (or a whole season/series) watched.
  Future<JellyfinUserData> markPlayed(String itemId) async => JellyfinUserData.fromJson(
      _map(await _json('POST', '/UserPlayedItems/$itemId', query: {'userId': _uid})));

  /// Marks an item unwatched. This also resets play count, last played date
  /// and resume position.
  Future<JellyfinUserData> markUnplayed(String itemId) async => JellyfinUserData.fromJson(
      _map(await _json('DELETE', '/UserPlayedItems/$itemId', query: {'userId': _uid})));

  /// Sets the resume position without a playback session.
  Future<void> setResumePosition(String itemId, int positionTicks) =>
      _json('POST', '/UserItems/$itemId/UserData',
          query: {'userId': _uid}, body: {'PlaybackPositionTicks': positionTicks});

  /// Removes the item from Continue Watching.
  Future<void> clearResumePosition(String itemId) => setResumePosition(itemId, 0);

  // ------------------------------------------------------------- plumbing

  String get _uid {
    final id = userId;
    if (id == null) throw const JellyfinException('not signed in', statusCode: 401);
    return id;
  }

  Uri _uri(String path, [Map<String, String>? query]) {
    final uri = Uri.parse('$baseUrl$path');
    return query == null || query.isEmpty ? uri : uri.replace(queryParameters: query);
  }

  Future<Object?> _json(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
    bool auth = true,
  }) async {
    final uri = _uri(path, query);
    final res = await _http.send(
      method,
      uri,
      headers: {
        'Authorization': clientInfo.authorizationHeader(auth ? accessToken : null),
        'Accept': 'application/json',
      },
      body: body == null ? null : jsonEncode(body),
    );
    if (!res.ok) {
      final detail = res.body.length > 200 ? res.body.substring(0, 200) : res.body;
      throw JellyfinException('$method $path -> ${res.statusCode} $detail'.trim(),
          statusCode: res.statusCode);
    }
    if (res.body.trim().isEmpty) return null;
    try {
      return jsonDecode(res.body);
    } on FormatException {
      throw JellyfinException('$method $path: response is not JSON', statusCode: res.statusCode);
    }
  }

  static Map<String, dynamic> _map(Object? v) =>
      v is Map ? v.cast<String, dynamic>() : const {};
}

/// The successor of [episodeId] in [episodes] (a series' episode list in
/// airing order, as `/Shows/{id}/Episodes` returns it), crossing seasons.
/// Other copies of the same episode (same season and episode number, e.g.
/// two files of one episode) are skipped. Null when [episodeId] is last or
/// not in the list.
JellyfinItem? episodeAfter(List<JellyfinItem> episodes, String episodeId) {
  final at = episodes.indexWhere((e) => e.id == episodeId);
  if (at < 0) return null;
  final cur = episodes[at];
  for (var i = at + 1; i < episodes.length; i++) {
    final e = episodes[i];
    final sameEpisode = cur.indexNumber != null &&
        e.indexNumber == cur.indexNumber &&
        e.parentIndexNumber == cur.parentIndexNumber;
    if (!sameEpisode) return e;
  }
  return null;
}

/// The predecessor of [episodeId] in [episodes], the mirror of
/// [episodeAfter]: crossing seasons, skipping other copies of the same
/// episode. Null when it is first or not in the list.
JellyfinItem? episodeBefore(List<JellyfinItem> episodes, String episodeId) {
  final at = episodes.indexWhere((e) => e.id == episodeId);
  if (at < 0) return null;
  final cur = episodes[at];
  for (var i = at - 1; i >= 0; i--) {
    final e = episodes[i];
    final sameEpisode = cur.indexNumber != null &&
        e.indexNumber == cur.indexNumber &&
        e.parentIndexNumber == cur.parentIndexNumber;
    if (!sameEpisode) return e;
  }
  return null;
}
