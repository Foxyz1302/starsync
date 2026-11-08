import 'dart:async';

import 'package:sync_relay_core/core.dart' show JellyfinItem, normalizeSeries;

import '../library/show_matcher.dart' show seasonMarker, titleSimilarity;
import 'anilist.dart';
import 'schedule_model.dart';

// The Schedule's own AniList -> Jellyfin link, for every linked account,
// with or without AnimeFlow (ARCHITECTURE "Desktop UI", Schedule). One
// light walk of each library's series ([SeriesIndexCache]) is matched per
// AniList entry ([JellyfinSeriesMatcher]): a provider id first (AniList,
// MyAnimeList), else the names, with the library matcher's similarity.
// Where the entry's episodes sit in the series (TVDB season and offset,
// split cours included) comes from the series' episodes ([placeRun]): the
// one premiered on an airing's Japan day, else the entry's season marker.

/// One series of a linked Jellyfin library, as the Schedule matches it.
class JellyfinSeriesInfo {
  final String serverId;
  final String id;
  final String name;
  /// Its own-language title (Japanese for anime), when the metadata has one.
  final String? originalTitle;
  /// The year it started.
  final int? year;
  /// `AniList`, `Tvdb`, `Tmdb`, `Imdb`, `AniDB`... as the server's
  /// metadata plugins set them.
  final Map<String, String> providerIds;

  const JellyfinSeriesInfo({
    required this.serverId,
    required this.id,
    required this.name,
    this.originalTitle,
    this.year,
    this.providerIds = const {},
  });

  factory JellyfinSeriesInfo.fromItem(String serverId, JellyfinItem i) => JellyfinSeriesInfo(
        serverId: serverId,
        id: i.id,
        name: i.name,
        originalTitle: i.originalTitle,
        year: i.productionYear,
        providerIds: i.providerIds,
      );

  @override
  String toString() => 'JellyfinSeriesInfo($id "$name")';
}

/// How sure a match is.
enum SeriesMatchKind {
  /// The series carries the entry's AniList or MyAnimeList id.
  providerId,

  /// A name is the same, or the series' names start the entry's ones
  /// ("The Apothecary Diaries" for "... Season 3") in two of its names or
  /// before a season word.
  title,

  /// One name of the series starts one of the entry's, nothing more: kept
  /// only when an episode premiered on an airing's day ([placeRun]).
  weakTitle,
}

class JellyfinSeriesMatch {
  final JellyfinSeriesInfo series;
  final SeriesMatchKind kind;
  const JellyfinSeriesMatch(this.series, this.kind);

  @override
  String toString() => 'JellyfinSeriesMatch(${series.name}, ${kind.name})';
}

// After a series' name, what makes the rest one season of it.
final _seasonRest = RegExp(r'^(?:part \d+|cour \d+|第\d+期|第\d+クール|\d+(?: |$))');

/// Matches AniList entries to the series of [series] (linked accounts in
/// order of preference: the first one wins a tie). Answers are memoised
/// per AniList id for this index.
class JellyfinSeriesMatcher {
  JellyfinSeriesMatcher(this.series) {
    for (final s in series) {
      for (final e in s.providerIds.entries) {
        final v = int.tryParse(e.value.trim());
        if (v == null) continue;
        switch (e.key.toLowerCase()) {
          case 'anilist':
            _byAniList.putIfAbsent(v, () => s);
          case 'mal' || 'myanimelist':
            _byMal.putIfAbsent(v, () => s);
        }
      }
      final names = {
        for (final n in [s.name, ?s.originalTitle]) normalizeSeries(n),
      }..remove('');
      _names.add((s, names.toList()));
      for (final n in names) {
        (_exact[n] ??= []).add(s);
      }
    }
  }

  final List<JellyfinSeriesInfo> series;
  final _byAniList = <int, JellyfinSeriesInfo>{};
  final _byMal = <int, JellyfinSeriesInfo>{};
  final _exact = <String, List<JellyfinSeriesInfo>>{};
  final _names = <(JellyfinSeriesInfo, List<String>)>[];
  final _memo = <int, JellyfinSeriesMatch?>{};

  /// The series [a]'s AniList entry is part of, or null.
  JellyfinSeriesMatch? match(Airing a) => _memo.putIfAbsent(a.anilistId, () => _match(a));

