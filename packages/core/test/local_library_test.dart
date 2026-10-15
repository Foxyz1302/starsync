import 'package:sync_relay_core/core.dart';
import 'package:test/test.dart';

// L1 grouping (groupLocal) over the names of a real anime folder: three
// Bleach folders (one holding only shortcut junk) with absolute numbering
// and a hole, a Sword Art Online season folder with OP/ED extras, a loose
// Re:Zero S04E17 and a Kimetsu no Yaiba movie. Paths only: nothing here
// touches the disk (the app's scanner test walks a generated tree).

const root = '/lib/Binux';
const bleach1 = '$root/[Judas] Bleach 001-055 [BD 1080p][HEVC x265 10bit]';
const bleach2 = '$root/[Judas] Bleach 056-111 [BD 1080p][HEVC x265 10bit]';
const bleach3 = '$root/[Judas] Bleach 112-139 [BD 1080p][HEVC x265 10bit][Dual-Audio][Eng-Subs]';
const sao = '$root/[Judas] Sword Art Online (Season 3 - Alicization) [BD 1080p][HEVC x265 10bit][Eng-Subs]';

String three(int n) => n.toString().padLeft(3, '0');
String two(int n) => n.toString().padLeft(2, '0');

/// The Binux names (and order as `find` lists them: not sorted).
List<String> binux() => [
      '$root/[Erai-raws] Kimetsu no Yaiba - Mugenjou Hen - Movie 01 [1080p CR WEBRip HEVC AAC][MultiSub][8E47462C].mkv',
      for (final junk in ['Amine', 'App', 'Audio', 'Document', 'Download', 'Image', 'Recent', 'Video'])
        '$bleach1/$junk#DfopghDGLvYAG.lnk',
      for (final n in [...List.generate(10, (i) => 56 + i), 108, 109, 110, 111]) '$bleach2/[Judas] Bleach - ${three(n)}.mkv',
      for (var n = 139; n >= 112; n--) '$bleach3/[Judas] Bleach - ${three(n)}.mkv',
      '$root/[Judas] Re.Zero - S04E17.mkv',
      for (var n = 1; n <= 24; n++) '$sao/[Judas] Sword Art Online S3 - ${two(n)}.mkv',
      for (final x in ['Ending 1', 'Ending 2', 'Opening 1', 'Opening 2', 'Opening 3'])
        '$sao/[Judas] Sword Art Online S3 - $x.mkv',
    ];

LocalLibrary group(Iterable<String> paths) =>
    groupLocal([for (final p in paths) LocalFile(p, 1 << 30, DateTime(2026))], roots: [root]);

