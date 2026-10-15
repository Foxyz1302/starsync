import 'package:flutter_test/flutter_test.dart';
import 'package:starsync/src/files/name_parser.dart';

void _expect(
  String name,
  String series, {
  int? season,
  int? episode,
  String? group,
  int? year,
  String? extra,
  String? label,
}) {
  final p = parseReleaseName(name);
  final why = '$name -> $p';
  expect(p.series, series, reason: why);
  expect(p.season, season, reason: why);
  expect(p.episode, episode, reason: why);
  expect(p.group, group, reason: why);
  expect(p.year, year, reason: why);
  expect(p.extra, extra, reason: why);
  if (label != null) expect(p.label, label, reason: why);
}

void main() {
  group('anime', () {
    test('SubsPlease dash number', () {
      _expect('[SubsPlease] Sousou no Frieren - 25 (1080p) [A1B2C3D4].mkv',
          'Sousou no Frieren',
          episode: 25, group: 'SubsPlease', label: 'E25');
    });
    test('Erai-raws Nth Season', () {
      _expect(
          '[Erai-raws] Kusuriya no Hitorigoto 2nd Season - 04 [1080p][Multiple Subtitle].mkv',
          'Kusuriya no Hitorigoto',
          season: 2, episode: 4, group: 'Erai-raws', label: 'S02E04');
    });
    test('four-digit episode', () {
      _expect('One Piece - 1120 [1080p].mkv', 'One Piece',
          episode: 1120, label: 'E1120');
    });
    test('SxxEyy behind a group', () {
      _expect('[Judas] Vinland Saga - S01E28.mkv', 'Vinland Saga',
          season: 1, episode: 28, group: 'Judas', label: 'S01E28');
    });
    test('S2 in the title and a v2 release', () {
      _expect('Mushoku Tensei S2 - 03v2 [1080p].mkv', 'Mushoku Tensei',
          season: 2, episode: 3, label: 'S02E03');
    });
    test('Season N in the title', () {
      _expect('[Group] Spy x Family Season 2 - 07 [720p].mkv', 'Spy x Family',
          season: 2, episode: 7, group: 'Group');
    });
    test('Episode word', () {
      _expect('Cowboy Bebop - Episode 12.mkv', 'Cowboy Bebop', episode: 12);
      _expect('Cowboy Bebop Ep.05.mkv', 'Cowboy Bebop', episode: 5);
      _expect('Cowboy Bebop EP07.mkv', 'Cowboy Bebop', episode: 7);
    });
    test('numbers in the title are not episodes', () {
      _expect('[SubsPlease] 86 - 05 (1080p).mkv', '86',
          episode: 5, group: 'SubsPlease');
      _expect('Mob Psycho 100 - 03 [1080p].mkv', 'Mob Psycho 100', episode: 3);
      _expect('Mob Psycho 100 III - 03.mkv', 'Mob Psycho 100 III', episode: 3);
    });
    test('batch keeps the first episode', () {
      _expect('Show.S01E01-E02.1080p.WEB.mkv', 'Show', season: 1, episode: 1);
      _expect('Show S01E05E06.mkv', 'Show', season: 1, episode: 5);
      _expect('[Grp] Show - 01-02 [1080p].mkv', 'Show', episode: 1, group: 'Grp');
      _expect('[Grp] Show - 01~12 [1080p].mkv', 'Show', episode: 1, group: 'Grp');
      _expect('Show E01-E02.mkv', 'Show', episode: 1);
    });
    test('resolution, codec, CRC and audio never become episodes', () {
      _expect('[Grp] Show [1080p][HEVC][ABCD1234].mkv', 'Show', group: 'Grp');
      _expect('Show (1920x1080 x264 AAC 5.1).mkv', 'Show');
      _expect('Show 1080p x265 10bit.mkv', 'Show');
      _expect('Show.720p.HDTV.x264-GRP.mkv', 'Show', group: 'GRP');
    });
  });

  group('extras', () {
    test('NCOP / NCED', () {
      _expect('[Grp] Show - NCOP1 [1080p].mkv', 'Show',
          group: 'Grp', extra: 'NCOP1', label: 'NCOP1');
      _expect('[Grp] Show - NCED [1080p].mkv', 'Show',
          group: 'Grp', extra: 'NCED');
      _expect('[Grp] Show S2 NCOP 2 [BD 1080p].mkv', 'Show',
          season: 2, group: 'Grp', extra: 'NCOP2');
    });
    test('OVA, OAD, Special, OP/ED after the dash', () {
      _expect('[Grp] Show - OVA [720p].mkv', 'Show', group: 'Grp', extra: 'OVA');
      _expect('[Grp] Show OVA - 02 [720p].mkv', 'Show',
          group: 'Grp', extra: 'OVA 2');
      _expect('Show - OAD 3.mkv', 'Show', extra: 'OAD 3');
      _expect('Show - Special 1.mkv', 'Show', extra: 'Special 1');
      _expect('Show - SP2.mkv', 'Show', extra: 'SP2');
      _expect('Show - OP1 [1080p].mkv', 'Show', extra: 'OP1');
      _expect('Show - ED.mkv', 'Show', extra: 'ED');
    });
    test('"Special" inside a title is a title', () {
      _expect('Special Operations Unit - 04.mkv', 'Special Operations Unit',
          episode: 4);
    });
  });

  group('scene / western', () {
    test('dotted SxxEyy with a trailing group', () {
      _expect('The.Expanse.S01E07.1080p.WEB.H264-GRP.mkv', 'The Expanse',
          season: 1, episode: 7, group: 'GRP', label: 'S01E07');
    });
    test('year before the episode', () {
      _expect('Doctor.Who.2005.S02E03.720p.mkv', 'Doctor Who',
          season: 2, episode: 3, year: 2005);
      _expect('Fargo (2014) - S03E01.mkv', 'Fargo',
          season: 3, episode: 1, year: 2014);
    });
    test('1x03 style', () {
      _expect('Friends 1x03 The One.avi', 'Friends', season: 1, episode: 3);
    });
    test('season pack name', () {
      _expect('Show.S02.1080p.BluRay.x264-GRP.mkv', 'Show',
          season: 2, group: 'GRP', label: 'S02');
    });
    test('lowercase', () {
      _expect('show.name.s01e02.mkv', 'show name', season: 1, episode: 2);
    });
  });

  group('movies', () {
    test('dotted movie: year taken out of the title', () {
      _expect('Movie.Title.2023.1080p.BluRay.x264.mkv', 'Movie Title',
          year: 2023, label: '');
    });
    test('year in parentheses', () {
      _expect('Movie Title (2019) [1080p].mkv', 'Movie Title', year: 2019);
    });
    test('title that is a number, year too far ahead', () {
      _expect('Blade.Runner.2049.2017.1080p.BluRay.mkv', 'Blade Runner 2049',
          year: 2017);
      _expect('Blade Runner 2049.mkv', 'Blade Runner 2049');
      _expect('1917.2019.1080p.WEB-DL.mkv', '1917', year: 2019);
    });
    test('WEB-DL at the end is not a group', () {
      _expect('Some.Movie.2021.1080p.WEB-DL.mkv', 'Some Movie', year: 2021);
    });
    test('hyphen in the title', () {
      _expect('Spider-Man.2002.1080p.BluRay.mkv', 'Spider-Man', year: 2002);
    });
  });

  group('unstructured', () {
    test('cleaned name, no episode', () {
      _expect('vid_2024_final.mp4', 'vid 2024 final');
      _expect('holiday video.mov', 'holiday video');
      _expect('Dr. Stone - 05.mkv', 'Dr. Stone', episode: 5);
    });
    test('never empty', () {
      expect(parseReleaseName('[Grp].mkv').series, isNotEmpty);
      expect(parseReleaseName('1080p.mkv').series, '1080p');
      expect(parseReleaseName('').series, '');
    });
  });

  test('seriesKey ignores case and punctuation', () {
    expect(parseReleaseName('Re:Zero - 01.mkv').seriesKey,
        parseReleaseName('re zero - 02.mkv').seriesKey);
    expect(parseReleaseName("Frieren: Beyond Journey's End - 01.mkv").seriesKey,
        'frieren beyond journeys end');
  });
}