  JellyfinSeriesMatch? _match(Airing a) {
    if (_byAniList[a.anilistId] case final s?) return JellyfinSeriesMatch(s, SeriesMatchKind.providerId);
    if (_byMal[a.idMal] case final s?) return JellyfinSeriesMatch(s, SeriesMatchKind.providerId);
    // A series that started after this airing is not it.
    bool fits(JellyfinSeriesInfo s) => s.year == null || s.year! <= a.airingAt.toUtc().year;
    final all = {for (final n in a.names) normalizeSeries(n)}..remove('');
    for (final n in all) {
      for (final s in _exact[n] ?? const <JellyfinSeriesInfo>[]) {
        if (fits(s)) return JellyfinSeriesMatch(s, SeriesMatchKind.title);
      }
    }
    // The series is the show, the entry one season of it: the series'
    // name starts the entry's (its main names only: synonyms hold every
    // translation, too loose for a prefix).
    final main = {
      for (final n in [a.title, a.titleRomaji, a.titleNative]) normalizeSeries(n),
    }..remove('');
    JellyfinSeriesMatch? best;
    var bestScore = 0.0;
    for (final (s, names) in _names) {
      if (!fits(s)) continue;
      var support = 0;
      var seasonal = false;
      var score = 0.0;
      for (final sn in names) {
        var hit = false;
        for (final n in main) {
          if (!n.startsWith('$sn ')) continue;
          hit = true;
          final rest = n.substring(sn.length + 1);
          if (seasonMarker(AniListEntry(id: 0, english: rest)) != null || _seasonRest.hasMatch(rest)) seasonal = true;
          final sim = titleSimilarity(n, sn);
          if (sim > score) score = sim;
        }
        if (hit) support++;
      }
      if (support == 0) continue;
      final kind = support >= 2 || seasonal ? SeriesMatchKind.title : SeriesMatchKind.weakTitle;
      final better = best == null ||
          (kind == SeriesMatchKind.title && best.kind == SeriesMatchKind.weakTitle) ||
          (kind == best.kind && score > bestScore);
      if (better) {
        best = JellyfinSeriesMatch(s, kind);
        bestScore = score;
      }
    }
    return best;
  }
}

/// The season number an airing's names carry: `Season 3`, `3rd Season`,
/// `第3期`; null when none does.
int? seasonHintOf(Airing a) {
  final marker = seasonMarker(
      AniListEntry(id: a.anilistId, english: a.title, romaji: a.titleRomaji, native: a.titleNative));
  if (marker != null) return marker;
  final m = RegExp(r'第(\d{1,2})期').firstMatch(a.titleNative);
  return m == null ? null : int.parse(m.group(1)!);
}

/// Where an AniList entry's episodes are in a Jellyfin series: Jellyfin
/// episode = AniList episode + [offset] in [season].
class RunPlacement {
  final int season;
  final int offset;

  /// Found from the air days of the episodes Jellyfin has; otherwise a
  /// guess (the season marker, else the latest season, offset 0).
  final bool anchored;
  const RunPlacement(this.season, this.offset, {this.anchored = false});

  @override
  bool operator ==(Object other) =>
      other is RunPlacement && other.season == season && other.offset == offset && other.anchored == anchored;
  @override
  int get hashCode => Object.hash(season, offset, anchored);
  @override
  String toString() => 'RunPlacement(S$season +$offset${anchored ? ' anchored' : ''})';
}

/// A premiere date worth comparing (servers send 1970 for unknown ones).
DateTime? sanePremiere(DateTime? d) => d != null && d.year >= 1980 ? d : null;

/// Places one AniList entry ([airings]: its episodes in the window) in a
/// series Jellyfin has [have] of: each aired airing whose Japan day
/// exactly one episode premiered on votes for (that season, its number -
/// the AniList one), the most votes win (a split cour's part 2 lands on
/// its season with the first part's count as offset). With no such day,
/// [seasonHint] (else the latest season) and offset 0, not anchored.
RunPlacement placeRun(List<Airing> airings, List<JellyfinEpisodeRef> have, {required DateTime now, int? seasonHint}) {
  final eps = [for (final x in have) if (x.season > 0) x];
  final votes = <(int, int), int>{};
  for (final a in airings) {
    if (a.airingAt.isAfter(now)) continue;
    final same = [
      for (final x in eps)
        if (sanePremiere(x.premiere) case final p? when sameAirDay(p, a.airingAt)) x,
    ];
    if (same.length != 1) continue;
    final k = (same.single.season, same.single.episode - a.episode);
    votes[k] = (votes[k] ?? 0) + 1;
  }
  if (votes.isNotEmpty) {
    final best = votes.entries.reduce((a, b) => b.value > a.value ? b : a).key;
    return RunPlacement(best.$1, best.$2, anchored: true);
  }
  final seasons = [for (final x in eps) x.season];
  final season = seasonHint ?? (seasons.isEmpty ? 1 : seasons.reduce((a, b) => a > b ? a : b));
  return RunPlacement(season, 0);
}

/// An AniList entry's place on a linked Jellyfin: the series, how sure,
/// and where its episodes are (null: unknown, the episodes could not be
/// looked up or none has aired yet).
class DirectMatch {
  final JellyfinSeriesMatch match;
  final RunPlacement? placement;
  const DirectMatch(this.match, this.placement);

  JellyfinSeriesInfo get series => match.series;
}

