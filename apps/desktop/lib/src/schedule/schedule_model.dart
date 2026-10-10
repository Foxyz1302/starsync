import 'dart:async';

import 'anilist.dart';
import 'animeflow.dart';

// The Schedule tab's data: AniList says what airs when, AnimeFlow says
// what the media server has of it. [matchSchedule] merges the two and
// [ScheduleRepository] loads a window of both, degrading to AniList alone
// when AnimeFlow is unreachable or not linked.

enum ScheduleStatus {
  available,
  downloading,
  upcoming,
  missing,
  failed,
  unmonitored,
  /// AnimeFlow does not track this series (or is unreachable).
  notTracked,
  /// Not tracked by AnimeFlow, the series is on Jellyfin (`/library`) and
  /// so is the episode ([confirmOnJellyfin]; [matchSchedule] alone sets
  /// it from the series).
  inLibrary,
  /// Not tracked, the series is on Jellyfin, the episode aired but is not
  /// there yet.
  notOnJellyfin,
  /// Not tracked, the series is on Jellyfin, the episode aired; whether
  /// it is there is unknown (no linked account, lookup failed).
  aired;

  static ScheduleStatus of(EpisodeStatus s) => switch (s) {
        EpisodeStatus.available => available,
        EpisodeStatus.downloading => downloading,
        EpisodeStatus.upcoming => upcoming,
        EpisodeStatus.missing => missing,
        EpisodeStatus.failed => failed,
        EpisodeStatus.unmonitored => unmonitored,
      };
}

/// One airing with what AnimeFlow knows about it.
class ScheduleEntry {
  final Airing airing;
  final ScheduleStatus status;
  /// 0..1 while downloading.
  final double? progress;
  /// Why it failed.
  final String? reason;
  /// AnimeFlow tracks the series.
  final bool tracked;
  /// AnimeFlow's series id (requests).
  final int? seriesId;
  /// The AnimeFlow season of the matched episode (requests); untracked
  /// on Jellyfin: the TVDB season of the AniList entry.
  final int? season;
  /// Untracked on Jellyfin: the TVDB episode number in [season] (AniList
  /// episode + the `anilist_map` run's offset).
  final int? jellyfinEpisode;
  /// Play target once available.
  final String? jellyfinSeriesId;
  /// The series is on Jellyfin (tracked or not).
  bool get onJellyfin => jellyfinSeriesId != null;

  const ScheduleEntry({
    required this.airing,
    required this.status,
    this.progress,
    this.reason,
    this.tracked = false,
    this.seriesId,
    this.season,
    this.jellyfinEpisode,
    this.jellyfinSeriesId,
  });

  ScheduleEntry withStatus(ScheduleStatus s) => ScheduleEntry(
        airing: airing,
        status: s,
        progress: progress,
        reason: reason,
        tracked: tracked,
        seriesId: seriesId,
        season: season,
        jellyfinEpisode: jellyfinEpisode,
        jellyfinSeriesId: jellyfinSeriesId,
      );

  @override
  String toString() => 'ScheduleEntry(${airing.anilistId}#${airing.episode} $status)';
}

/// Without AnimeFlow: future airings are upcoming, past ones unknown.
ScheduleEntry untrackedEntry(Airing a, DateTime now) => ScheduleEntry(
      airing: a,
      status: a.airingAt.isAfter(now) ? ScheduleStatus.upcoming : ScheduleStatus.notTracked,
    );

String _day(DateTime d) {
  final l = d.toLocal();
  return '${l.year}-${l.month}-${l.day}';
}

class _SeriesRef {
  final int seriesId;
  final String? jellyfinSeriesId;
  _SeriesRef(this.seriesId, this.jellyfinSeriesId);
}

