import 'release_name.dart';

// L1 of the library (ARCHITECTURE.md "Library"): the videos found in the
// user's folders grouped into shows, offline and deterministic. A file's
// own name wins; the folders above it (up to the watched folder) are
// lower-priority hints for the title, the season, the season's name and
// an episode range. One show spread over several folders (`Bleach
// 001-055`, `Bleach 056-111`) is one show. Numbering is kept as found
// (absolute or per season) and holes in it are known, so "next" can say
// what is missing. Matching to AniList (L2) is the app's.

const videoExtensions = {
  'mkv', 'mp4', 'webm', 'avi', 'mov', 'm4v', 'ts', 'm2ts', 'wmv', 'flv', //
};
const subtitleExtensions = {'ass', 'ssa', 'srt', 'vtt', 'sup'};

enum FileKind { video, subtitle, other }

FileKind kindOf(String path) {
  final ext = _extension(_baseName(path));
  if (videoExtensions.contains(ext)) return FileKind.video;
  if (subtitleExtensions.contains(ext)) return FileKind.subtitle;
  return FileKind.other;
}

/// A file found in a folder.
class LocalFile {
  final String path;
  final int size;
  final DateTime modified;
  const LocalFile(this.path, this.size, this.modified);

  String get name => _baseName(path);

  /// The folder it is in.
  String get folder => _parent(path);
}

/// A run of episode numbers that are not in the folders (`66–107`).
class EpisodeGap {
  final int first;
  final int last;
  const EpisodeGap(this.first, this.last);

  int get length => last - first + 1;

  /// `66–107`, or `5` for one.
  String get label => first == last ? '$first' : '$first–$last';

  @override
  bool operator ==(Object other) => other is EpisodeGap && other.first == first && other.last == last;
  @override
  int get hashCode => Object.hash(first, last);
  @override
  String toString() => 'EpisodeGap($label)';
}

/// What a local file is in its show.
enum LocalKind { episode, movie, extra, other }

/// One video as L1 sees it.
class LocalEpisode {
  final LocalFile file;

  /// The file name's own reading.
  final ParsedName parsed;
  final LocalKind kind;

  /// Its show ([LocalShow.key]); '' for [LocalKind.other].
  final String showKey;

  /// Display title of what it belongs to (file name, else folder).
  final String title;

  /// File's season, else the folder's; null: absolute or none.
  final int? season;

  /// The season's own name (`Alicization`), from a parenthetical.
  final String? seasonName;
  final int? episode;

  /// `OP1`, `NCED2`, `OVA 2` for extras.
  final String? extra;

  /// `Movie 2`'s number.
  final int? movieNumber;

  const LocalEpisode({
    required this.file,
    required this.parsed,
    required this.kind,
    required this.showKey,
    required this.title,
    this.season,
    this.seasonName,
    this.episode,
    this.extra,
    this.movieNumber,
  });

  String get path => file.path;
  String get name => file.name;
  String get folder => file.folder;

  /// Stable across rescans: the show, season and number (or the extra,
  /// the movie, or the path for anything else). Two copies of one
  /// episode share it.
  String get key => switch (kind) {
        LocalKind.episode => '$showKey|s${season ?? ''}|e$episode',
        LocalKind.extra => '$showKey|s${season ?? ''}|x${extra!.toLowerCase()}',
        LocalKind.movie => '$showKey|m${movieNumber ?? ''}',
        LocalKind.other => '|f|${file.path}',
      };

  /// `E056`, `S03E01`, `OP1`, `Movie 1`, else ''.
  String get label => switch (kind) {
        LocalKind.episode => [
            if (season != null) 'S${season.toString().padLeft(2, '0')}',
            'E${episode.toString().padLeft(2, '0')}',
          ].join(),
        LocalKind.extra => extra!,
        LocalKind.movie => movieNumber == null ? 'Movie' : 'Movie $movieNumber',
        LocalKind.other => '',
      };

