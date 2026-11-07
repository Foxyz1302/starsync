import 'package:sync_relay_core/core.dart';

import '../../jellyfin/accounts.dart';
import '../../jellyfin/format.dart' show pickFor, progressOf;
import '../../screens/home/picked_media.dart';
import '../anilist.dart';
import '../animeflow.dart';
import '../schedule_model.dart';
import '../schedule_store.dart';

// What the Schedule page's buttons do beyond one client call: friendly
// AnimeFlow errors, finding AnimeFlow's own numbering of an airing, the
// AniDB id of an untracked AniList entry, and the Jellyfin episode to put
// up.

/// A failure meant for the user as is.
class ScheduleActionException implements Exception {
  final String message;
  const ScheduleActionException(this.message);
  @override
  String toString() => message;
}

/// [e] as one short sentence for a toast.
String friendlyError(Object e) => switch (e) {
  ScheduleActionException(:final message) => message,
  AnimeFlowException(:final code, :final detail) => switch (code) {
    AnimeFlowErrorCode.alreadyRequested => 'Already requested',
    AnimeFlowErrorCode.alreadyTracked => 'AnimeFlow already tracks this series',
    AnimeFlowErrorCode.alreadyAvailable => 'Already on Jellyfin',
    AnimeFlowErrorCode.missingScope => 'The owner has not allowed you to do that on AnimeFlow',
    AnimeFlowErrorCode.revoked => 'Your AnimeFlow access was revoked',
    AnimeFlowErrorCode.missingToken => 'Link the Jellyfin server to use AnimeFlow',
    AnimeFlowErrorCode.badToken => 'AnimeFlow: sign in to Jellyfin again',
    AnimeFlowErrorCode.ownAccount => 'You cannot change your own account',
    AnimeFlowErrorCode.searchUnavailable => 'AniDB search is unavailable right now',
    AnimeFlowErrorCode.seriesNotFound => 'AnimeFlow does not know this series',
    AnimeFlowErrorCode.episodeNotFound => 'AnimeFlow does not know this episode',
    AnimeFlowErrorCode.requestNotFound => 'That request is gone',
    AnimeFlowErrorCode.notFound => 'AnimeFlow: not found',
    AnimeFlowErrorCode.invalidState => 'That cannot be done in its current state',
    AnimeFlowErrorCode.rateLimited => 'AnimeFlow is busy, try again shortly',
    AnimeFlowErrorCode.network => 'AnimeFlow is unreachable',
    AnimeFlowErrorCode.jellyfinUnreachable => 'AnimeFlow cannot reach Jellyfin right now',
    _ => 'AnimeFlow: $detail',
  },
  JellyfinException(:final message) => 'Jellyfin: $message',
  _ => '$e',
};

/// AnimeFlow's episode for [e] (its season and numbering), from the
/// series detail: same AniList id and episode, else absolute number, else
/// the same air day ([sameAirDay]). Null when the entry is not tracked or nothing fits.
Future<AnimeFlowEpisode?> flowEpisodeFor(AnimeFlowClient client, ScheduleEntry e) async {
  final id = e.seriesId;
  if (id == null) return null;
  final eps = (await client.seriesDetail(id)).episodes;
  final a = e.airing;
  final mine = eps.where((x) => x.anilistId == null || x.anilistId == a.anilistId).toList();
  return mine.where((x) => x.anilistId == a.anilistId && x.episode == a.episode).firstOrNull ??
      mine.where((x) => x.absolute == a.episode).firstOrNull ??
      mine.where((x) => x.airDate != null && sameAirDay(x.airDate!, a.airingAt)).firstOrNull;
}

/// The (season, episode) AnimeFlow uses for [e]; falls back to the
/// matched season and AniList's number when the detail has nothing.
Future<({int season, int episode})> flowNumbering(AnimeFlowClient? client, ScheduleEntry e) async {
  AnimeFlowEpisode? ep;
  if (client != null) {
    try {
      ep = await flowEpisodeFor(client, e);
    } on AnimeFlowException catch (err) {
      if (err.isUnauthorized || err.isForbidden) rethrow;
    }
  }
  if (ep != null) return (season: ep.season, episode: ep.episode);
  return (season: e.season ?? 1, episode: e.jellyfinEpisode ?? e.airing.episode);
}

/// The AniDB id of an untracked AniList entry, from AnimeFlow's search:
/// the hit with the same AniList id, searched by English then romaji
/// title. Otherwise every hit seen, for the user to choose from.
Future<({AnimeFlowSearchHit? match, List<AnimeFlowSearchHit> hits})> findOnAniDb(
  AnimeFlowClient client,
  Airing a,
) async {
  final hits = <AnimeFlowSearchHit>[];
  final queries = {a.title, if (a.titleRomaji.isNotEmpty) a.titleRomaji};
  for (final q in queries) {
    final found = await client.search(q);
    final match = found.where((h) => h.anilistId == a.anilistId).firstOrNull;
    if (match != null) return (match: match, hits: found);
    for (final h in found) {
      if (hits.every((x) => x.anidbId != h.anidbId)) hits.add(h);
    }
  }
  return (match: null, hits: hits);
}

