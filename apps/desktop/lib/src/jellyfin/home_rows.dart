import 'package:sync_relay_core/core.dart';

import 'format.dart';

// What the Jellyfin home rows show, as pure functions over the API lists
// (tested without widgets).

/// Series not watched for longer than this leave the Continue row, unless
/// nothing newer is left.
const continueMaxAge = Duration(days: 60);

/// Added this long after it first aired: a re-release ([isReRelease]).
const reReleaseAge = Duration(days: 30);

/// One Continue card per series: an episode's series, else the item itself.
String continueKey(JellyfinItem item) => item.seriesId ?? item.id;

DateTime? _later(DateTime? a, DateTime? b) =>
    a == null ? b : b == null || !b.isAfter(a) ? a : b;

/// The Continue row: Continue watching ([resume]) and Next up ([nextUp])
/// merged into one card per series, the series watched most recently first.
/// A series shows its resume item when that was the last thing played in
/// it, else its next-up episode. When a series was last played comes from
/// the resume points and from [recentlyPlayed] (finished episodes, which
/// next-up items do not carry). Series untouched for [maxAge] are left out
/// unless nothing else is left; [dismissed] (key -> when) hides a series
/// until it is played again after that.
List<JellyfinItem> mergeContinue({
  required List<JellyfinItem> resume,
  required List<JellyfinItem> nextUp,
  List<JellyfinItem> recentlyPlayed = const [],
  Map<String, DateTime> dismissed = const {},
  required DateTime now,
  Duration maxAge = continueMaxAge,
}) {
  final finished = <String, DateTime>{};
  for (final p in recentlyPlayed) {
    final at = p.userData.lastPlayedDate;
    if (at != null) finished[continueKey(p)] = _later(finished[continueKey(p)], at)!;
  }
  final resumeBy = <String, JellyfinItem>{};
  final nextBy = <String, JellyfinItem>{};
  final order = <String>[];
  for (final r in resume) {
    final k = continueKey(r);
    final had = resumeBy[k];
    if (had == null) order.add(k);
    final at = r.userData.lastPlayedDate;
    if (had == null || (at != null && at.isAfter(had.userData.lastPlayedDate ?? DateTime(0)))) {
      resumeBy[k] = r;
    }
  }
  for (final n in nextUp) {
    final k = continueKey(n);
    if (nextBy.containsKey(k)) continue;
    nextBy[k] = n;
    if (!resumeBy.containsKey(k)) order.add(k);
  }

  final cards = <({JellyfinItem item, DateTime? at, int index})>[];
  for (final (i, k) in order.indexed) {
    final r = resumeBy[k], n = nextBy[k], done = finished[k];
    final resumedAt = r?.userData.lastPlayedDate;
    final JellyfinItem item;
    if (r != null && (n == null || (resumedAt != null && (done == null || !resumedAt.isBefore(done))))) {
      item = r;
    } else {
      item = n!;
    }
    final at = _later(resumedAt, done);
    final hiddenAt = dismissed[k];
    if (hiddenAt != null && (at == null || !at.isAfter(hiddenAt))) continue;
    cards.add((item: item, at: at, index: i));
  }
  cards.sort((a, b) {
    if (a.at == null || b.at == null) {
      return a.at == b.at ? a.index.compareTo(b.index) : (a.at == null ? 1 : -1);
    }
    final c = b.at!.compareTo(a.at!);
    return c != 0 ? c : a.index.compareTo(b.index);
  });
  final fresh = [for (final c in cards) if (c.at != null && now.difference(c.at!) <= maxAge) c.item];
  return fresh.isNotEmpty ? fresh : [for (final c in cards) c.item];
}

/// Added to the library long ([age]) after it first aired: a re-upload or
/// an old season added late, not news. Unknown dates are never re-releases.
bool isReRelease(JellyfinItem item, {Duration age = reReleaseAge}) {
  final aired = item.premiereDate, added = item.dateCreated;
  return aired != null && added != null && added.difference(aired) > age;
}

/// One card of a "Latest in X" row: [item] is what selecting or putting it
/// up acts on, [display] gives the picture and title, [subtitle] the line
/// under it.
class LatestCard {
  final JellyfinItem item;
  final JellyfinItem display;
  final String subtitle;
  const LatestCard(this.item, this.display, this.subtitle);
}

/// A series to show for [episode]: its id, name and poster.
JellyfinItem seriesOf(JellyfinItem episode) => JellyfinItem(
      id: episode.seriesId!,
      name: episode.seriesName ?? episode.name,
      type: JellyfinItemType.series,
      isFolder: true,
      imageTags: {
        if (episode.seriesPrimaryImageTag != null)
          JellyfinImageType.primary.apiName: episode.seriesPrimaryImageTag!,
      },
      parentBackdropItemId: episode.parentBackdropItemId,
      parentBackdropImageTags: episode.parentBackdropImageTags,
    );

/// "Latest in X" from the library's newest items (ungrouped, newest
/// first): episodes become one card per series (its poster and name,
/// "S1E1" for a single new episode, else "N new"), in order of the newest
/// episode; movies and other items stay as they are. With [hideReReleases]
/// items that [isReRelease] are left out first.
List<LatestCard> latestCards(List<JellyfinItem> items, {bool hideReReleases = true}) {
  final kept = hideReReleases ? items.where((i) => !isReRelease(i)) : items;
  final groups = <String, List<JellyfinItem>>{};
  final out = <Object>[]; // a JellyfinItem, or a series id (group)
  for (final i in kept) {
    final sid = i.seriesId;
    if (i.kind == JellyfinItemKind.episode && sid != null) {
      final g = groups[sid];
      if (g == null) {
        groups[sid] = [i];
        out.add(sid);
      } else {
        g.add(i);
      }
    } else {
      out.add(i);
    }
  }
  return [
    for (final o in out)
      if (o is JellyfinItem)
        LatestCard(
          o,
          o,
          o.kind == JellyfinItemKind.series && (o.childCount ?? 0) > 1
              ? '${o.childCount} new'
              : cardSubtitle(o),
        )
      else
        _seriesCard(groups[o]!),
  ];
}

LatestCard _seriesCard(List<JellyfinItem> eps) {
  final series = seriesOf(eps.first);
  if (eps.length == 1) {
    final e = eps.single;
    return LatestCard(e, series, e.episodeLabel ?? e.name);
  }
  return LatestCard(series, series, '${eps.length} new');
}