  @override
  String toString() => 'LocalEpisode($key, ${file.name})';
}

/// One season of a show as found: a numbered season, or the absolute run
/// ([number] null).
class LocalSeason {
  final int? number;
  final String? name;

  /// In episode order; a second copy of an episode follows the first
  /// (newest release name first).
  final List<LocalEpisode> episodes;

  /// Numbers before, between and (by a folder's range) after the
  /// episodes that are not there.
  final List<EpisodeGap> gaps;

  const LocalSeason(this.number, this.name, this.episodes, this.gaps);

  bool get absolute => number == null;

  /// One file per episode number (the first copy), in order.
  List<LocalEpisode> get distinct {
    final seen = <int>{};
    return [
      for (final e in episodes)
        if (seen.add(e.episode!)) e
    ];
  }

  /// "Season 3 · Alicization", "Season 1", "Episodes".
  String get title {
    if (number == null) return name ?? 'Episodes';
    return name == null ? 'Season $number' : 'Season $number · $name';
  }
}

final _episodeKey = RegExp(r'\|s(\d*)\|e(\d+)$');

/// What to play after an episode: the next one there is, and the
/// numbers skipped to reach it (not in the folders).
class LocalNext {
  final LocalEpisode episode;
  final EpisodeGap? skipped;
  const LocalNext(this.episode, {this.skipped});
}

/// A show found in the folders.
class LocalShow {
  /// [normalizeSeries] of its title: stable across rescans and folders.
  final String key;

  /// The most common spelling among its files.
  final String title;
  final List<LocalSeason> seasons;

  /// OP/ED, OVA, specials: by season, then kind, then number.
  final List<LocalEpisode> extras;

  /// Its movies (`Title - Movie 2`).
  final List<LocalEpisode> movies;

  /// The folders its files are in, sorted.
  final List<String> folders;

  /// The most common release group.
  final String? group;

  const LocalShow({
    required this.key,
    required this.title,
    required this.seasons,
    this.extras = const [],
    this.movies = const [],
    this.folders = const [],
    this.group,
  });

  List<LocalEpisode> get episodes => [for (final s in seasons) ...s.episodes];

  /// Every file of the show: episodes, extras, movies.
  Iterable<LocalEpisode> get files sync* {
    yield* episodes;
    yield* extras;
    yield* movies;
  }

  int get episodeCount => seasons.fold(0, (n, s) => n + s.distinct.length);

  LocalSeason? season(int? number) => seasons.where((s) => s.number == number).firstOrNull;

  /// The episode after [lastKey] (a [LocalEpisode.key]; null: nothing
  /// watched yet, so the first one), with the numbers skipped on the way;
  /// null when there is nothing after it. The next season follows the
  /// last episode of one.
  LocalNext? nextAfter(String? lastKey) {
    final all = [
      for (final s in seasons)
        for (final e in s.distinct) (s, e)
    ];
    if (all.isEmpty) return null;
    if (lastKey == null) {
      final (s, e) = all.first;
      final lead = s.gaps.where((g) => g.last < e.episode!).firstOrNull;
      return LocalNext(e, skipped: lead);
    }
    final at = all.indexWhere((p) => p.$2.key == lastKey);
    if (at < 0) {
      // Gone from the folders: the first one after its number.
      final m = _episodeKey.firstMatch(lastKey);
      if (m == null) return null;
      final season = m.group(1)!.isEmpty ? null : int.parse(m.group(1)!);
      final ep = int.parse(m.group(2)!);
      final next = all.indexWhere((p) => p.$1.number == season && p.$2.episode! > ep);
      if (next < 0) return null;
      final (s, e) = all[next];
      return LocalNext(e, skipped: e.episode! > ep + 1 ? EpisodeGap(ep + 1, e.episode! - 1) : null);
    }
    if (at + 1 >= all.length) return null;
    final (s0, e0) = all[at];
    final (s1, e1) = all[at + 1];
    if (!identical(s0, s1)) {
      final lead = s1.gaps.where((g) => g.last < e1.episode!).firstOrNull;
      return LocalNext(e1, skipped: lead);
    }
    final from = e0.episode! + 1, to = e1.episode! - 1;
    return LocalNext(e1, skipped: to >= from ? EpisodeGap(from, to) : null);
  }