/// Merges AniList [airings] with AnimeFlow's [schedule] rows and tracked
/// [series]. Per airing: the episode with the same AniList id (that
/// episode's season's entry) and episode number, else absolute number,
/// else the same local air day; unmatched airings of a tracked AniList id
/// are missing once aired, upcoming before; the rest are not tracked.
List<ScheduleEntry> matchSchedule(
  List<Airing> airings, {
  required List<AnimeFlowScheduleItem> schedule,
  List<AnimeFlowSeries> series = const [],
  List<AnimeFlowLibraryItem> library = const [],
  DateTime? now,
}) {
  final at = now ?? DateTime.now();
  // AniList id -> (Jellyfin series, its TVDB season, TVDB - AniList
  // episode offset) from /library.
  final lib = <int, (String, int, int)>{};
  for (final item in library) {
    if (item.jellyfinSeriesId.isEmpty) continue;
    for (final r in item.anilistMap) {
      lib[r.anilistId] ??= (item.jellyfinSeriesId, r.season, r.offset);
    }
    for (final e in item.anilistIds.entries) {
      lib[e.value] ??= (item.jellyfinSeriesId, e.key, 0);
    }
  }
  final refs = <int, _SeriesRef>{};
  for (final s in series) {
    final id = s.anilistId;
    if (id != null) refs[id] ??= _SeriesRef(s.seriesId, s.jellyfinSeriesId);
  }
  // AnimeFlow's AniList episode number wins outright: TVDB numbering runs
  // on across split entries (JoJo S6E4 is "2nd & 3rd STAGE" ep 3), so a TVDB
  // or absolute number, or an air day, is only a guess for AniList entries
  // AnimeFlow gives no AniList numbers for.
  final byAni = <String, AnimeFlowScheduleItem>{};
  final byEp = <String, AnimeFlowScheduleItem>{};
  final byAbs = <String, AnimeFlowScheduleItem>{};
  final byDay = <String, AnimeFlowScheduleItem>{};
  final numbered = <int>{};
  for (final it in schedule) {
    final e = it.episode, id = e.anilistId;
    if (id == null) continue;
    refs[id] ??= _SeriesRef(it.seriesId, it.jellyfinSeriesId);
    if (e.anilistEpisode != null) {
      numbered.add(id);
      byAni.putIfAbsent('$id#${e.anilistEpisode}', () => it);
    }
    byEp.putIfAbsent('$id#${e.episode}', () => it);
    if (e.absolute != null) byAbs.putIfAbsent('$id#${e.absolute}', () => it);
    if (e.airDate != null) byDay.putIfAbsent('$id@${_day(e.airDate!)}', () => it);
  }
  return [
    for (final a in airings)
      () {
        final id = a.anilistId;
        final ref = refs[id];
        final it = numbered.contains(id)
            ? byAni['$id#${a.episode}']
            : byEp['$id#${a.episode}'] ?? byAbs['$id#${a.episode}'] ?? byDay['$id@${_day(a.airingAt)}'];
        if (it != null) {
          final e = it.episode;
          return ScheduleEntry(
            airing: a,
            status: ScheduleStatus.of(e.status),
            progress: e.status == EpisodeStatus.downloading ? e.progress : null,
            reason: e.status == EpisodeStatus.failed ? e.reason : null,
            tracked: true,
            seriesId: it.seriesId,
            season: e.season,
            jellyfinSeriesId: it.jellyfinSeriesId ?? ref?.jellyfinSeriesId ?? lib[id]?.$1,
          );
        }
        if (ref == null) {
          final onJf = lib[id];
          if (onJf == null) return ScheduleEntry(airing: a, status: ScheduleStatus.notTracked);
          return ScheduleEntry(
            airing: a,
            status: a.airingAt.isAfter(at) ? ScheduleStatus.upcoming : ScheduleStatus.inLibrary,
            season: onJf.$2,
            jellyfinEpisode: a.episode + onJf.$3,
            jellyfinSeriesId: onJf.$1,
          );
        }
        return ScheduleEntry(
          airing: a,
          status: a.airingAt.isAfter(at) ? ScheduleStatus.upcoming : ScheduleStatus.missing,
          tracked: true,
          seriesId: ref.seriesId,
          jellyfinSeriesId: ref.jellyfinSeriesId ?? lib[id]?.$1,
        );
      }(),
  ];
}

