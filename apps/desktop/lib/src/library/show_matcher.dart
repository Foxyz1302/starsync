import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:signals/signals.dart';
import 'package:sync_relay_core/core.dart';

import '../schedule/anilist.dart';
import '../schedule/animeflow.dart';
import 'library_store.dart';

// L2 of the library (ARCHITECTURE.md "Media identity"): local shows (L1)
// matched to AniList, device-owned and cached. A season of a show is
// searched once (title and synonyms, the season's number or name as
// hints) and the answer kept by show key, season and season name; its
// episodes map onto AniList entries along the run (a season AniList
// splits into cours continues on the SEQUEL entry), or onto AnimeFlow's
// `anilist_map` when signed in. The user's pins (a show everywhere, or one
// folder) and episode offsets override everything and survive rescans.
// Requests are lazy (only for shows on screen), one at a time and spaced
// out for AniList's rate limit; everything answers offline from the cache.

/// Where AnimeFlow places an AniList entry: the TVDB season runs of its
/// series ([AniListRun]) and the series' TVDB id.
class FlowShow {
  final List<AniListRun> runs;
  final int? tvdbId;
  const FlowShow(this.runs, {this.tvdbId});
}

/// AnimeFlow's knowledge of a show, when signed in.
abstract interface class FlowLookup {
  /// The series [anilistId] belongs to; null when AnimeFlow has none (or
  /// cannot be asked).
  Future<FlowShow?> forAniList(int anilistId);
}

/// [FlowLookup] over the AnimeFlow app API (`/library`, `/series`), read
/// once per app run.
class AnimeFlowLookup implements FlowLookup {
  final AnimeFlowClient client;
  AnimeFlowLookup(this.client);

  Future<(List<AnimeFlowLibraryItem>, List<AnimeFlowSeries>)>? _load;

  Future<(List<AnimeFlowLibraryItem>, List<AnimeFlowSeries>)> _fetch() async =>
      (await client.library(), await client.series());

  @override
  Future<FlowShow?> forAniList(int anilistId) async {
    final load = _load ??= _fetch();
    final (List<AnimeFlowLibraryItem>, List<AnimeFlowSeries>) data;
    try {
      data = await load;
    } catch (e) {
      _load = null;
      return null;
    }
    final (library, series) = data;
    for (final item in library) {
      final has = item.anilistMap.any((r) => r.anilistId == anilistId) || item.anilistIds.values.contains(anilistId);
      if (!has) continue;
      final s = series
          .where((s) =>
              (item.seriesId != null && s.seriesId == item.seriesId) ||
              (s.jellyfinSeriesId != null && s.jellyfinSeriesId == item.jellyfinSeriesId))
          .firstOrNull;
      return FlowShow(item.anilistMap, tvdbId: s?.tvdbId);
    }
    return null;
  }
}

/// What a pin covers.
enum PinScope { show, folder }

/// The AniList entry a season (or a movie, or an extra's show) is.
class SeasonMatch {
  final AniListEntry entry;

  /// Set by the user ("Wrong show?"), not by the search.
  final PinScope? pinned;
  const SeasonMatch(this.entry, {this.pinned});
}

/// An episode on AniList.
class EpisodeTarget {
  final int anilistId;
  final int? anilistEp;
  const EpisodeTarget(this.anilistId, this.anilistEp);

  @override
  bool operator ==(Object other) => other is EpisodeTarget && other.anilistId == anilistId && other.anilistEp == anilistEp;
  @override
  int get hashCode => Object.hash(anilistId, anilistEp);
  @override
  String toString() => 'EpisodeTarget($anilistId, $anilistEp)';
}

/// The library's L2: see the file comment. Made by the composition root.
class ShowMatcher {
  ShowMatcher({
    required this.store,
    required this.aniList,
    this.flow,
    this.spacing = const Duration(milliseconds: 800),
    this.retryNoneAfter = const Duration(days: 3),
    DateTime Function()? now,
    Future<void> Function(Duration)? delay,
  })  : _now = now ?? DateTime.now,
        _delay = delay ?? Future<void>.delayed;