/// Matches every AniList entry of [airings] to [series] ([matcher]) and
/// places it ([placeRun]) with the episodes [episodes] gives (the series'
/// of entries with an aired episode, looked up in parallel; null: could
/// not tell). A weak title match is kept only when an air day anchors it.
Future<Map<int, DirectMatch>> matchDirect(
  List<Airing> airings,
  JellyfinSeriesMatcher matcher, {
  required JellyfinEpisodeLookup episodes,
  required DateTime now,
}) async {
  final byId = <int, List<Airing>>{};
  for (final a in airings) {
    (byId[a.anilistId] ??= []).add(a);
  }
  final matches = <int, JellyfinSeriesMatch>{};
  for (final MapEntry(key: id, value: list) in byId.entries) {
    if (matcher.match(list.first) case final m?) matches[id] = m;
  }
  bool aired(int id) => byId[id]!.any((a) => !a.airingAt.isAfter(now));
  final keys = {
    for (final MapEntry(key: id, value: m) in matches.entries)
      if (aired(id)) (m.series.serverId, m.series.id),
  };
  final found = <(String, String), List<JellyfinEpisodeRef>>{};
  await Future.wait([
    for (final k in keys)
      episodes(k.$1, k.$2).then((eps) {
        if (eps != null) found[k] = eps;
      }, onError: (_) {}),
  ]);
  final out = <int, DirectMatch>{};
  for (final MapEntry(key: id, value: m) in matches.entries) {
    final have = found[(m.series.serverId, m.series.id)];
    final list = byId[id]!;
    final placed = have == null ? null : placeRun(list, have, now: now, seasonHint: seasonHintOf(list.first));
    if (m.kind == SeriesMatchKind.weakTitle && !(placed?.anchored ?? false)) continue;
    out[id] = DirectMatch(m, placed);
  }
  // One Jellyfin episode is one AniList episode: a weak match landing on
  // episodes a surer one claims is a companion airing the same day (the
  // show's omake shorts), not that show.
  Iterable<(String, String, int, int)> claims(int id, DirectMatch d) sync* {
    final p = d.placement;
    if (p == null) return;
    for (final a in byId[id]!) {
      if (!a.airingAt.isAfter(now)) yield (d.series.serverId, d.series.id, p.season, a.episode + p.offset);
    }
  }

  final claimed = {
    for (final MapEntry(key: id, value: d) in out.entries)
      if (d.match.kind != SeriesMatchKind.weakTitle) ...claims(id, d),
  };
  out.removeWhere((id, d) => d.match.kind == SeriesMatchKind.weakTitle && claims(id, d).any(claimed.contains));
  return out;
}

/// Each linked account's series ([walk]: one light request per account),
/// kept [ttl]; an ask after that answers with the kept one and walks again
/// in the background (an account never walked, or [series] with force,
/// waits for its walk). A failed walk keeps the last one and is retried
/// after [retryAfter]. [servers] lists the accounts in order of
/// preference.
class SeriesIndexCache {
  SeriesIndexCache({
    required this.servers,
    required this.walk,
    this.ttl = const Duration(minutes: 30),
    this.retryAfter = const Duration(minutes: 5),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final Future<List<String>> Function() servers;
  final Future<List<JellyfinSeriesInfo>> Function(String serverId) walk;
  final Duration ttl;
  final Duration retryAfter;
  final DateTime Function() _now;

  final _kept = <String, ({DateTime at, List<JellyfinSeriesInfo> series})>{};
  final _failedAt = <String, DateTime>{};
  final _inflight = <String, Future<void>>{};
  var _all = const <JellyfinSeriesInfo>[];
  var _allKey = '';

  /// Every linked account's series, preferred account first. The same
  /// list instance while nothing changed (a matcher built on it stays
  /// valid).
  Future<List<JellyfinSeriesInfo>> series({bool force = false}) async {
    final ids = await servers();
    final now = _now();
    bool due(String id) {
      final k = _kept[id], f = _failedAt[id];
      if (f != null && now.difference(f) < retryAfter && !force) return false;
      return force || k == null || now.difference(k.at) >= ttl;
    }

    final wait = <Future<void>>[];
    for (final id in ids) {
      if (!due(id)) continue;
      final f = _refresh(id);
      force || !_kept.containsKey(id) ? wait.add(f) : unawaited(f);
    }
    await Future.wait(wait);
    final key = [for (final id in ids) '$id@${_kept[id]?.at.microsecondsSinceEpoch}'].join(',');
    if (key != _allKey) {
      _allKey = key;
      _all = List.unmodifiable([
        for (final id in ids) ...?_kept[id]?.series,
      ]);
    }
    return _all;
  }

  Future<void> _refresh(String id) {
    if (_inflight[id] case final running?) return running;
    final f = _walkOne(id);
    _inflight[id] = f;
    return f.whenComplete(() {
      if (identical(_inflight[id], f)) _inflight.remove(id);
    });
  }

  Future<void> _walkOne(String id) async {
    try {
      final s = await walk(id);
      _kept[id] = (at: _now(), series: s);
      _failedAt.remove(id);
    } catch (_) {
      _failedAt[id] = _now();
    }
  }
}
