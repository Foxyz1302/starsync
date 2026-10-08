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
  notTracked;

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
  final bool followed;
  /// AnimeFlow's series id (follow, requests).
  final int? seriesId;
  /// The AnimeFlow season of the matched episode (requests).
  final int? season;
  /// Play target once available.
  final String? jellyfinSeriesId;

  const ScheduleEntry({
    required this.airing,
    required this.status,
    this.progress,
    this.reason,
    this.tracked = false,
    this.followed = false,
    this.seriesId,
    this.season,
    this.jellyfinSeriesId,
  });

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
  bool followed;
  _SeriesRef(this.seriesId, this.jellyfinSeriesId, this.followed);
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
  DateTime? now,
}) {
  final at = now ?? DateTime.now();
  final refs = <int, _SeriesRef>{};
  for (final s in series) {
    final id = s.anilistId;
    if (id != null) refs[id] ??= _SeriesRef(s.seriesId, s.jellyfinSeriesId, s.followed);
  }
  final byEp = <String, AnimeFlowScheduleItem>{};
  final byAbs = <String, AnimeFlowScheduleItem>{};
  final byDay = <String, AnimeFlowScheduleItem>{};
  for (final it in schedule) {
    final e = it.episode, id = e.anilistId;
    if (id == null) continue;
    final ref = refs[id] ??= _SeriesRef(it.seriesId, it.jellyfinSeriesId, it.followed);
    if (it.followed) ref.followed = true;
    byEp.putIfAbsent('$id#${e.episode}', () => it);
    if (e.absolute != null) byAbs.putIfAbsent('$id#${e.absolute}', () => it);
    if (e.airDate != null) byDay.putIfAbsent('$id@${_day(e.airDate!)}', () => it);
  }
  return [
    for (final a in airings)
      () {
        final id = a.anilistId;
        final ref = refs[id];
        final it = byEp['$id#${a.episode}'] ?? byAbs['$id#${a.episode}'] ?? byDay['$id@${_day(a.airingAt)}'];
        if (it != null) {
          final e = it.episode;
          return ScheduleEntry(
            airing: a,
            status: ScheduleStatus.of(e.status),
            progress: e.status == EpisodeStatus.downloading ? e.progress : null,
            reason: e.status == EpisodeStatus.failed ? e.reason : null,
            tracked: true,
            followed: it.followed || (ref?.followed ?? false),
            seriesId: it.seriesId,
            season: e.season,
            jellyfinSeriesId: it.jellyfinSeriesId ?? ref?.jellyfinSeriesId,
          );
        }
        if (ref == null) return ScheduleEntry(airing: a, status: ScheduleStatus.notTracked);
        return ScheduleEntry(
          airing: a,
          status: a.airingAt.isAfter(at) ? ScheduleStatus.upcoming : ScheduleStatus.missing,
          tracked: true,
          followed: ref.followed,
          seriesId: ref.seriesId,
          jellyfinSeriesId: ref.jellyfinSeriesId,
        );
      }(),
  ];
}

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
  ScheduleRepository({required this.aniList, this.animeFlow, DateTime Function()? now})
      : _now = now ?? DateTime.now;

  final AniListClient aniList;
  /// Null = not configured (AniList only).
  final AnimeFlowClient? animeFlow;
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
        ? matchSchedule(airings, schedule: flow.schedule, series: flow.series, now: now)
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

  Future<({AnimeFlowMe? me, List<AnimeFlowScheduleItem> schedule, List<AnimeFlowSeries> series, Object? error})>
      _animeFlow(DateTime from, DateTime to, bool force) async {
    final c = animeFlow;
    if (c == null) {
      return (me: null, schedule: const <AnimeFlowScheduleItem>[], series: const <AnimeFlowSeries>[],
          error: 'AnimeFlow is not configured');
    }
    try {
      if (force) c.clearCache();
      final me = await c.me();
      final (sched, series) = await (c.schedule(from, to), c.series()).wait;
      return (me: me, schedule: sched.items, series: series, error: null);
    } on ParallelWaitError catch (e) {
      final errs = e.errors as (AsyncError?, AsyncError?);
      return (
        me: null,
        schedule: const <AnimeFlowScheduleItem>[],
        series: const <AnimeFlowSeries>[],
        error: (errs.$1 ?? errs.$2)!.error,
      );
    } catch (e) {
      return (me: null, schedule: const <AnimeFlowScheduleItem>[], series: const <AnimeFlowSeries>[], error: e);
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