  final LibraryStore store;
  final AniListLookup aniList;
  final FlowLookup? flow;

  /// Between two AniList requests.
  final Duration spacing;

  /// A search that found nothing is asked again after this.
  final Duration retryNoneAfter;
  final DateTime Function() _now;
  final Future<void> Function(Duration) _delay;

  /// Bumps whenever something new is known (a match, an entry, a pin).
  final revision = signal(0);

  /// Shows being matched right now, by show key.
  final busy = signal<Set<String>>(const {});

  // Files seen in scans this run, for refs of files put up.
  final _byPath = <String, LocalEpisode>{};
  final _entries = <int, AniListEntry>{};
  final _flows = <int, FlowShow?>{};
  final _jobs = <String, Future<void> Function()>{};
  final _failed = <String, DateTime>{};
  bool _pumping = false;
  DateTime? _lastRequest;
  DateTime? _pausedUntil;

  /// Loads the cache (once); reads before it finishes see nothing.
  Future<void> ensureLoaded() => store.ensureLoaded().then((_) => _bump());

  // ------------------------------------------------------------- keys

  static String matchKey(String showKey, int? season, String? seasonName) =>
      '$showKey|${season ?? ''}|${normalizeSeries(seasonName ?? '')}';

  static String _movieKey(LocalEpisode e) => '${e.showKey}|movie|${e.movieNumber ?? ''}';

  String _keyOf(LocalEpisode e) =>
      e.kind == LocalKind.movie ? _movieKey(e) : matchKey(e.showKey, e.season, e.seasonName);

  // ------------------------------------------------------------- reads

  /// Remembers [library]'s files, so [refForPath] knows their show.
  void remember(LocalLibrary library) {
    for (final e in library.files) {
      _byPath[e.path] = e;
    }
  }

  AniListEntry? entry(int id) {
    final known = _entries[id];
    if (known != null) return known;
    final raw = store.get('entry:$id');
    final e = raw is Map ? AniListEntry.fromJson(raw['e']) : null;
    if (e != null) _entries[id] = e;
    return e;
  }

  /// The user's pin for [showKey] (everywhere), if any.
  int? showPin(String showKey) => _int(store.get('pin:show:$showKey'));

  /// The pin of [folder] or the nearest folder above it, if any.
  ({String folder, int id})? folderPin(String folder) {
    var f = folder;
    while (f.isNotEmpty) {
      final id = _int(store.get('pin:folder:$f'));
      if (id != null) return (folder: f, id: id);
      final cut = f.lastIndexOf(RegExp(r'[/\\]'));
      if (cut <= 0) break;
      f = f.substring(0, cut);
    }
    return null;
  }

  /// "These files are episodes N..": added to every file's number of
  /// [showKey]'s season [season].
  int offset(String showKey, int? season) => _int(store.get('offset:$showKey|${season ?? ''}')) ?? 0;

  /// The entry [e]'s season (or movie, or the show of an extra) is: a
  /// folder pin, else the show's pin, else the search's answer.
  SeasonMatch? seasonMatch(LocalEpisode e) {
    if (e.kind == LocalKind.other) return null;
    final fp = folderPin(e.folder);
    if (fp != null) {
      final en = entry(fp.id);
      return en == null ? null : SeasonMatch(en, pinned: PinScope.folder);
    }
    final sp = showPin(e.showKey);
    if (sp != null) {
      final en = entry(sp);
      return en == null ? null : SeasonMatch(en, pinned: PinScope.show);
    }
    final auto = store.get('auto:${_keyOf(e)}');
    final id = auto is Map ? _int(auto['id']) : null;
    if (id == null) {
      // An extra of no matched season: the show's first one.
      if (e.kind == LocalKind.extra && e.season != null) {
        return seasonMatch(LocalEpisode(
            file: e.file, parsed: e.parsed, kind: LocalKind.extra, showKey: e.showKey, title: e.title, extra: e.extra));
      }
      return null;
    }
    final en = entry(id);
    return en == null ? null : SeasonMatch(en);
  }

