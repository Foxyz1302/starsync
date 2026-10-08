// Release file names -> series / season / episode, anitomy-style but small:
// enough to group a downloads folder into shows. Unknown shapes fall back to
// the cleaned name with no episode, never to a wrong number.

/// What a release file name says.
class ParsedName {
  /// Title without group, season marker, episode, year or release tags.
  final String series;
  final int? season;
  final int? episode;
  /// Release group: leading `[Group]` or scene-style trailing `-GRP`.
  final String? group;
  /// Release year, taken out of [series] (movies, `Title (2019)`).
  final int? year;
  /// Non-episode marker (`NCOP1`, `NCED`, `OVA 2`, `Special`): such files
  /// carry no [episode] so they never sort among the real ones.
  final String? extra;

  const ParsedName(
    this.series, {
    this.season,
    this.episode,
    this.group,
    this.year,
    this.extra,
  });

  /// `S01E03`, `E25`, the [extra] marker, `S02` for a season pack, else ''.
  String get label {
    final s = season == null ? '' : 'S${season.toString().padLeft(2, '0')}';
    if (episode != null) return '${s}E${episode.toString().padLeft(2, '0')}';
    return extra ?? s;
  }

  /// Grouping key: case, punctuation and spacing do not split a series.
  String get seriesKey => normalizeSeries(series);

  @override
  String toString() => 'ParsedName($series, s=$season, e=$episode, '
      'group=$group, year=$year, extra=$extra)';
}

/// Lowercase letters and digits of [s], single spaces between words.
String normalizeSeries(String s) => s
    .toLowerCase()
    .replaceAll(RegExp(r"['’`]"), '')
    .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
    .trim();

// Release tags: the title ends where the first of these starts.
final _junk = RegExp(
  r'\b(?:2160p|1440p|1080[pi]|720p|576p|480p|4K|UHD|[xh]\.?26[45]|HEVC|AVC|'
  r'AV1|VP9|WEB(?:-?DL|-?Rip)?|BD(?:Rip|Remux)?|Blu-?Ray|BRRip|DVD(?:Rip)?|'
  r'HDTV|HDR(?:10)?|DV|REMUX|AAC(?:\d\.\d)?|FLAC|Opus|DTS(?:-HD)?|E?-?AC-?3|'
  r'DDP?\d?|TrueHD|Atmos|10-?bit|8-?bit|Hi10P?|PROPER|REPACK|Dual[ -]Audio|'
  r'Multi(?:ple)?[ -]Subs?(?:titles?)?|AMZN|NF|CR|DSNP|HMAX|ATVP|'
  r'Batch|Complete)\b',
  caseSensitive: false,
);
final _ext = RegExp(r'\.(?=[a-z0-9]*[a-z])[a-z0-9]{2,4}$', caseSensitive: false);
final _leadingGroup = RegExp(r'^\s*\[([^\]]+)\]');
final _sceneGroup = RegExp(r'-([A-Za-z0-9]+)$');
final _bracketYear = RegExp(r'[(\[]((?:19|20)\d{2})[)\]]');
final _brackets = RegExp(r'\[[^\]]*\]|\([^)]*\)|\{[^}]*\}|【[^】]*】');
// S01E02, S01.E02, S1 E2; a batch `S01E01-E02` / `S01E01E02` keeps the first.
final _sxe = RegExp(r'\bS(\d{1,2})[ .]?E(\d{1,4})(?:v\d)?(?!\d)',
    caseSensitive: false);
final _nxn = RegExp(r'\b(\d{1,2})x(\d{2,3})\b');
// Anime: `Title - 25`, `- 03v2`, `- 01-02` (batch keeps the first).
final _dashNumber = RegExp(r'\s[-–]\s(\d{1,4})(?:v\d)?(?=$|[\s\-~.])');
final _episodeWord = RegExp(
  r'\b(?:Episode|Ep\.?|E)\s?(\d{1,4})(?:v\d)?\b',
  caseSensitive: false,
);
// Extras: unambiguous words anywhere, short ones only right after the dash.
final _extraAnywhere = RegExp(
  r'(?:^|\s)(NCOP|NCED|OVA|OAD|ONA)\s?(\d{1,2})?(?:v\d)?(?=$|\s)',
  caseSensitive: false,
);
final _extraAfterDash = RegExp(
  r'\s[-–]\s(OP|ED|SP|Specials?|Extras?|Recap|Preview|PV|Menu)\s?(\d{1,2})?'
  r'(?:v\d)?(?=$|\s)',
  caseSensitive: false,
);
final _seasonInTitle = RegExp(
  r'\s(?:S(\d{1,2})|Season\s?(\d{1,2})|(\d{1,2})(?:st|nd|rd|th)\s+Season)\s*$',
  caseSensitive: false,
);
final _trailingYear = RegExp(r'\s((?:19|20)\d{2})$');

