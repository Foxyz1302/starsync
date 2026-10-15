// restructure: rewrite in step 4 (Library + Media identity): groupBySeries
// becomes L1 local grouping; the scan and classify tests stay.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_together/src/files/name_parser.dart';
import 'package:watch_together/src/files/scanner.dart';

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

VideoFile _v(String name) =>
    VideoFile('/x/$name', 1, parseReleaseName(name), DateTime(2020));

void main() {
  setUp(() => _root = Directory.systemTemp.createTempSync('files_scan_'));
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
    expect(ep.parsed.episode, 2);
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

  group('groupBySeries', () {
    test('groups across spellings, sorts by season then episode', () {
      final g = groupBySeries([
        _v('[A] Re:Zero S2 - 02 [1080p].mkv'),
        _v('[A] Re:Zero - 10 [1080p].mkv'),
        _v('[B] Re Zero - 02 [720p].mkv'),
        _v('[A] Re:Zero S2 - 01 [1080p].mkv'),
        _v('[A] Re:Zero - NCOP1 [1080p].mkv'),
        _v('Other Show - 03.mkv'),
        _v('Other Show - 01.mkv'),
        _v('Movie.2020.1080p.mkv'),
        _v('vid_2024_final.mp4'),
        _v('[A] Lonely - OVA.mkv'),
      ]);
      expect(g.series.map((s) => s.title), ['Other Show', 'Re:Zero']);
      final re = g.series[1];
      expect(re.episodes.map((v) => v.parsed.label),
          ['E02', 'E10', 'S02E01', 'S02E02']);
      expect(re.seasons, [1, 2]);
      expect(re.extras.single.parsed.extra, 'NCOP1');
      expect(g.series[0].episodes.map((v) => v.parsed.episode), [1, 3]);
      expect(g.loose.map((v) => v.name), [
        '[A] Lonely - OVA.mkv',
        'Movie.2020.1080p.mkv',
        'vid_2024_final.mp4',
      ]);
    });

    test('empty input', () {
      final g = groupBySeries(const []);
      expect(g.series, isEmpty);
      expect(g.loose, isEmpty);
    });
  });
}
