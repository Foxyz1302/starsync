import 'package:sync_relay_core/core.dart';

// `media.ref` (PROTOCOL.md "Media identity") for each source: what a media
// is, independent of where its bytes come from. Local files get theirs
// from the library (`ShowMatcher.refFor`, L1 + L2); these are the other
// two: Jellyfin items by their provider ids, links best effort from their
// name.

/// A Jellyfin episode, movie or video: kind, series (or movie) title,
/// season and episode as Jellyfin numbers them, and the AniList / TVDB ids
/// its metadata plugins set ([series]' when given: an episode's own ids
/// are the episode's, not the show's). Null for anything that is not
/// played (series, seasons, folders).
MediaRef? jellyfinMediaRef(JellyfinItem item, {JellyfinItem? series}) {
  final kind = switch (item.kind) {
    JellyfinItemKind.episode => 'episode',
    JellyfinItemKind.movie || JellyfinItemKind.video => 'movie',
    _ => null,
  };
  if (kind == null) return null;
  final episode = kind == 'episode';
  // An episode's Tvdb id names the episode; the show's comes from the
  // series item. AniList ids are only ever set on shows and movies.
  final owner = episode ? series : item;
  final special = episode && item.parentIndexNumber == 0;
  return MediaRef(
    kind: special ? 'extra' : kind,
    title: episode ? (item.seriesName ?? series?.name ?? item.name) : item.name,
    anilistId: owner?.providerId('AniList'),
    tvdbId: owner?.providerId('Tvdb'),
    season: episode && !special ? item.parentIndexNumber : null,
    ep: episode && !special ? item.indexNumber : null,
  );
}

final _sxe = RegExp(r'S(\d{1,3})\s?E(\d{1,4})$', caseSensitive: false);

/// A picked Jellyfin item from its card's lines alone ([title], and
/// [subtitle] "Series · S1E6" for episodes, the year for movies): kind,
/// title and numbers, no ids.
MediaRef jellyfinPickRef(String title, String subtitle) {
  final sub = subtitle.trim();
  final cut = sub.lastIndexOf(' · ');
  final label = cut < 0 ? sub : sub.substring(cut + 3).trim();
  final m = _sxe.firstMatch(label);
  if (m == null) return MediaRef(kind: 'movie', title: title);
  final season = int.parse(m.group(1)!);
  return MediaRef(
    kind: season == 0 ? 'extra' : 'episode',
    title: cut < 0 ? title : sub.substring(0, cut).trim(),
    season: season == 0 ? null : season,
    ep: season == 0 ? null : int.parse(m.group(2)!),
  );
}

/// A link, best effort: its name read like a release name (`Show - 05`
/// is an episode, `OP1` an extra); anything else a movie of that title.
MediaRef linkMediaRef(String name) {
  final p = parseReleaseName(name);
  final title = p.series.trim().isEmpty ? name.trim() : p.series.trim();
  return switch (p.kind) {
    ReleaseKind.episode => MediaRef(
        kind: 'episode',
        title: title,
        season: p.season,
        ep: p.season == null ? null : p.episode,
        absolute: p.season == null ? p.episode : null),
    ReleaseKind.extra => MediaRef(kind: 'extra', title: title, season: p.season),
    ReleaseKind.movie || ReleaseKind.other => MediaRef(kind: 'movie', title: title),
  };
}

/// The episode line a ref gives (`S3 E13`, `E108`), or null (movies;
/// extras keep the name's own marker).
String? refEpisodeLine(MediaRef ref) {
  if (ref.kind != 'episode') return null;
  if (ref.season != null && ref.ep != null) return 'S${ref.season} E${ref.ep}';
  final n = ref.absolute ?? ref.ep ?? ref.anilistEp;
  return n == null ? null : 'E$n';
}
