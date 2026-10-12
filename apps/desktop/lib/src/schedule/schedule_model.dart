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
  /// AnimeFlow's `missing`: aired, monitored, no release grabbed yet;
  /// AnimeFlow grabs it by itself once one appears (nothing to request).
  /// Also an aired episode of a tracked series AnimeFlow has no row for.
  missing,
  failed,
  /// AnimeFlow does not monitor it: the only status worth a Request.
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
  /// Why it failed, or (missing) why the releases found were rejected.
  final String? reason;
  /// AnimeFlow's last search for it (missing).
  final DateTime? lastSearchedAt;
  /// AnimeFlow tracks the series.
  final bool tracked;
  /// AnimeFlow's series id (requests).
  final int? seriesId;
  /// The AnimeFlow season of the matched episode (requests); untracked
  /// on Jellyfin: the TVDB season of the AniList entry.
  final int? season;
  /// The TVDB episode number in [season]: tracked, AnimeFlow's own;
  /// untracked on Jellyfin, AniList episode + the `anilist_map` run's
  /// offset.
  final int? jellyfinEpisode;
  /// Play target once available.
  final String? jellyfinSeriesId;
  /// This user's progress on the Jellyfin episode ([confirmOnJellyfin]);
  /// null when it is not on Jellyfin or was not looked up.
  final EpisodeWatch? watch;
  /// The series is on Jellyfin (tracked or not).
  bool get onJellyfin => jellyfinSeriesId != null;

  const ScheduleEntry({
    required this.airing,
    required this.status,
    this.progress,
    this.reason,
    this.lastSearchedAt,
    this.tracked = false,
    this.seriesId,
    this.season,
    this.jellyfinEpisode,
    this.jellyfinSeriesId,
    this.watch,
  });

  ScheduleEntry copyWith({ScheduleStatus? status, EpisodeWatch? watch}) => ScheduleEntry(
        airing: airing,
        status: status ?? this.status,
        progress: progress,
        reason: reason,
        lastSearchedAt: lastSearchedAt,
        tracked: tracked,
        seriesId: seriesId,
        season: season,
        jellyfinEpisode: jellyfinEpisode,
        jellyfinSeriesId: jellyfinSeriesId,
        watch: watch ?? this.watch,
      );

  @override
  String toString() => 'ScheduleEntry(${airing.anilistId}#${airing.episode} $status)';
}

/// Without AnimeFlow: future airings are upcoming, past ones unknown.
ScheduleEntry untrackedEntry(Airing a, DateTime now) => ScheduleEntry(
      airing: a,
      status: a.airingAt.isAfter(now) ? ScheduleStatus.upcoming : ScheduleStatus.notTracked,
    );

/// This user's state of a Jellyfin episode (its `UserData`).
class EpisodeWatch {
  final bool played;
  /// 0..1: the resume point of a partly watched episode (0 = none).
  final double progress;
  const EpisodeWatch({this.played = false, this.progress = 0});

  @override
  bool operator ==(Object other) => other is EpisodeWatch && other.played == played && other.progress == progress;
  @override
  int get hashCode => Object.hash(played, progress);
  @override
  String toString() => 'EpisodeWatch(${played ? 'played' : '$progress'})';
}

/// One episode Jellyfin has of a series, as the schedule needs it.
class JellyfinEpisodeRef {
  final int season;
  final int episode;
  /// Jellyfin's date-only premiere date.
  final DateTime? premiere;
  final EpisodeWatch watch;
  const JellyfinEpisodeRef(this.season, this.episode, {this.premiere, this.watch = const EpisodeWatch()});
}

// Air dates (AnimeFlow's `air_date`, Jellyfin's premiere date) are
// date-only: the Japanese broadcast day, sent as midnight Japan time (or
// midnight UTC by older servers). Both land on the right day read as a
// Japan (UTC+9, no DST) calendar day, never as a local one: midnight JST
// is the evening before in Europe and America.
const _jst = Duration(hours: 9);

/// The Japan calendar day of [t].
DateTime _jstDay(DateTime t) {
  final j = t.toUtc().add(_jst);
  return DateTime.utc(j.year, j.month, j.day);
}

String _dayKey(DateTime d) => '${d.year}-${d.month}-${d.day}';

/// The Japan days whose air date fits a broadcast at [airingAt]: its own
/// and, for a late-night slot (before 05:00 JST, "25:30"), the evening
/// before, which listings often give.
List<DateTime> _airDays(DateTime airingAt) {
  final j = airingAt.toUtc().add(_jst);
  final d = DateTime.utc(j.year, j.month, j.day);
  return [d, if (j.hour < 5) DateTime.utc(j.year, j.month, j.day - 1)];
}

