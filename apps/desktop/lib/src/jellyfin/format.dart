import 'package:sync_relay_core/core.dart';

import '../screens/home/picked_media.dart';
import 'accounts.dart';

/// "1 h 42 min", "24 min", "45 s".
String formatRuntime(Duration d) {
  final h = d.inHours, m = d.inMinutes % 60;
  if (h > 0) return m == 0 ? '$h h' : '$h h $m min';
  if (d.inMinutes > 0) return '${d.inMinutes} min';
  return '${d.inSeconds} s';
}

/// Watched share of a resumable item, 0 when there is no resume point.
double progressOf(JellyfinItem item) {
  final run = item.runTimeTicks;
  final pos = item.userData.playbackPositionTicks;
  if (run == null || run <= 0 || pos <= 0) return 0;
  return (pos / run).clamp(0.0, 1.0);
}

/// "12 min left" for a resumable item, else null.
String? timeLeft(JellyfinItem item) {
  final run = item.runTimeTicks;
  if (run == null || !item.userData.isResumable) return null;
  final left = ticksToDuration(run - item.userData.playbackPositionTicks);
  if (left.inMinutes < 1) return 'almost done';
  return '${formatRuntime(left)} left';
}

bool isPlayable(JellyfinItem item) => switch (item.kind) {
      JellyfinItemKind.movie || JellyfinItemKind.episode || JellyfinItemKind.video => true,
      _ => !item.isFolder && item.mediaType == 'Video',
    };

/// Cards that select (details panel) on click: playable items and series.
bool isSelectable(JellyfinItem item) => isPlayable(item) || item.kind == JellyfinItemKind.series;

/// Line under a card title: "S2E3 · 12 min left", "2019 · 24 eps", ...
String cardSubtitle(JellyfinItem item, {bool withSeries = false}) {
  final parts = <String>[];
  switch (item.kind) {
    case JellyfinItemKind.episode:
      if (withSeries && item.seriesName != null) parts.add(item.seriesName!);
      parts.add(item.episodeLabel ?? item.seasonName ?? 'Episode');
    case JellyfinItemKind.series:
      if (item.productionYear != null) parts.add('${item.productionYear}');
      final eps = item.recursiveItemCount, seasons = item.childCount;
      if (eps != null && eps > 0) {
        parts.add('$eps eps');
      } else if (seasons != null && seasons > 0) {
        parts.add(seasons == 1 ? '1 season' : '$seasons seasons');
      }
    case JellyfinItemKind.season:
      final n = item.childCount ?? item.recursiveItemCount;
      if (n != null) parts.add('$n eps');
    default:
      if (item.productionYear != null) parts.add('${item.productionYear}');
  }
  final left = timeLeft(item);
  if (left != null) {
    parts.add(left);
  } else if (isPlayable(item) && item.runTime != null) {
    parts.add(formatRuntime(item.runTime!));
  }
  return parts.join(' · ');
}

/// Title on a card: episodes in rows that mix series show the series name
/// on top and the episode below.
String cardTitle(JellyfinItem item, {bool seriesFirst = false}) =>
    seriesFirst && item.kind == JellyfinItemKind.episode && item.seriesName != null
        ? item.seriesName!
        : item.name;

/// The selection for a playable [item] of [account].
JellyfinMedia pickFor(JellyfinAccount account, JellyfinItem item) {
  final String subtitle;
  if (item.kind == JellyfinItemKind.episode) {
    subtitle = [?item.seriesName, ?item.episodeLabel].join(' · ');
  } else {
    subtitle = item.productionYear?.toString() ?? '';
  }
  return JellyfinMedia(
    serverId: account.serverId,
    baseUrl: account.baseUrl,
    itemId: item.id,
    mediaSourceId: item.mediaSources.length > 1 ? item.mediaSources.first.id : null,
    title: item.name,
    subtitle: subtitle,
    runtime: item.runTime,
  );
}
