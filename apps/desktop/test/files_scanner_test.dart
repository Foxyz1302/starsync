import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:starsync/src/files/scanner.dart';
import 'package:sync_relay_core/core.dart' show groupLocal, readLocalFile, EpisodeGap, LocalKind;

// The Files scan on a real (generated) tree, and the library's L1
// grouping over what it found (core's own tests cover the grouping
// rules on paths alone).

final _tmp = Platform.environment['WT_TEST_TMP'] ?? Directory.systemTemp.path;

late Directory _root;

String _p(String rel) => '${_root.path}/$rel';

void _file(String rel, {int size = 10}) {
  final f = File(_p(rel))..createSync(recursive: true);
  if (size > 0) {
    final raf = f.openSync(mode: FileMode.write);
    raf.truncateSync(size);
    raf.closeSync();
  }
}

void main() {
  setUp(() => _root = Directory(_tmp).createTempSync('files_scan_'));
  tearDown(() => _root.deleteSync(recursive: true));

  test('classifies, skips hidden and samples, pairs sidecar subtitles',
      () async {
    _file('Show/[Grp] Show - 01 [1080p].mkv');
    _file('Show/[Grp] Show - 01 [1080p].ass');
    _file('Show/[Grp] Show - 02 [1080p].mkv');
    _file('Show/[Grp] Show - 02 [1080p].en.srt');
    _file('Show/[Grp] Show - 02 [1080p].en.forced.srt');
    _file('Show/unrelated.srt');
    _file('Show/sample-show.mkv');
    _file('Show/info.nfo');
    _file('Show/cover.jpg');
    _file('Movie.2020.1080p.BluRay.mp4');
    _file('Movie.2020.1080p.BluRay.nfo');
    _file('.hidden.mkv');
    _file('.cache/inside.mkv');
    _file('deep/a/b/c/clip.webm');
    _file('Trailer big.mkv', size: 301 << 20); // sparse
    Link(_p('link-to-show')).createSync(_p('Show'));
    Link(_p('link.mkv')).createSync(_p('Movie.2020.1080p.BluRay.mp4'));

    final scan = await scanFolder(_root.path);
    final names = scan.videos.map((v) => v.name).toList()..sort();
    expect(names, [
      'Movie.2020.1080p.BluRay.mp4',
      'Trailer big.mkv',
      '[Grp] Show - 01 [1080p].mkv',
      '[Grp] Show - 02 [1080p].mkv',
      'clip.webm',
    ]);
    expect(scan.hiddenCount, 4); // sample, nfo, jpg, nfo
    expect(scan.hiddenExamples, hasLength(4));
    expect(scan.hiddenExamples, contains('sample-show.mkv'));
    expect(scan.truncated, isFalse);
    expect(scan.subtitles[_p('Show/[Grp] Show - 01 [1080p].mkv')],
        [_p('Show/[Grp] Show - 01 [1080p].ass')]);
    expect(scan.subtitles[_p('Show/[Grp] Show - 02 [1080p].mkv')], [
      _p('Show/[Grp] Show - 02 [1080p].en.forced.srt'),
      _p('Show/[Grp] Show - 02 [1080p].en.srt'),
    ]);
    expect(scan.subtitles.containsKey(_p('Movie.2020.1080p.BluRay.mp4')),
        isFalse);

    final ep = scan.videos.firstWhere((v) => v.name.contains('- 02'));
    expect(readLocalFile(ep).episode, 2);
    expect(ep.size, 10);
    expect(ep.modified.year, DateTime.now().year);
  });

  test('only language/flag suffixes pair a subtitle with a shorter name',
      () async {
    _file('Show.mkv');
    _file('Show.pt-BR.srt');
    _file('Show.S01E01.srt');
    final scan = await scanFolder(_root.path);
    expect(scan.subtitles[_p('Show.mkv')], [_p('Show.pt-BR.srt')]);
  });

  test('stops after the file limit and says so', () async {
    for (var i = 0; i < 30; i++) {
      _file('f$i.mkv', size: 0);
    }
    final scan = await scanFolder(_root.path, maxFiles: 12);
    expect(scan.truncated, isTrue);
    expect(scan.videos, hasLength(12));
  });

  test('hidden examples stop at 6', () async {
    for (var i = 0; i < 9; i++) {
      _file('note$i.txt', size: 0);
    }
    final scan = await scanFolder(_root.path);
    expect(scan.hiddenCount, 9);
    expect(scan.hiddenExamples, hasLength(6));
  });

  test('a missing folder is an empty scan', () async {
    final scan = await scanFolder(_p('nope'));
    expect(scan.videos, isEmpty);
    expect(scan.truncated, isFalse);
  });

  test('kindOf', () {
    expect(kindOf('/a/b.MKV'), FileKind.video);
    expect(kindOf('b.m2ts'), FileKind.video);
    expect(kindOf('b.SUP'), FileKind.subtitle);
    expect(kindOf('b.nfo'), FileKind.other);
    expect(kindOf('mkv'), FileKind.other);
  });

  test('a generated tree of the Binux names, scanned and grouped (L1)', () async {
    const b1 = '[Judas] Bleach 001-055 [BD 1080p][HEVC x265 10bit]';
    const b2 = '[Judas] Bleach 056-111 [BD 1080p][HEVC x265 10bit]';
    const b3 = '[Judas] Bleach 112-139 [BD 1080p][HEVC x265 10bit][Dual-Audio][Eng-Subs]';
    const sao = '[Judas] Sword Art Online (Season 3 - Alicization) [BD 1080p][HEVC x265 10bit][Eng-Subs]';
    String n3(int n) => n.toString().padLeft(3, '0');
    // The first Bleach folder holds 1-byte shortcuts only.
    for (final j in ['Amine', 'App', 'Audio', 'Data', 'Document', 'Download', 'Image', 'Internal storage', 'Recent', 'Video']) {
      _file('$b1/$j#D4aIyEEtZEWR9gBorzBWiMh_.lnk', size: 1);
    }
    for (final n in [56, 57, 58, 59, 60, 61, 62, 63, 64, 65, 108, 109, 110, 111]) {
      _file('$b2/[Judas] Bleach - ${n3(n)}.mkv');
    }
    for (var n = 112; n <= 139; n++) {
      _file('$b3/[Judas] Bleach - ${n3(n)}.mkv');
    }
    for (var n = 1; n <= 24; n++) {
      _file('$sao/[Judas] Sword Art Online S3 - ${n.toString().padLeft(2, '0')}.mkv');
    }
    for (final x in ['Opening 1', 'Opening 2', 'Opening 3', 'Ending 1', 'Ending 2']) {
      _file('$sao/[Judas] Sword Art Online S3 - $x.mkv');
    }
    _file('[Judas] Re.Zero - S04E17.mkv');
    _file('[Erai-raws] Kimetsu no Yaiba - Mugenjou Hen - Movie 01 [1080p CR WEBRip HEVC AAC][MultiSub][8E47462C].mkv');

    final scan = await scanFolder(_root.path);
    expect(scan.videos, hasLength(14 + 28 + 24 + 5 + 2));
    expect(scan.hiddenCount, 10, reason: 'the shortcuts are not videos');
    final lib = groupLocal(scan.videos, roots: [_root.path]);
    expect(lib.shows.map((s) => s.title), ['Bleach', 'Re.Zero', 'Sword Art Online']);
    final bleach = lib.show('bleach')!;
    expect(bleach.folders, [_p(b2), _p(b3)]);
    expect(bleach.seasons.single.gaps, const [EpisodeGap(1, 55), EpisodeGap(66, 107)]);
    final s = lib.show('sword art online')!;
    expect([s.seasons.single.number, s.seasons.single.name], [3, 'Alicization']);
    expect(s.extras.map((e) => e.label), ['OP1', 'OP2', 'OP3', 'ED1', 'ED2']);
    expect(lib.show('re zero')!.seasons.single.number, 4);
    expect(lib.movies.single.kind, LocalKind.movie);
    expect(lib.movies.single.title, 'Kimetsu no Yaiba - Mugenjou Hen');
    expect(lib.other, isEmpty);
  });
}