void main() {
  test('the Binux folder: three shows, a movie, junk left out', () {
    final lib = group(binux());
    expect(lib.shows.map((s) => s.title), ['Bleach', 'Re.Zero', 'Sword Art Online']);
    expect(lib.movies.map((m) => (m.title, m.label)), [('Kimetsu no Yaiba - Mugenjou Hen', 'Movie 1')]);
    expect(lib.other, isEmpty);
    expect(lib.ignored, 8, reason: 'the .lnk shortcuts');
  });

  test('Bleach: one show across folders, absolute numbering, the hole known', () {
    final bleach = group(binux()).show('bleach')!;
    expect(bleach.folders, [bleach2, bleach3]);
    expect(bleach.group, 'Judas');
    final run = bleach.seasons.single;
    expect(run.absolute, isTrue);
    expect(run.number, isNull);
    expect(run.distinct.map((e) => e.episode), [...List.generate(10, (i) => 56 + i), ...List.generate(32, (i) => 108 + i)]);
    expect(run.gaps, const [EpisodeGap(1, 55), EpisodeGap(66, 107)]);
    expect(bleach.episodeCount, 42);
    expect(run.episodes.first.label, 'E56');
    expect(run.episodes.first.key, 'bleach|s|e56');

    // Next: from nothing it starts at 56 (1–55 missing); after 65 it
    // skips 66–107; after 111 it is 112, nothing skipped; 139 is the end.
    final start = bleach.nextAfter(null)!;
    expect([start.episode.episode, start.skipped], [56, const EpisodeGap(1, 55)]);
    final at65 = run.episodes.firstWhere((e) => e.episode == 65);
    final skip = bleach.nextAfter(at65.key)!;
    expect([skip.episode.episode, skip.skipped?.label], [108, '66–107']);
    final at111 = run.episodes.firstWhere((e) => e.episode == 111);
    expect([bleach.nextAfter(at111.key)!.episode.episode, bleach.nextAfter(at111.key)!.skipped], [112, null]);
    expect(bleach.nextAfter('bleach|s|e139'), isNull);
    // An episode no longer in the folders: the next one after its number.
    expect(bleach.nextAfter('bleach|s|e70')!.episode.episode, 108);
  });

  test('Sword Art Online: season and its name from the folder, OP/ED as extras', () {
    final s = group(binux()).show('sword art online')!;
    final season = s.seasons.single;
    expect([season.number, season.name, season.title], [3, 'Alicization', 'Season 3 · Alicization']);
    expect(season.distinct.map((e) => e.episode), List.generate(24, (i) => i + 1));
    expect(season.gaps, isEmpty);
    expect(s.extras.map((e) => e.label), ['OP1', 'OP2', 'OP3', 'ED1', 'ED2']);
    expect(s.extras.every((e) => e.kind == LocalKind.extra && e.season == 3), isTrue);
    expect(season.episodes.first.label, 'S03E01');
    final first = s.nextAfter(null)!;
    expect([first.episode.episode, first.skipped], [1, null]);
  });

  test('Re:Zero: a loose S04E17 is a show of its own, numbers as found', () {
    final re = group(binux()).show('re zero')!;
    final s4 = re.seasons.single;
    expect([s4.number, s4.distinct.single.episode, s4.gaps], [4, 17, const [EpisodeGap(1, 16)]]);
    expect(re.folders, [root]);
  });

  test('deterministic: any input order gives the same library', () {
    String dump(LocalLibrary l) => [
          for (final s in l.shows) '${s.key}:${[for (final e in s.files) e.path].join(',')}',
          for (final m in l.movies) m.path,
        ].join('\n');
    final a = group(binux());
    final b = group(binux().reversed);
    final c = group([...binux()]..sort());
    expect(dump(b), dump(a));
    expect(dump(c), dump(a));
  });

  test('folder hints: titles for bare names, season folders, extras folders, ranges', () {
    final lib = group([
      '$root/Frieren/Season 2/01.mkv',
      '$root/Frieren/Season 2/02.mkv',
      '$root/Frieren/Season 2/Extras/Creditless Opening.mkv',
      '$root/Frieren/Frieren - 05.mkv',
      '$root/Show 01-12/Show - 01.mkv',
      '$root/Show 01-12/Show - 02.mkv',
      '$root/clip.mp4',
      '$root/Lonely/[A] Lonely - OVA.mkv',
    ]);
    final f = lib.show('frieren')!;
    expect(f.seasons.map((s) => s.number), [null, 2]);
    expect(f.season(2)!.distinct.map((e) => e.episode), [1, 2]);
    expect(f.extras.single.extra, 'Creditless Opening');
    // A range in the folder name: what should follow is missing too.
    expect(lib.show('show')!.seasons.single.gaps, const [EpisodeGap(3, 12)]);
    // An extra of no show here, and a clip: just videos.
    expect(lib.other.map((e) => e.name), ['[A] Lonely - OVA.mkv', 'clip.mp4']);
  });

  test('copies of one episode share its key; the newest name comes first', () {
    final lib = group([
      '$root/a/[A] Show - 01.mkv',
      '$root/a/[A] Show - 01v2.mkv',
      '$root/a/[A] Show - 02.mkv',
    ]);
    final s = lib.shows.single.seasons.single;
    expect(s.episodes.map((e) => e.name), ['[A] Show - 01v2.mkv', '[A] Show - 01.mkv', '[A] Show - 02.mkv']);
    expect(s.distinct.map((e) => e.name), ['[A] Show - 01v2.mkv', '[A] Show - 02.mkv']);
    expect(s.episodes[0].key, s.episodes[1].key);
  });
}