  /// What the show is as a whole: its first season's match (else a
  /// movie's or an extra's).
  SeasonMatch? showMatch(LocalShow show) {
    for (final e in [
      for (final s in show.seasons) s.episodes.first,
      ...show.movies,
      ...show.extras,
    ]) {
      final m = seasonMatch(e);
      if (m != null) return m;
    }
    return null;
  }

  /// The proper name of [show]: its match's title, else as found.
  String titleOf(LocalShow show) => showMatch(show)?.entry.title ?? show.title;

  /// The AniList entry and episode [e] is; for extras and movies only the
  /// entry. Null before a match.
  EpisodeTarget? target(LocalEpisode e) {
    final m = seasonMatch(e);
    if (m == null) return null;
    if (e.kind != LocalKind.episode) return EpisodeTarget(m.entry.id, null);
    final n = e.episode! + offset(e.showKey, e.season);
    if (n < 1) return EpisodeTarget(m.entry.id, null);
    final fs = _flowOf(m.entry.id);
    if (fs != null && e.season != null) {
      final runs = fs.runs.where((r) => r.season == e.season && r.firstEpisode <= n).toList()
        ..sort((a, b) => b.firstEpisode.compareTo(a.firstEpisode));
      if (runs.isNotEmpty) return EpisodeTarget(runs.first.anilistId, n - runs.first.offset);
    }
    // Along the run: past an entry's episodes, its sequel's.
    var cur = m.entry;
    var k = n;
    for (var hop = 0; hop < 30; hop++) {
      final count = cur.episodes;
      final next = cur.sequel;
      if (count == null || k <= count || next == null) break;
      k -= count;
      final nx = entry(next);
      if (nx == null) {
        _wantEntry(next);
        return EpisodeTarget(next, k);
      }
      cur = nx;
    }
    return EpisodeTarget(cur.id, k);
  }

  /// AniList's title of [e]'s episode, when it knows one.
  String? episodeTitle(LocalEpisode e) {
    final t = target(e);
    final ep = t?.anilistEp;
    if (t == null || ep == null) return null;
    return entry(t.anilistId)?.episodeTitles[ep];
  }

  /// What [e] is on the wire (`media.ref`): the match when there is one,
  /// else what L1 read (kind, title, numbers).
  MediaRef refFor(LocalEpisode e) {
    final m = seasonMatch(e);
    final t = target(e);
    final n = e.episode == null ? null : e.episode! + offset(e.showKey, e.season);
    final tvdb = m == null ? null : _flowOf(m.entry.id)?.tvdbId;
    return MediaRef(
      kind: switch (e.kind) {
        LocalKind.episode => 'episode',
        LocalKind.extra => 'extra',
        LocalKind.movie || LocalKind.other => 'movie',
      },
      title: m?.entry.title ?? e.title,
      anilistId: t?.anilistId ?? m?.entry.id,
      anilistEp: t?.anilistEp,
      tvdbId: tvdb,
      season: e.kind == LocalKind.episode ? e.season : null,
      ep: e.kind == LocalKind.episode && e.season != null ? n : null,
      absolute: e.kind == LocalKind.episode && e.season == null ? n : null,
    );
  }

  /// [refFor] the file at [path]: as seen in a scan this run, else read
  /// from its name and folder alone.
  MediaRef refForPath(String path) =>
      refFor(_byPath[path] ?? readLocalFile(LocalFile(path, 0, DateTime.fromMillisecondsSinceEpoch(0))));

  /// The library's reading of [path] (null: not seen in a scan this run).
  LocalEpisode? episodeAt(String path) => _byPath[path];

  // ------------------------------------------------------------- matching