/// Checks [matchSchedule]'s [ScheduleStatus.inLibrary] entries (series
/// on Jellyfin) against the episodes Jellyfin has: [episodes] maps a
/// Jellyfin series id to its (season, episode) numbers. Found stays
/// inLibrary, absent becomes [ScheduleStatus.notOnJellyfin], a series
/// missing from [episodes] (not looked up) [ScheduleStatus.aired].
List<ScheduleEntry> confirmOnJellyfin(List<ScheduleEntry> entries, Map<String, Set<(int, int)>> episodes) => [
      for (final e in entries)
        if (e.status != ScheduleStatus.inLibrary)
          e
        else
          switch (episodes[e.jellyfinSeriesId]) {
            null => e.withStatus(ScheduleStatus.aired),
            final have when have.contains((e.season, e.jellyfinEpisode)) => e,
            _ => e.withStatus(ScheduleStatus.notOnJellyfin),
          },
    ];

/// The (season, episode) numbers Jellyfin has of a series; null when it
/// cannot tell (no linked account for that server).
typedef JellyfinEpisodeLookup = Future<Set<(int, int)>?> Function(String jellyfinSeriesId);

/// One loaded window. Errors are display text; [entries] is empty only
/// when AniList failed with nothing cached.
class ScheduleSnapshot {
  final DateTime from;
  final DateTime to;
  /// Sorted by air time.
  final List<ScheduleEntry> entries;
  /// AniList failed and nothing was cached.
  final String? aniListError;
  /// AniList failed; [entries] come from the cache fetched then.
  final DateTime? aniListStaleSince;
  /// AnimeFlow is unreachable, refused or not linked: statuses are
  /// AniList-only (upcoming / not tracked).
  final String? animeFlowError;
  /// The structured AnimeFlow failure behind [animeFlowError].
  final AnimeFlowException? animeFlowException;
  /// Who we are on AnimeFlow (null when it failed).
  final AnimeFlowMe? me;

  const ScheduleSnapshot({
    required this.from,
    required this.to,
    required this.entries,
    this.aniListError,
    this.aniListStaleSince,
    this.animeFlowError,
    this.animeFlowException,
    this.me,
  });

  bool get hasAnimeFlow => me != null;
}

/// Loads AniList and AnimeFlow for a window and merges them.
class ScheduleRepository {
  ScheduleRepository({required this.aniList, this.animeFlow, this.jellyfinEpisodes, DateTime Function()? now})
      : _now = now ?? DateTime.now;

  final AniListClient aniList;
  /// Null = not configured (AniList only).
  final AnimeFlowClient? animeFlow;
  /// Confirms "on Jellyfin" per episode ([confirmOnJellyfin]); null =
  /// never confirmed (aired entries read [ScheduleStatus.aired]).
  final JellyfinEpisodeLookup? jellyfinEpisodes;
  final DateTime Function() _now;

  /// Last week's Monday 00:00 local .. 4 weeks later.
  static ({DateTime from, DateTime to}) defaultWindow(DateTime now) {
    final l = now.toLocal();
    final from = DateTime(l.year, l.month, l.day - (l.weekday - 1) - 7);
    return (from: from, to: DateTime(from.year, from.month, from.day + 28));
  }

