// Release file and folder names -> show / season / episode / extra / movie,
// anitomy-style but small: enough to group a downloads folder into shows.
// Unknown shapes fall back to the cleaned name with no episode, never to a
// wrong number. Pure and offline (L1 of the library, see ARCHITECTURE.md
// "Library").

/// What a release name is about.
enum ReleaseKind {
  /// A numbered episode.
  episode,

  /// `Title (2019)`, `Title - Movie 2`, `Gekijouban Title`.
  movie,

  /// Not an episode of the run: OP/ED (creditless or not), OVA, specials,
  /// PV, menus.
  extra,

  /// Nothing says which: a clip, a season pack's name, a page title.
  other,
}

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

  /// Non-episode marker (`NCOP1`, `OP2`, `ED`, `OVA 2`, `Special`, `PV1`,
  /// `Menu`): such files carry no [episode] so they never sort among the
  /// real ones.
  final String? extra;

  /// A movie marker was found (`Movie`, `Movie 01`, `Gekijouban`).
  final bool movie;

  /// `Movie 2`: its number in the show's movies.
  final int? movieNumber;

  /// From a parenthetical next to the season (`(Season 3 - Alicization)`):
  /// the season's own name.
  final String? subtitle;

  const ParsedName(
    this.series, {
    this.season,
    this.episode,
    this.group,
    this.year,
    this.extra,
    this.movie = false,
    this.movieNumber,
    this.subtitle,
  });

  ReleaseKind get kind {
    if (episode != null) return ReleaseKind.episode;
    if (extra != null) return ReleaseKind.extra;
    if (movie || year != null) return ReleaseKind.movie;
    return ReleaseKind.other;
  }

  /// `S01E03`, `E25`, the [extra] marker, `Movie 2`, `S02` for a season
  /// pack, else ''.
  String get label {
    final s = season == null ? '' : 'S${season.toString().padLeft(2, '0')}';
    if (episode != null) return '${s}E${episode.toString().padLeft(2, '0')}';
    if (extra != null) return extra!;
    if (movie) return movieNumber == null ? 'Movie' : 'Movie $movieNumber';
    return s;
  }

  /// Grouping key: case, punctuation and spacing do not split a series.
  String get seriesKey => normalizeSeries(series);

  @override
  String toString() => 'ParsedName($series, s=$season, e=$episode, '
      'group=$group, year=$year, extra=$extra, movie=$movie/$movieNumber, '
      'subtitle=$subtitle)';
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
final _parenthetical = RegExp(r'\(([^)]*)\)');
// Inside a parenthetical: `Season 3 - Alicization`, `S2: Subtitle`,
// `2nd Season`.
final _seasonPhrase = RegExp(
  r'^\s*(?:Season\s?(\d{1,2})|S(\d{1,2})|(\d{1,2})(?:st|nd|rd|th)\s+Season)'
  r'(?:\s*[-–:~]\s*(.+?))?\s*$',
  caseSensitive: false,
);
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
// A name that is only the number (`01.mkv`, `001v2`; not a year).
final _bareNumber = RegExp(r'^(?!(?:19|20)\d\d(?:v\d)?$)(\d{1,4})(?:v\d)?$');
// Extras: unambiguous words anywhere, short ones only right after the dash.
final _extraAnywhere = RegExp(
  r'(?:^|\s)(NCOP|NCED|OVA|OAD|ONA)\s?(\d{1,2})?(?:v\d)?(?=$|\s)',
  caseSensitive: false,
);
final _extraAfterDash = RegExp(
  r'\s[-–]\s(?:Creditless\s|Clean\s|NC\s)?'
  r'(OP|ED|SP|Specials?|Extras?|Recap|Preview|PV|CM|Menu|Opening|Ending)'
  r'\s?(\d{1,2})?(?:v\d)?(?=$|\s)',
  caseSensitive: false,
);
final _creditless = RegExp(r'\s[-–]\s(?:Creditless|Clean|NC)\s', caseSensitive: false);
// Movies: `Title - Movie 01`, `Title - The Movie`, `Title Movie 2` at the
// end, `Gekijouban Title` in front.
final _movieAfterDash = RegExp(
  r'\s[-–]\s(?:The\s)?Movie(?:\s(\d{1,2}))?(?=$|\s)',
  caseSensitive: false,
);
final _movieAtEnd =
    RegExp(r'\s(?:The\sMovie|Movie(?=\s\d))(?:\s(\d{1,2}))?$', caseSensitive: false);