  @override
  String toString() => 'LocalShow($key, ${seasons.length} seasons)';
}

/// The folders' videos, grouped.
class LocalLibrary {
  final List<LocalShow> shows;

  /// Movies of no show found here.
  final List<LocalEpisode> movies;

  /// Videos that are not episodes, extras of a show or movies.
  final List<LocalEpisode> other;

  /// Files left out: not videos (`.lnk`, `.nfo`, pictures).
  final int ignored;

  const LocalLibrary({
    this.shows = const [],
    this.movies = const [],
    this.other = const [],
    this.ignored = 0,
  });

  static const empty = LocalLibrary();

  LocalShow? show(String key) => shows.where((s) => s.key == key).firstOrNull;

  /// Every video of the library.
  Iterable<LocalEpisode> get files sync* {
    for (final s in shows) {
      yield* s.files;
    }
    yield* movies;
    yield* other;
  }

  LocalEpisode? byPath(String path) => files.where((e) => e.path == path).firstOrNull;
}

/// The show and season a file names, with its folders as hints.
LocalEpisode readLocalFile(LocalFile file, {Iterable<String> roots = const []}) {
  final p = parseReleaseName(file.name);
  final hints = [for (final d in _foldersBelow(file.path, roots)) parseFolderName(d)];
  FolderHint? first(bool Function(FolderHint h) test) => hints.where(test).firstOrNull;
  final titled = first((h) => h.title.isNotEmpty && RegExp(r'\p{L}', unicode: true).hasMatch(h.title));
  final seasonHint = first((h) => h.season != null);
  final nearest = hints.firstOrNull;
  var kind = switch (p.kind) {
    ReleaseKind.episode => LocalKind.episode,
    ReleaseKind.extra => LocalKind.extra,
    ReleaseKind.movie => LocalKind.movie,
    ReleaseKind.other => LocalKind.other,
  };
  String? extra = p.extra;
  var ownTitle = p.series.trim();
  // A file in an `Extras` / `NCOP` folder is an extra of the show above;
  // a name that says nothing else (`Creditless Opening 1`) is its label.
  if (nearest != null && nearest.extras && kind != LocalKind.movie) {
    if (kind == LocalKind.episode) extra = 'Extra ${p.episode}';
    if (kind == LocalKind.other) {
      extra = ownTitle;
      ownTitle = '';
    }
    kind = LocalKind.extra;
  }
  final usesFolder = kind != LocalKind.other && ownTitle.isEmpty;
  final title = usesFolder && titled != null ? titled.title : ownTitle;
  final season = p.season ?? (kind == LocalKind.movie ? null : seasonHint?.season);
  final seasonName = p.subtitle ?? (season != null && seasonHint?.season == season ? seasonHint?.subtitle : null);
  return LocalEpisode(
    file: file,
    parsed: p,
    kind: kind,
    showKey: kind == LocalKind.other ? '' : normalizeSeries(title),
    title: title.isEmpty ? file.name : title,
    season: season,
    seasonName: seasonName,
    episode: kind == LocalKind.episode ? p.episode : null,
    extra: kind == LocalKind.extra ? (extra ?? 'Extra') : null,
    movieNumber: kind == LocalKind.movie ? p.movieNumber : null,
  );
}