  /// Matches [show]'s seasons and movies that have no answer yet, in the
  /// background (see the file comment).
  void want(LocalShow show) {
    final seen = <String>{};
    for (final e in [
      for (final s in show.seasons) s.episodes.first,
      ...show.movies,
      if (show.seasons.isEmpty) ...show.extras.take(1),
    ]) {
      final key = _keyOf(e);
      if (!seen.add(key)) continue;
      final pinned = folderPin(e.folder)?.id ?? showPin(e.showKey);
      if (pinned != null) {
        if (entry(pinned) == null) _wantEntry(pinned);
        continue;
      }
      _wantMatch(key, show, e);
    }
    final m = showMatch(show);
    if (m != null) _wantFlow(m.entry.id);
  }

  /// [want] for each standalone movie of [library] and each of [shows].
  void wantMovie(LocalEpisode movie) {
    if (movie.kind != LocalKind.movie) return;
    _wantMatch(_movieKey(movie), null, movie);
  }

  void _wantMatch(String key, LocalShow? show, LocalEpisode e) {
    final auto = store.get('auto:$key');
    if (auto is Map) {
      final id = _int(auto['id']);
      if (id != null) {
        if (entry(id) == null) _wantEntry(id);
        return;
      }
      final at = _int(auto['at']) ?? 0;
      if (_now().difference(DateTime.fromMillisecondsSinceEpoch(at)) < retryNoneAfter) return;
    }
    if (_recentlyFailed(key)) return;
    _enqueue('match:$key', () => _match(key, show?.title ?? e.title, e));
    _setBusy(e.showKey, true);
  }

  void _wantEntry(int id) {
    if (_recentlyFailed('entry:$id')) return;
    _enqueue('entry:$id', () async {
      final en = await _ask(() => aniList.anime(id));
      if (en != null) _keepEntry(en);
    });
  }

  void _wantFlow(int id) {
    final f = flow;
    if (f == null || _flows.containsKey(id)) return;
    final stored = store.get('flow:$id');
    if (stored is Map) {
      _flows[id] = _flowFromJson(stored);
      final at = _int(stored['at']) ?? 0;
      if (_now().difference(DateTime.fromMillisecondsSinceEpoch(at)) < const Duration(days: 1)) return;
    } else {
      _flows[id] = null;
    }
    unawaited(f.forAniList(id).then((fs) {
      if (fs == null) return;
      _flows[id] = fs;
      store.put('flow:$id', {
        'at': _now().millisecondsSinceEpoch,
        'tvdb': fs.tvdbId,
        'runs': [
          for (final r in fs.runs) [r.season, r.anilistId, r.firstEpisode, r.offset]
        ],
      });
      _bump();
    }).catchError((Object e) => debugPrint('library: animeflow lookup $id: $e')));
  }

  FlowShow? _flowOf(int id) {
    if (!_flows.containsKey(id)) {
      final stored = store.get('flow:$id');
      if (stored is Map) _flows[id] = _flowFromJson(stored);
    }
    return _flows[id];
  }

  static FlowShow? _flowFromJson(Map j) {
    final runs = <AniListRun>[];
    final raw = j['runs'];
    if (raw is List) {
      for (final r in raw) {
        if (r is List && r.length == 4 && r.every((v) => v is int)) {
          runs.add(AniListRun(
              season: r[0] as int, anilistId: r[1] as int, firstEpisode: r[2] as int, offset: r[3] as int));
        }
      }
    }
    return runs.isEmpty ? null : FlowShow(runs, tvdbId: _int(j['tvdb']));
  }

