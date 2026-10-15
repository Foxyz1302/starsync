import 'package:flutter_test/flutter_test.dart';
import 'package:starsync/src/library/media_refs.dart';
import 'package:starsync/src/session/now_playing_info.dart';
import 'package:sync_relay_core/core.dart';

// `media.ref` producers other than the library (Jellyfin items, links)
// and what receivers make of a ref.

void main() {
  group('Jellyfin', () {
    final series = JellyfinItem.fromJson({
      'Id': 's',
      'Name': 'Frieren',
      'Type': 'Series',
      'ProviderIds': {'AniList': '154587', 'Tvdb': '424536', 'Imdb': 'tt22248376'},
    });
    final episode = JellyfinItem.fromJson({
      'Id': 'e',
      'Name': 'The Journey\'s End',
      'Type': 'Episode',
      'SeriesName': 'Frieren',
      'ParentIndexNumber': 1,
      'IndexNumber': 1,
      'ProviderIds': {'Tvdb': '9999999'},
    });

    test('provider ids: the show\'s for an episode, never the episode\'s own', () {
      expect(series.providerId('anilist'), 154587);
      expect(jellyfinMediaRef(episode, series: series),
          const MediaRef(kind: 'episode', title: 'Frieren', anilistId: 154587, tvdbId: 424536, season: 1, ep: 1));
      expect(jellyfinMediaRef(episode),
          const MediaRef(kind: 'episode', title: 'Frieren', season: 1, ep: 1));
    });

    test('movies carry their own ids; specials are extras; folders none', () {
      final movie = JellyfinItem.fromJson(
          {'Id': 'm', 'Name': 'Suzume', 'Type': 'Movie', 'ProviderIds': {'AniList': '142770'}});
      expect(jellyfinMediaRef(movie), const MediaRef(kind: 'movie', title: 'Suzume', anilistId: 142770));
      final special = JellyfinItem.fromJson(
          {'Id': 'x', 'Name': 'OVA', 'Type': 'Episode', 'SeriesName': 'Frieren', 'ParentIndexNumber': 0, 'IndexNumber': 1});
      expect(jellyfinMediaRef(special)!.kind, 'extra');
      expect(jellyfinMediaRef(series), isNull);
    });

    test('from a pick\'s lines alone', () {
      expect(jellyfinPickRef('The Pilot', 'Show · S2E6'), const MediaRef(kind: 'episode', title: 'Show', season: 2, ep: 6));
      expect(jellyfinPickRef('Movie', '2019'), const MediaRef(kind: 'movie', title: 'Movie'));
    });
  });

  test('links: kind and title from the name, best effort', () {
    expect(linkMediaRef('[SubsPlease] Frieren - 05 (1080p).mkv'),
        const MediaRef(kind: 'episode', title: 'Frieren', absolute: 5));
    expect(linkMediaRef('Show.S01E03.mkv'), const MediaRef(kind: 'episode', title: 'Show', season: 1, ep: 3));
    expect(linkMediaRef('A funny cat'), const MediaRef(kind: 'movie', title: 'A funny cat'));
  });

  group('receivers', () {
    test('a ref names the show and the episode; art stays by hash', () {
      final np = nowPlayingOf({
        'name': '[Judas] Re.Zero - S04E17.mkv',
        'relay': {'source': 'm2'},
        'art': {'poster': 'p', 'banner': 'b'},
        'ref': {'kind': 'episode', 'title': 'Re:ZERO Season 4', 'anilistId': 189046, 'anilistEp': 17, 'season': 4, 'ep': 17},
      })!;
      expect([np.title, np.episode, np.posterHash, np.bannerHash], ['Re:ZERO Season 4', 'S4 E17', 'p', 'b']);
      final abs = nowPlayingOf({
        'name': '[Judas] Bleach - 108.mkv',
        'ref': {'kind': 'episode', 'title': 'Bleach', 'anilistId': 269, 'anilistEp': 108, 'absolute': 108},
      })!;
      expect([abs.title, abs.episode], ['Bleach', 'E108']);
    });

    test('extras keep their marker, movies have no episode line, no ref falls back to the name', () {
      expect(
          nowPlayingOf({
            'name': '[Judas] Sword Art Online S3 - Opening 1.mkv',
            'ref': {'kind': 'extra', 'title': 'Sword Art Online: Alicization', 'anilistId': 100182},
          })!
              .episode,
          'OP1');
      final movie = nowPlayingOf({
        'name': 'x.mkv',
        'ref': {'kind': 'movie', 'title': 'Demon Slayer: Infinity Castle'},
      })!;
      expect([movie.title, movie.episode], ['Demon Slayer: Infinity Castle', null]);
      final plain = nowPlayingOf({'name': '[SubsPlease] Frieren - 05.mkv'})!;
      expect([plain.title, plain.episode], ['Frieren', 'E5']);
    });
  });
}