/// The linked Jellyfin account AnimeFlow's series ids belong to: the one
/// AnimeFlow authenticates with, else the default.
JellyfinAccount? jellyfinAccountFor(JellyfinAccounts accounts, AnimeFlowClient? flow) {
  if (flow != null) {
    final token = AnimeFlowClient.tokenFor(accounts.accounts, flow.baseUrl);
    final a = accounts.accounts.where((a) => token != null && a.token == token).firstOrNull;
    if (a != null) return a;
  }
  return accounts.defaultAccount;
}

/// The Schedule's data for [accounts]: AniList, AnimeFlow at [address]
/// (read on every load: the last one a server offered) with the token
/// of the linked account on its domain, that account's Jellyfin episodes,
/// and the last schedule kept per account and AnimeFlow address ([store]:
/// on disk too). The app keeps one for its whole run (`AppGraph.schedule`),
/// so the clients' own caches (AniList's pages, AnimeFlow's ETags and
/// /me) last across visits of the tab.
ScheduleRepository scheduleRepositoryFor(JellyfinAccounts accounts,
    {required String Function() address, ScheduleStore? store}) {
  final flow = AnimeFlowClient.fromAccounts(accounts, address: address);
  return ScheduleRepository(
    aniList: AniListClient(),
    animeFlow: flow,
    jellyfinEpisodes: (id) => jellyfinScheduleEpisodes(accounts, flow, id),
    store: store,
    key: () async {
      await accounts.ensureLoaded(validate: false);
      final token = AnimeFlowClient.tokenFor(accounts.accounts, flow.baseUrl);
      final a = accounts.accounts.where((a) => token != null && a.token == token).firstOrNull;
      return scheduleKeyFor(flow.baseUrl, serverId: a?.serverId, userId: a?.userId);
    },
  );
}

/// The episodes Jellyfin has of [jellyfinSeriesId] (numbers, premiere
/// date, this user's watched state), seen by the account AnimeFlow's ids
/// belong to ([jellyfinAccountFor]): the user's own; null without a
/// linked account. One request per series, memoised a few minutes
/// ([JellyfinAccounts.cached]; a stop report drops it,
/// [JellyfinAccounts.watched]).
Future<List<JellyfinEpisodeRef>?> jellyfinScheduleEpisodes(
  JellyfinAccounts accounts,
  AnimeFlowClient? flow,
  String jellyfinSeriesId,
) async {
  await accounts.ensureLoaded(validate: false);
  final account = jellyfinAccountFor(accounts, flow);
  final client = account == null ? null : accounts.clientFor(account.serverId);
  if (account == null || client == null) return null;
  return accounts.cached(
    account.serverId,
    'schedule-episodes:$jellyfinSeriesId',
    () async => [
      for (final x in await client.episodes(jellyfinSeriesId))
        if (x.parentIndexNumber != null && x.indexNumber != null)
          JellyfinEpisodeRef(
            x.parentIndexNumber!,
            x.indexNumber!,
            premiere: x.premiereDate,
            watch: EpisodeWatch(played: x.userData.played, progress: x.userData.played ? 0 : progressOf(x)),
          ),
    ],
  );
}

/// The Jellyfin episode of an available [e] as a media pick. Throws
/// [ScheduleActionException] (or a client error) when it cannot be found.
Future<JellyfinMedia> resolveJellyfinEpisode(JellyfinAccounts accounts, AnimeFlowClient? flow, ScheduleEntry e) async {
  final seriesId = e.jellyfinSeriesId;
  if (seriesId == null) throw const ScheduleActionException('This series is not on Jellyfin yet');
  await accounts.ensureLoaded(validate: false);
  final account = jellyfinAccountFor(accounts, flow);
  final client = account == null ? null : accounts.clientFor(account.serverId);
  if (account == null || client == null) {
    throw const ScheduleActionException('Link the Jellyfin server first (Settings)');
  }
  final n = await flowNumbering(flow, e);
  final List<JellyfinItem> eps;
  try {
    eps = await client.episodes(seriesId);
  } on JellyfinException catch (err) {
    if (err.isUnauthorized) accounts.markExpired(account.serverId);
    rethrow;
  }
  final a = e.airing;
  final item =
      eps.where((x) => x.parentIndexNumber == n.season && x.indexNumber == n.episode).firstOrNull ??
      eps.where((x) => x.premiereDate != null && sameAirDay(x.premiereDate!, a.airingAt)).singleOrNull ??
      eps.where((x) => x.indexNumber == a.episode).singleOrNull;
  if (item == null) {
    throw ScheduleActionException('Episode ${a.episode} of ${a.title} is not on Jellyfin yet');
  }
  return pickFor(account, item);
}