  /// One search for the season [e] stands for; keeps the best entry (or
  /// "none") under [key].
  Future<void> _match(String key, String title, LocalEpisode e) async {
    try {
      final plain = title.replaceAll(RegExp(r'[._]+'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
      final movie = e.kind == LocalKind.movie;
      final season = movie ? null : e.season;
      final name = movie ? null : e.seasonName;
      final query = [
        plain,
        if (name != null) name else if (season != null && season > 1) 'season $season',
      ].join(' ');
      var hits = await _ask(() => aniList.searchAnime(query));
      var best = pickMatch(hits, title: plain, season: season, seasonName: name, movie: movie);
      if (best == null && query != plain) {
        hits = await _ask(() => aniList.searchAnime(plain));
        best = pickMatch(hits, title: plain, season: season, seasonName: name, movie: movie);
        // Found the show but not the season: walk its sequels.
        if (best != null && season != null && season > 1 && name == null && seasonMarker(best) != season) {
          var cur = best;
          for (var hop = 1; hop < season; hop++) {
            final next = cur.sequel;
            if (next == null) break;
            final nx = entry(next) ?? await _ask(() => aniList.anime(next));
            if (nx == null) break;
            _keepEntry(nx);
            cur = nx;
          }
          best = cur;
        }
      }
      for (final h in hits) {
        if (h.id == best?.id) _keepEntry(h);
      }
      store.put('auto:$key', {'id': best?.id, 'at': _now().millisecondsSinceEpoch});
      if (best != null) _wantFlow(best.id);
      _bump();
    } finally {
      _setBusy(e.showKey, false);
    }
  }

  /// "Wrong show?": AniList's answers for [query], best first.
  Future<List<AniListEntry>> search(String query) async {
    final hits = await _ask(() => aniList.searchAnime(query));
    return hits;
  }

  // ------------------------------------------------------------- corrections

  /// Pins [showKey] to [e] everywhere (every folder, every rescan).
  void pinShow(String showKey, AniListEntry e) {
    _keepEntry(e);
    store.put('pin:show:$showKey', e.id);
    _wantFlow(e.id);
    _bump();
  }

  /// Pins every video in [folder] (and below) to [e].
  void pinFolder(String folder, AniListEntry e) {
    _keepEntry(e);
    store.put('pin:folder:$folder', e.id);
    _wantFlow(e.id);
    _bump();
  }

  void unpinShow(String showKey) {
    store.delete('pin:show:$showKey');
    _bump();
  }

  void unpinFolder(String folder) {
    store.delete('pin:folder:$folder');
    _bump();
  }

  /// "These files are episodes N..": [offset] is added to the file
  /// numbers of [showKey]'s season [season] (0 removes it).
  void setOffset(String showKey, int? season, int offset) {
    final key = 'offset:$showKey|${season ?? ''}';
    offset == 0 ? store.delete(key) : store.put(key, offset);
    _bump();
  }

  /// Forgets the automatic match of [show] so it is searched again.
  void rematch(LocalShow show) {
    for (final k in store.keys('auto:${show.key}|').toList()) {
      store.delete(k);
    }
    want(show);
    _bump();
  }

  // ------------------------------------------------------------- plumbing

  void _keepEntry(AniListEntry e) {
    _entries[e.id] = e;
    store.put('entry:${e.id}', {'at': _now().millisecondsSinceEpoch, 'e': e.toJson()});
    _bump();
  }

  void _bump() => revision.value++;

  void _setBusy(String showKey, bool on) {
    final now = {...busy.peek()};
    if (on ? now.add(showKey) : now.remove(showKey)) busy.value = now;
  }

  bool _recentlyFailed(String key) {
    final at = _failed[key];
    return at != null && _now().difference(at) < const Duration(minutes: 5);
  }

  void _enqueue(String key, Future<void> Function() job) {
    if (_jobs.containsKey(key)) return;
    _jobs[key] = () => job().catchError((Object e) {
          _failed[key] = _now();
          debugPrint('library: $key failed: $e');
          if (e is AniListException && e.isRateLimited) _pausedUntil = _now().add(const Duration(minutes: 1));
        });
    if (!_pumping) unawaited(_pump());
  }

  Future<void> _pump() async {
    _pumping = true;
    try {
      while (_jobs.isNotEmpty) {
        final key = _jobs.keys.first;
        final job = _jobs[key]!;
        await job();
        _jobs.remove(key);
      }
    } finally {
      _pumping = false;
    }
  }

  /// One AniList request, spaced from the last one (and after a rate
  /// limit's pause).
  Future<T> _ask<T>(Future<T> Function() request) async {
    final paused = _pausedUntil;
    if (paused != null && paused.isAfter(_now())) await _delay(paused.difference(_now()));
    final last = _lastRequest;
    if (last != null) {
      final wait = spacing - _now().difference(last);
      if (wait > Duration.zero) await _delay(wait);
    }
    _lastRequest = _now();
    return request();
  }

  @visibleForTesting
  bool get idle => _jobs.isEmpty && !_pumping;

  static int? _int(Object? v) => v is int ? v : null;
}

// ------------------------------------------------------------------ scoring

/// The season number an entry's names carry (`Season 2`, `2nd Season`,
/// `Part 2` is not one); null when none does.
int? seasonMarker(AniListEntry e) {
  for (final n in e.names) {
    final s = _seasonOf(normalizeSeries(n));
    if (s != null) return s;
  }
  return null;
}

final _seasonWords = RegExp(r'\b(?:season (\d{1,2})|(\d{1,2})(?:st|nd|rd|th) season|s(\d{1,2}))\b');
final _roman = {'ii': 2, 'iii': 3, 'iv': 4, 'v': 5, 'vi': 6};

int? _seasonOf(String normalized) {
  final m = _seasonWords.firstMatch(normalized);
  if (m != null) return int.parse(m.group(1) ?? m.group(2) ?? m.group(3)!);
  final last = normalized.split(' ').last;
  return _roman[last];
}

/// How alike two normalized titles are, 0..1.
double titleSimilarity(String a, String b) {
  if (a.isEmpty || b.isEmpty) return 0;
  if (a == b) return 1;
  final short = a.length <= b.length ? a : b;
  final long = a.length <= b.length ? b : a;
  final ratio = short.length / long.length;
  if (long.startsWith('$short ')) return 0.8 + 0.2 * ratio;
  if (long.contains(' $short ') || long.endsWith(' $short')) return 0.6 + 0.2 * ratio;
  // Dice over letter pairs, spaces ignored.
  Set<String> pairs(String s) {
    final t = s.replaceAll(' ', '');
    return {for (var i = 0; i + 1 < t.length; i++) t.substring(i, i + 2)};
  }

  final pa = pairs(a), pb = pairs(b);
  if (pa.isEmpty || pb.isEmpty) return 0;
  return 2 * pa.intersection(pb).length / (pa.length + pb.length);
}

/// Scores [e] as the answer for a show called [title] (its season
/// [season] or its season named [seasonName]; a [movie]); [rank]: its
/// place in AniList's own order.
double scoreMatch(AniListEntry e,
    {required String title, int? season, String? seasonName, bool movie = false, int rank = 0}) {
  final q = normalizeSeries(title);
  final full = seasonName == null ? q : normalizeSeries('$title $seasonName');
  var best = 0.0;
  for (final n in e.names) {
    final nn = normalizeSeries(n);
    final s = [titleSimilarity(nn, q), titleSimilarity(nn, full)].reduce((a, b) => a > b ? a : b);
    if (s > best) best = s;
  }
  var score = best;
  if (seasonName != null) {
    final sub = normalizeSeries(seasonName);
    if (e.names.any((n) => normalizeSeries(n).contains(sub))) score += 0.25;
  } else if (!movie) {
    final wanted = season ?? 1;
    final marker = seasonMarker(e);
    if (marker != null && marker == wanted) {
      score += 0.2;
    } else if (marker != null) {
      score -= 0.25;
    } else if (wanted > 1) {
      score -= 0.1;
    }
  }
  if (movie) {
    score += e.isMovie ? 0.15 : -0.25;
  } else {
    score += e.isSeries ? 0.05 : (e.isMovie ? -0.3 : -0.1);
  }
  return score - rank * 0.02;
}

/// The best of [hits] for a show called [title], if any is good enough.
AniListEntry? pickMatch(List<AniListEntry> hits,
    {required String title, int? season, String? seasonName, bool movie = false}) {
  AniListEntry? best;
  var bestScore = 0.55;
  for (var i = 0; i < hits.length; i++) {
    final s = scoreMatch(hits[i], title: title, season: season, seasonName: seasonName, movie: movie, rank: i);
    if (s > bestScore) {
      best = hits[i];
      bestScore = s;
    }
  }
  return best;
}