final _gekijouban = RegExp(r'^\s*Gekij(?:ou|ō|o)ban\s+', caseSensitive: false);
final _seasonInTitle = RegExp(
  r'\s(?:S(\d{1,2})|Season\s?(\d{1,2})|(\d{1,2})(?:st|nd|rd|th)\s+Season)\s*$',
  caseSensitive: false,
);
// A folder named only for its season: `Season 2`, `S02`, `2nd Season`.
final _seasonOnly = RegExp(
  r'^(?:S(\d{1,2})|Season\s?(\d{1,2})|(\d{1,2})(?:st|nd|rd|th)\s+Season)$',
  caseSensitive: false,
);
final _trailingYear = RegExp(r'\s((?:19|20)\d{2})$');
// A folder's episode range: `Bleach 001-055`, `Show 01~12`.
final _range = RegExp(r'\s(\d{1,4})\s?[-~–]\s?(\d{1,4})$');
final _extrasFolder = RegExp(
  r'^(?:Extras?|Specials?|SPs?|Bonus|NC(?:OP|ED)?s?|Creditless|OP\s?&?\s?ED|'
  r'Openings?|Endings?|Menus?|PVs?|CMs?|Featurettes?)$',
  caseSensitive: false,
);

/// Season and season name from parentheticals of [s] (`(Season 3 -
/// Alicization)`), read before the brackets are thrown away.
({int? season, String? subtitle}) _parentheticalSeason(String s) {
  for (final m in _parenthetical.allMatches(s)) {
    final p = _seasonPhrase.firstMatch(m.group(1)!);
    if (p == null) continue;
    final n = int.parse(p.group(1) ?? p.group(2) ?? p.group(3)!);
    final sub = p.group(4)?.trim();
    return (season: n, subtitle: sub == null || sub.isEmpty ? null : sub);
  }
  return (season: null, subtitle: null);
}

