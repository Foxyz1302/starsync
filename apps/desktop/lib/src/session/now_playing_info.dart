import '../files/name_parser.dart';
import '../jellyfin/session_media.dart';
import 'now_playing.dart';

// Title and episode line of `state.media` (pure; see [NowPlaying]).

// "S1E6" (pickFor) or "S01E02".
final _episodeLabel = RegExp(r'^S(\d{1,3})\s?E(\d{1,4})$', caseSensitive: false);
final _year = RegExp(r'^(?:19|20)\d{2}$');
final _ext = RegExp(r'\.(?=[a-z0-9]*[a-z])[a-z0-9]{2,4}$', caseSensitive: false);

/// What the player shows for [media] (`state.media`); null with nothing up.
NowPlaying? nowPlayingOf(Map<String, Object?>? media) {
  if (media == null) return null;
  final name = media['name'] is String ? media['name'] as String : '';
  final art = media['art'] is Map ? media['art'] as Map : const {};
  final poster = art['poster'] is String ? art['poster'] as String : '';
  final banner = art['banner'] is String ? art['banner'] as String : '';
  // A web video's thumbnail: its name as is, no episode guessing.
  if (poster.isNotEmpty && poster == banner) {
    return NowPlaying(title: name, posterHash: poster, bannerHash: banner);
  }
  final ref = refOfStateMedia(media);
  final (title, episode) = ref != null
      ? jellyfinTitle(ref.title.isNotEmpty ? ref.title : name, ref.subtitle)
      : fileTitle(name);
  return NowPlaying(title: title, episode: episode, posterHash: poster, bannerHash: banner);
}

/// Jellyfin: [name] is the item's, [subtitle] "Series · S1E6" (or
/// "Series - S01E02") for episodes, the year for movies. Episodes give the
/// series and "S1 E6 · Name"; anything else the name alone.
(String, String?) jellyfinTitle(String name, String? subtitle) {
  final sub = subtitle?.trim() ?? '';
  if (sub.isEmpty || _year.hasMatch(sub)) return (name, null);
  // The label is after the last separator (or the whole subtitle).
  final cut = RegExp(r' [·-] ').allMatches(sub).lastOrNull;
  final m = _episodeLabel.firstMatch(cut == null ? sub : sub.substring(cut.end).trim());
  final series = m == null ? sub : (cut == null ? '' : sub.substring(0, cut.start).trim());
  final label = m == null ? null : 'S${int.parse(m.group(1)!)} E${int.parse(m.group(2)!)}';
  if (series.isEmpty) return (name, label);
  final episode = [?label, if (name.isNotEmpty) name].join(' · ');
  return (series, episode.isEmpty ? null : episode);
}

/// Files and links: the release name's series and "S1 E3", "E25" or its
/// extra marker (NCOP1, OVA 2); the name minus extension when it says
/// nothing better.
(String, String?) fileTitle(String name) {
  final p = parseReleaseName(name);
  final series = p.series.trim();
  if (series.isEmpty) return (name.replaceFirst(_ext, ''), null);
  final String? episode;
  if (p.episode != null) {
    episode = p.season != null ? 'S${p.season} E${p.episode}' : 'E${p.episode}';
  } else {
    episode = p.extra;
  }
  return (series, episode);
}