/// Groups [files] (any kind; only videos are kept) into shows. [roots]:
/// the watched folders the files were found under; folders below them
/// give hints, the root itself last.
LocalLibrary groupLocal(Iterable<LocalFile> files, {Iterable<String> roots = const []}) {
  var ignored = 0;
  final read = <LocalEpisode>[];
  for (final f in files) {
    if (kindOf(f.path) != FileKind.video) {
      ignored++;
      continue;
    }
    read.add(readLocalFile(f, roots: roots));
  }
  final byKey = <String, List<LocalEpisode>>{};
  final extras = <String, List<LocalEpisode>>{};
  final movies = <String, List<LocalEpisode>>{};
  final other = <LocalEpisode>[];
  for (final e in read) {
    if (e.kind != LocalKind.other && e.showKey.isEmpty) {
      other.add(e);
      continue;
    }
    switch (e.kind) {
      case LocalKind.episode:
        byKey.putIfAbsent(e.showKey, () => []).add(e);
      case LocalKind.extra:
        extras.putIfAbsent(e.showKey, () => []).add(e);
      case LocalKind.movie:
        movies.putIfAbsent(e.showKey, () => []).add(e);
      case LocalKind.other:
        other.add(e);
    }
  }
  // Ranges in folder names (`Bleach 112-150`) say where a run should end.
  final ranges = <String, int>{};
  for (final e in read) {
    if (e.kind != LocalKind.episode) continue;
    final h = parseFolderName(_baseName(e.folder));
    final last = h.lastEpisode;
    if (last == null || h.key != e.showKey && h.key.isNotEmpty) continue;
    final k = '${e.showKey}|${e.season}';
    if (last > (ranges[k] ?? 0)) ranges[k] = last;
  }
  final shows = <LocalShow>[];
  for (final entry in byKey.entries) {
    final key = entry.key;
    final eps = entry.value;
    final bySeason = <int?, List<LocalEpisode>>{};
    for (final e in eps) {
      bySeason.putIfAbsent(e.season, () => []).add(e);
    }
    final numbers = bySeason.keys.toList()..sort(_nullFirst);
    final seasons = [
      for (final n in numbers) _season(n, bySeason[n]!, ranges['$key|$n']),
    ];
    final x = (extras.remove(key) ?? [])..sort(_byExtra);
    final m = (movies.remove(key) ?? [])..sort(_byMovie);
    final all = [...eps, ...x, ...m];
    shows.add(LocalShow(
      key: key,
      title: _mostCommon([for (final e in eps) e.title])!,
      seasons: seasons,
      extras: x,
      movies: m,
      folders: ({for (final e in all) e.folder}.toList()..sort()),
      group: _mostCommon([
        for (final e in all)
          if (e.parsed.group != null) e.parsed.group!
      ]),
    ));
  }
  shows.sort((a, b) {
    final t = a.title.toLowerCase().compareTo(b.title.toLowerCase());
    return t != 0 ? t : a.key.compareTo(b.key);
  });
  // Extras of no show here are just videos; movies of none stand alone.
  for (final list in extras.values) {
    other.addAll(list);
  }
  final standalone = [for (final list in movies.values) ...list]..sort((a, b) {
      final t = a.title.toLowerCase().compareTo(b.title.toLowerCase());
      return t != 0 ? t : _byMovie(a, b);
    });
  other.sort(_byName);
  return LocalLibrary(shows: shows, movies: standalone, other: other, ignored: ignored);
}

LocalSeason _season(int? number, List<LocalEpisode> eps, int? rangeEnd) {
  eps.sort(_byEpisode);
  final present = <int>{for (final e in eps) e.episode!}.toList()..sort();
  final gaps = <EpisodeGap>[];
  var expect = 1;
  for (final n in present) {
    if (n > expect) gaps.add(EpisodeGap(expect, n - 1));
    expect = n + 1;
  }
  if (rangeEnd != null && rangeEnd >= expect) gaps.add(EpisodeGap(expect, rangeEnd));
  return LocalSeason(
      number,
      _mostCommon([
        for (final e in eps)
          if (e.seasonName != null) e.seasonName!
      ]),
      eps,
      gaps);
}

