import 'package:flutter_test/flutter_test.dart';
import 'package:watch_together/src/session/now_playing.dart';
import 'package:watch_together/src/session/now_playing_info.dart';

void main() {
  group('jellyfinTitle', () {
    test('episodes: series on top, "S1 E2 · Name" below', () {
      expect(jellyfinTitle('The Pilot', 'Show · S1E2'), ('Show', 'S1 E2 · The Pilot'));
      expect(jellyfinTitle('The Pilot', 'Show - S01E02'), ('Show', 'S1 E2 · The Pilot'));
      expect(jellyfinTitle('Ep', 'Re:Zero - Starting Life · S2E10'), ('Re:Zero - Starting Life', 'S2 E10 · Ep'));
    });

    test('movies and partial subtitles', () {
      expect(jellyfinTitle('Movie', '2019'), ('Movie', null));
      expect(jellyfinTitle('Movie', null), ('Movie', null));
      expect(jellyfinTitle('Pilot', 'S1E1'), ('Pilot', 'S1 E1'));
      expect(jellyfinTitle('Special', 'Show'), ('Show', 'Special'));
    });
  });

  group('fileTitle', () {
    test('release names', () {
      expect(fileTitle('[SubsPlease] Frieren - 05 (1080p) [ABCD1234].mkv'), ('Frieren', 'E5'));
      expect(fileTitle('Show.Name.S01E03.1080p.WEB-DL.x264-GRP.mkv'), ('Show Name', 'S1 E3'));
      expect(fileTitle('[Grp] Show - NCOP1 [1080p].mkv'), ('Show', 'NCOP1'));
      expect(fileTitle('Some Movie (2019).mkv'), ('Some Movie', null));
    });

    test('nothing sensible: the raw name minus extension', () {
      expect(fileTitle('[1080p].mkv').$1, '[1080p]');
    });
  });

  test('nowPlayingOf: media map with ref and art', () {
    expect(nowPlayingOf(null), isNull);
    expect(
        nowPlayingOf({
          'name': 'The Pilot',
          'jellyfin': {'serverId': 's', 'itemId': 'i', 'title': 'The Pilot', 'subtitle': 'Show · S1E2'},
          'art': {'poster': 'aaaa', 'banner': 'bbbb'},
        }),
        const NowPlaying(title: 'Show', episode: 'S1 E2 · The Pilot', posterHash: 'aaaa', bannerHash: 'bbbb'));
    expect(nowPlayingOf({'name': 'Show - 12.mkv'}), const NowPlaying(title: 'Show', episode: 'E12'));
  });
}