/// Parses a file name (with or without the extension, no directories).
ParsedName parseReleaseName(String fileName) {
  var s = fileName.replaceFirst(_ext, '').trim();
  final original = s;
  String? group = _leadingGroup.firstMatch(s)?.group(1)?.trim();
  int? year;
  final by = _bracketYear.firstMatch(s);
  if (by != null) year = int.parse(by.group(1)!);
  s = s.replaceAll(_brackets, ' ');

  // Dots and underscores as separators (scene style), unless the name
  // already has spaces and only the odd `Dr. Stone` dot.
  final dotted = !s.contains(' ') || RegExp(r'\w\.\w').allMatches(s).length > 2;
  if (dotted) {
    // `...H264-GRP`, but not `...WEB-DL`.
    final tags = _junk.allMatches(s);
    if (group == null && tags.isNotEmpty && tags.last.end < s.length) {
      final g = _sceneGroup.firstMatch(s);
      if (g != null) {
        group = g.group(1);
        s = s.substring(0, g.start);
      }
    }
    s = s.replaceAll('.', ' ');
  }
  s = s.replaceAll('_', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

  // Release tags end the interesting part.
  final junk = _junk.firstMatch(s);
  if (junk != null && junk.start > 0) s = s.substring(0, junk.start).trim();

  int? season, episode;
  String? extra;
  var cut = s.length;
  final extraMatch =
      _extraAfterDash.firstMatch(s) ?? _extraAnywhere.firstMatch(s);
  final sxe = _sxe.firstMatch(s);
  if (extraMatch != null) {
    final word = extraMatch.group(1)!;
    final upper = word.length <= 4 ? word.toUpperCase() : _title(word);
    // `OVA - 02`: the number may follow the dash instead.
    final n = extraMatch.group(2) ??
        _dashNumber.firstMatch(s.substring(extraMatch.end))?.group(1);
    extra = n == null
        ? upper
        : (upper.startsWith('NC') || upper.length <= 2)
            ? '$upper${int.parse(n)}'
            : '$upper ${int.parse(n)}';
    cut = extraMatch.start;
    if (sxe != null && sxe.start < cut) {
      season = int.parse(sxe.group(1)!);
      cut = sxe.start;
    }
  } else if (sxe != null) {
    season = int.parse(sxe.group(1)!);
    episode = int.parse(sxe.group(2)!);
    cut = sxe.start;
  } else {
    final nxn = _nxn.firstMatch(s);
    if (nxn != null) {
      season = int.parse(nxn.group(1)!);
      episode = int.parse(nxn.group(2)!);
      cut = nxn.start;
    } else {
      final m = _dashNumber.firstMatch(s) ?? _episodeWord.firstMatch(s);
      if (m != null) {
        episode = int.parse(m.group(1)!);
        cut = m.start;
      }
    }
  }

  var series = s.substring(0, cut);
  // Season pack or season marker kept in the title: `Title S2`,
  // `Title Season 2`, `Title 2nd Season`, `Title.S01.1080p`.
  final sIn = _seasonInTitle.firstMatch(series);
  if (sIn != null) {
    season ??= int.parse(sIn.group(1) ?? sIn.group(2) ?? sIn.group(3)!);
    series = series.substring(0, sIn.start);
  }
  series = series.replaceAll(RegExp(r'[\s\-–:,~]+$'), '').trim();
  // A trailing year is the release year, unless it is the whole title or
  // too far ahead to be one (`Blade Runner 2049`).
  final ty = _trailingYear.firstMatch(series);
  if (ty != null) {
    final y = int.parse(ty.group(1)!);
    if (y <= DateTime.now().year + 1) {
      year ??= y;
      series = series.substring(0, ty.start).trim();
    }
  }
  series = series.replaceAll(RegExp(r'[\s\-–:,~]+$'), '').trim();
  if (series.isEmpty) {
    series = original.replaceAll(RegExp(r'[._]+'), ' ').trim();
  }
  return ParsedName(
    series,
    season: season,
    episode: episode,
    group: group,
    year: year,
    extra: extra,
  );
}

String _title(String w) => w[0].toUpperCase() + w.substring(1).toLowerCase();