/// The date-only [airDate] is the broadcast day of [airingAt] (see
/// [_airDays]).
bool sameAirDay(DateTime airDate, DateTime airingAt) => _airDays(airingAt).contains(_jstDay(airDate));

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
    if (e.airDate != null) byDay.putIfAbsent('$id@${_dayKey(_jstDay(e.airDate!))}', () => it);
  }
  return [
    for (final a in airings)
      () {
        final id = a.anilistId;
        final ref = refs[id];
        final it = numbered.contains(id)
            ? byAni['$id#${a.episode}']
            : byEp['$id#${a.episode}'] ??
                byAbs['$id#${a.episode}'] ??
                _airDays(a.airingAt).map((d) => byDay['$id@${_dayKey(d)}']).nonNulls.firstOrNull;
        if (it != null) {
          final e = it.episode;
          return ScheduleEntry(
            airing: a,
            status: ScheduleStatus.of(e.status),
            progress: e.status == EpisodeStatus.downloading ? e.progress : null,
            reason: e.status == EpisodeStatus.failed || e.status == EpisodeStatus.missing ? e.reason : null,
            lastSearchedAt: e.lastSearchedAt,
            tracked: true,
            seriesId: it.seriesId,
            season: e.season,
            jellyfinEpisode: e.episode,
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

/// The episodes [confirmOnJellyfin] looks up: on Jellyfin, untracked
/// ([ScheduleStatus.inLibrary]) or available through AnimeFlow.
bool needsJellyfinLookup(ScheduleEntry e) =>
    e.jellyfinSeriesId != null && (e.status == ScheduleStatus.inLibrary || e.status == ScheduleStatus.available);

/// Checks [matchSchedule]'s entries against the episodes Jellyfin has:
/// [episodes] maps a Jellyfin series id to its episodes. An
/// [ScheduleStatus.inLibrary] one found stays inLibrary, absent becomes
/// [ScheduleStatus.notOnJellyfin], a series missing from [episodes] (not
/// looked up) [ScheduleStatus.aired]. Found episodes (inLibrary or
/// available) get this user's [ScheduleEntry.watch]: (season, episode),
/// else the one premiered that day.
List<ScheduleEntry> confirmOnJellyfin(List<ScheduleEntry> entries, Map<String, List<JellyfinEpisodeRef>> episodes) => [
      for (final e in entries)
        if (!needsJellyfinLookup(e))
          e
        else
          switch ((episodes[e.jellyfinSeriesId], e.status)) {
            (null, ScheduleStatus.inLibrary) => e.copyWith(status: ScheduleStatus.aired),
            (null, _) => e,
            (final have?, _) => switch (_episodeOf(have, e)) {
                final x? => e.copyWith(watch: x.watch),
                null when e.status == ScheduleStatus.inLibrary => e.copyWith(status: ScheduleStatus.notOnJellyfin),
                null => e,
              },
          },
    ];

JellyfinEpisodeRef? _episodeOf(List<JellyfinEpisodeRef> have, ScheduleEntry e) {
  final byNumber = have.where((x) => x.season == e.season && x.episode == e.jellyfinEpisode).firstOrNull;
  if (byNumber != null || !e.tracked) return byNumber;
  // AnimeFlow's numbering missed (specials, renumbered seasons): the
  // episode premiered that day, when only one did.
  return have.where((x) => x.premiere != null && sameAirDay(x.premiere!, e.airing.airingAt)).singleOrNull;
}

/// The episodes Jellyfin has of a series, as the linked account sees
/// them; null when it cannot tell (no linked account for that server).
typedef JellyfinEpisodeLookup = Future<List<JellyfinEpisodeRef>?> Function(String jellyfinSeriesId);

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
  /// Confirms "on Jellyfin" and this user's watched state per episode
  /// ([confirmOnJellyfin]); null = never confirmed (aired entries read
  /// [ScheduleStatus.aired], nothing shows as watched).
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

  /// Looks up the episodes of every series an entry on Jellyfin is on
  /// ([needsJellyfinLookup]), in parallel, one request per series; a
  /// failed or impossible lookup leaves that series out.
  Future<List<ScheduleEntry>> _confirm(List<ScheduleEntry> entries) async {
    final lookup = jellyfinEpisodes;
    final ids = {
      for (final e in entries)
        if (needsJellyfinLookup(e)) e.jellyfinSeriesId!,
    };
    final found = <String, List<JellyfinEpisodeRef>>{};
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