  Future<ScheduleSnapshot> load({DateTime? from, DateTime? to, bool force = false}) async {
    final w = defaultWindow(_now());
    final start = from ?? w.from, end = to ?? w.to;
    final flowF = _animeFlow(start, end, force);
    final AniListSchedule ani;
    try {
      ani = await aniList.schedule(start, end, force: force);
    } catch (e) {
      unawaited(flowF.then((_) {}, onError: (_) {}));
      return ScheduleSnapshot(from: start, to: end, entries: const [], aniListError: _text(e));
    }
    final now = _now();
    final flow = await flowF;
    final airings = [...ani.airings]..sort((a, b) => a.airingAt.compareTo(b.airingAt));
    final entries = flow.error == null
        ? await _confirm(
            matchSchedule(airings, schedule: flow.schedule, series: flow.series, library: flow.library, now: now))
        : [for (final a in airings) untrackedEntry(a, now)];
    return ScheduleSnapshot(
      from: start,
      to: end,
      entries: entries,
      aniListStaleSince: ani.staleSince,
      animeFlowError: flow.error == null ? null : _text(flow.error!),
      animeFlowException: flow.error is AnimeFlowException ? flow.error as AnimeFlowException : null,
      me: flow.me,
    );
  }

  /// Looks up the episodes of every series an inLibrary entry is on, in
  /// parallel; a failed or impossible lookup leaves that series out.
  Future<List<ScheduleEntry>> _confirm(List<ScheduleEntry> entries) async {
    final lookup = jellyfinEpisodes;
    final ids = {
      for (final e in entries)
        if (e.status == ScheduleStatus.inLibrary && e.jellyfinSeriesId != null) e.jellyfinSeriesId!,
    };
    final found = <String, Set<(int, int)>>{};
    if (lookup != null) {
      await Future.wait([
        for (final id in ids)
          lookup(id).then((eps) {
            if (eps != null) found[id] = eps;
          }, onError: (_) {}),
      ]);
    }
    return confirmOnJellyfin(entries, found);
  }

  Future<({AnimeFlowMe? me, List<AnimeFlowScheduleItem> schedule, List<AnimeFlowSeries> series, List<AnimeFlowLibraryItem> library, Object? error})>
      _animeFlow(DateTime from, DateTime to, bool force) async {
    final c = animeFlow;
    if (c == null) {
      return (me: null, schedule: const <AnimeFlowScheduleItem>[], series: const <AnimeFlowSeries>[],
          library: const <AnimeFlowLibraryItem>[],
          error: 'AnimeFlow is not configured');
    }
    try {
      if (force) c.clearCache();
      final me = await c.me();
      final (sched, series) = await (c.schedule(from, to), c.series()).wait;
      // The library only adds "on Jellyfin" for untracked shows: its
      // failure never fails the schedule.
      List<AnimeFlowLibraryItem> library = const [];
      try {
        library = await c.library();
      } catch (_) {}
      return (me: me, schedule: sched.items, series: series, library: library, error: null);
    } on ParallelWaitError catch (e) {
      final errs = e.errors as (AsyncError?, AsyncError?);
      return (
        me: null,
        schedule: const <AnimeFlowScheduleItem>[],
        series: const <AnimeFlowSeries>[],
        library: const <AnimeFlowLibraryItem>[],
        error: (errs.$1 ?? errs.$2)!.error,
      );
    } catch (e) {
      return (me: null, schedule: const <AnimeFlowScheduleItem>[], series: const <AnimeFlowSeries>[], library: const <AnimeFlowLibraryItem>[], error: e);
    }
  }

  static String _text(Object e) => switch (e) {
        AnimeFlowException(:final code, :final detail) => switch (code) {
            AnimeFlowErrorCode.missingToken => 'Link the Jellyfin server to see AnimeFlow statuses',
            AnimeFlowErrorCode.badToken => 'AnimeFlow: sign in to Jellyfin again',
            AnimeFlowErrorCode.revoked => 'AnimeFlow: access revoked',
            AnimeFlowErrorCode.rateLimited => 'AnimeFlow: too many requests, try again shortly',
            _ => 'AnimeFlow: $detail',
          },
        AniListException(:final message) => message,
        _ => '$e',
      };
}