int _nullFirst(int? a, int? b) {
  if (a == b) return 0;
  if (a == null) return -1;
  if (b == null) return 1;
  return a.compareTo(b);
}

int _byName(LocalEpisode a, LocalEpisode b) {
  final t = a.name.toLowerCase().compareTo(b.name.toLowerCase());
  return t != 0 ? t : a.path.compareTo(b.path);
}

int _byEpisode(LocalEpisode a, LocalEpisode b) {
  final e = a.episode!.compareTo(b.episode!);
  if (e != 0) return e;
  // Same episode twice (v2, another group): newest release name first.
  final n = b.name.compareTo(a.name);
  return n != 0 ? n : a.path.compareTo(b.path);
}

final _extraNumber = RegExp(r'(\d+)$');

int _byExtra(LocalEpisode a, LocalEpisode b) {
  final s = _nullFirst(a.season, b.season);
  if (s != 0) return s;
  String word(LocalEpisode e) => e.extra!.replaceFirst(_extraNumber, '').trim().toLowerCase();
  int number(LocalEpisode e) => int.tryParse(_extraNumber.firstMatch(e.extra!)?.group(1) ?? '') ?? 0;
  final w = _extraOrder(word(a)).compareTo(_extraOrder(word(b)));
  if (w != 0) return w;
  final ww = word(a).compareTo(word(b));
  if (ww != 0) return ww;
  final n = number(a).compareTo(number(b));
  return n != 0 ? n : _byName(a, b);
}

// OP before ED (creditless with them), then the rest by name.
int _extraOrder(String word) => switch (word) {
      'op' || 'ncop' => 0,
      'ed' || 'nced' => 1,
      _ => 2,
    };

int _byMovie(LocalEpisode a, LocalEpisode b) {
  final n = (a.movieNumber ?? 0).compareTo(b.movieNumber ?? 0);
  return n != 0 ? n : _byName(a, b);
}

/// The most frequent of [values]; ties go to the first in sort order.
String? _mostCommon(Iterable<String> values) {
  final counts = <String, int>{};
  for (final v in values) {
    counts.update(v, (n) => n + 1, ifAbsent: () => 1);
  }
  if (counts.isEmpty) return null;
  final keys = counts.keys.toList()..sort();
  var best = keys.first;
  for (final k in keys) {
    if (counts[k]! > counts[best]!) best = k;
  }
  return best;
}

/// Folder names between the watched folder [roots] holding [path] and
/// the file, nearest first, then the watched folder's own name; just the
/// parent when no root holds it.
List<String> _foldersBelow(String path, Iterable<String> roots) {
  final parts = _split(path);
  if (parts.length < 2) return const [];
  final dirs = parts.sublist(0, parts.length - 1);
  List<String>? best;
  for (final r in roots) {
    final rp = _split(r);
    if (rp.length > dirs.length) continue;
    var ok = true;
    for (var i = 0; i < rp.length; i++) {
      if (rp[i] != dirs[i]) {
        ok = false;
        break;
      }
    }
    if (ok && (best == null || rp.length > best.length)) best = rp;
  }
  if (best == null) return [dirs.last];
  final below = dirs.sublist(best.length).reversed.toList();
  return [...below, if (best.isNotEmpty) best.last];
}

List<String> _split(String path) => path.split(RegExp(r'[/\\]')).where((p) => p.isNotEmpty).toList();

String _baseName(String path) {
  final parts = _split(path);
  return parts.isEmpty ? path : parts.last;
}

String _parent(String path) {
  final i = path.lastIndexOf(RegExp(r'[/\\]'));
  return i <= 0 ? (i == 0 ? path.substring(0, 1) : '') : path.substring(0, i);
}

String _extension(String name) {
  final dot = name.lastIndexOf('.');
  return dot <= 0 ? '' : name.substring(dot + 1).toLowerCase();
}