/// Parses a file name (with or without the extension, no directories).
ParsedName parseReleaseName(String fileName) {
  var s = fileName.replaceFirst(_ext, '').trim();
  final original = s;
  String? group = _leadingGroup.firstMatch(s)?.group(1)?.trim();
  int? year;
  final by = _bracketYear.firstMatch(s);
  if (by != null) year = int.parse(by.group(1)!);
  final paren = _parentheticalSeason(s);
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

  var movie = false;
  int? movieNumber;
  final gk = _gekijouban.firstMatch(s);
  if (gk != null) {
    movie = true;
    s = s.substring(gk.end);
  }

  int? season, episode;
  String? extra;
  var cut = s.length;
  final extraMatch =
      _extraAfterDash.firstMatch(s) ?? _extraAnywhere.firstMatch(s);
  final sxe = _sxe.firstMatch(s);
  final movieMatch = _movieAfterDash.firstMatch(s) ?? _movieAtEnd.firstMatch(s);
  if (extraMatch != null) {
    extra = _extraLabel(s, extraMatch);
    cut = extraMatch.start;
    if (sxe != null && sxe.start < cut) {
      season = int.parse(sxe.group(1)!);
      cut = sxe.start;
    }
  } else if (sxe != null) {
    season = int.parse(sxe.group(1)!);
    episode = int.parse(sxe.group(2)!);
    cut = sxe.start;
  } else if (movieMatch != null) {
    movie = true;
    final n = movieMatch.group(1);
    movieNumber = n == null ? null : int.parse(n);
    cut = movieMatch.start;
  } else {
    final nxn = _nxn.firstMatch(s);
    if (nxn != null) {
      season = int.parse(nxn.group(1)!);
      episode = int.parse(nxn.group(2)!);
      cut = nxn.start;
    } else {
      final m = _dashNumber.firstMatch(s) ??
          _episodeWord.firstMatch(s) ??
          (movie ? null : _bareNumber.firstMatch(s));
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
  season ??= paren.season;
  series = _trimTail(series);
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
  series = _trimTail(series);
  // A name that is only an episode or extra (`01.mkv`, `NCOP1.mkv`) has
  // no title: the folder gives one.
  if (series.isEmpty && episode == null && extra == null && !movie) {
    series = original.replaceAll(RegExp(r'[._]+'), ' ').trim();
  }
  return ParsedName(
    series,
    season: season,
    episode: episode,
    group: group,
    year: year,
    extra: extra,
    movie: movie,
    movieNumber: movieNumber,
    subtitle: paren.subtitle,
  );
}

String _trimTail(String s) => s.replaceAll(RegExp(r'[\s\-–:,~]+$'), '').trim();

/// `NCOP1`, `OP2`, `ED`, `OVA 2`, `Special 1`, `PV1`: short words joined,
/// long ones spaced; Opening / Ending read as OP / ED, creditless ones as
/// NCOP / NCED.
String _extraLabel(String s, RegExpMatch m) {
  final word = m.group(1)!;
  var upper = switch (word.toLowerCase()) {
    'opening' => 'OP',
    'ending' => 'ED',
    final w when w.length <= 3 || w.startsWith('nc') => word.toUpperCase(),
    _ => _title(word),
  };
  final creditless = _creditless.matchAsPrefix(s, m.start) != null;
  if (creditless && (upper == 'OP' || upper == 'ED')) upper = 'NC$upper';
  // `OVA - 02`: the number may follow the dash instead.
  final n = m.group(2) ?? _dashNumber.firstMatch(s.substring(m.end))?.group(1);
  if (n == null) return upper;
  return (upper.startsWith('NC') || upper.length <= 2)
      ? '$upper${int.parse(n)}'
      : '$upper ${int.parse(n)}';
}

String _title(String w) => w[0].toUpperCase() + w.substring(1).toLowerCase();

/// What a folder's name says about the videos in it: lower priority than
/// the file's own name (see `groupLocal`).
class FolderHint {
  /// Show title; '' when the folder names none (`Season 2`, `Extras`).
  final String title;
  final int? season;

  /// The season's own name, from a parenthetical (`Alicization`).
  final String? subtitle;

  /// An episode range in the name (`Bleach 056-111`).
  final int? firstEpisode;
  final int? lastEpisode;
  final String? group;
  final int? year;

  /// A folder of extras (`Extras`, `NCOP`, `Specials`).
  final bool extras;

  const FolderHint({
    this.title = '',
    this.season,
    this.subtitle,
    this.firstEpisode,
    this.lastEpisode,
    this.group,
    this.year,
    this.extras = false,
  });

  String get key => normalizeSeries(title);

  @override
  String toString() => 'FolderHint("$title", s=$season, sub=$subtitle, '
      'range=$firstEpisode-$lastEpisode, extras=$extras)';
}

/// Parses one folder name (no separators): `[Judas] Bleach 056-111 [BD
/// 1080p]`, `Sword Art Online (Season 3 - Alicization)`, `Season 2`.
FolderHint parseFolderName(String name) {
  var s = name.trim();
  final group = _leadingGroup.firstMatch(s)?.group(1)?.trim();
  final by = _bracketYear.firstMatch(s);
  final paren = _parentheticalSeason(s);
  s = s.replaceAll(_brackets, ' ');
  final dotted = !s.contains(' ') || RegExp(r'\w\.\w').allMatches(s).length > 2;
  if (dotted) s = s.replaceAll('.', ' ');
  s = s.replaceAll('_', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  final junk = _junk.firstMatch(s);
  if (junk != null && junk.start > 0) s = s.substring(0, junk.start).trim();
  s = _trimTail(s);
  if (_extrasFolder.hasMatch(s)) return FolderHint(group: group, extras: true);
  final only = _seasonOnly.firstMatch(s);
  if (only != null) {
    return FolderHint(
      season: int.parse(only.group(1) ?? only.group(2) ?? only.group(3)!),
      group: group,
    );
  }
  int? first, last;
  final r = _range.firstMatch(s);
  if (r != null) {
    final a = int.parse(r.group(1)!), b = int.parse(r.group(2)!);
    if (a <= b && !(a >= 1900 && b <= 2100)) {
      first = a;
      last = b;
      s = _trimTail(s.substring(0, r.start));
    }
  }
  int? season = paren.season;
  final sIn = _seasonInTitle.firstMatch(s);
  if (sIn != null) {
    season ??= int.parse(sIn.group(1) ?? sIn.group(2) ?? sIn.group(3)!);
    s = _trimTail(s.substring(0, sIn.start));
  }
  int? year = by == null ? null : int.parse(by.group(1)!);
  final ty = _trailingYear.firstMatch(s);
  if (ty != null && ty.start > 0) {
    year ??= int.parse(ty.group(1)!);
    s = _trimTail(s.substring(0, ty.start));
  }
  return FolderHint(
    title: s,
    season: season,
    subtitle: paren.subtitle,
    firstEpisode: first,
    lastEpisode: last,
    group: group,
    year: year,
  );
}
