import 'dart:convert';
import 'dart:io';

import 'package:sync_relay_core/core.dart';
import 'package:test/test.dart';

JellyfinMediaStream audio(int i, String? lang, String? title, String codec, int ch, {bool def = false}) =>
    JellyfinMediaStream(
        index: i, type: JellyfinStreamType.audio, language: lang, title: title, codec: codec, channels: ch, isDefault: def);

JellyfinMediaStream sub(int i, String? lang, String? title, String codec,
        {bool forced = false, bool def = false, bool hi = false}) =>
    JellyfinMediaStream(
        index: i,
        type: JellyfinStreamType.subtitle,
        language: lang,
        title: title,
        codec: codec,
        isForced: forced,
        isDefault: def,
        isHearingImpaired: hi);

void main() {
  // Copper Warden S1E6 -> S1E7 (captured): jpn+eng eac3 audio, 17 ass/srt subs.
  final eps = (jsonDecode(File('test/fixtures/jellyfin/bs_episodes.json').readAsStringSync())['Items'] as List)
      .map((e) => JellyfinItem.fromJson(e as Map<String, dynamic>))
      .toList();
  final e6 = eps.firstWhere((e) => e.indexNumber == 6).mediaStreams;
  final e7 = eps.firstWhere((e) => e.indexNumber == 7).mediaStreams;
  JellyfinMediaStream at(List<JellyfinMediaStream> s, int i) => s.firstWhere((x) => x.index == i);

  group('captured episodes', () {
    test('each track carries over to the same track', () {
      for (final s in e6.where((s) => s.type != JellyfinStreamType.video)) {
        expect(matchTrack(TrackPreference.fromStream(s), e7)!.index, s.index, reason: '$s');
      }
    });

    test('jpn audio + Signs subs', () {
      final r = matchTracks(audio: at(e6, 1), subtitle: at(e6, 4), streams: e7);
      expect((r.audioStreamIndex, r.subtitleStreamIndex), (1, 4));
    });

    test('subtitles off carries over as -1', () {
      final r = matchTracks(audio: at(e6, 2), subtitlesOff: true, streams: e7);
      expect((r.audioStreamIndex, r.subtitleStreamIndex), (2, -1));
    });

    test('nothing picked: no override', () {
      final r = matchTracks(streams: e7);
      expect((r.audioStreamIndex, r.subtitleStreamIndex), (null, null));
    });
  });

  group('different release next episode', () {
    // Next episode from another group: indices shift, titles differ.
    final next = [
      const JellyfinMediaStream(index: 0, type: JellyfinStreamType.video, codec: 'hevc'),
      audio(1, 'ja', null, 'aac', 2, def: true),
      audio(2, 'en', 'English 5.1', 'eac3', 6),
      audio(3, 'en', 'English Stereo', 'aac', 2),
      sub(4, 'eng', 'Signs & Songs', 'ass', forced: true),
      sub(5, 'eng', 'Full', 'ass', def: true),
      sub(6, 'eng', 'Full [SDH]', 'subrip', hi: true),
      sub(7, 'ger', 'Vollständig', 'ass'),
      sub(8, 'spa', 'Español (España)', 'ass'),
      sub(9, 'spa', 'Español (Latinoamérica)', 'ass'),
    ];

    test('Full subtitles -> "Full", not "Signs & Songs"', () {
      expect(matchTrack(TrackPreference.fromStream(at(e6, 3)), next)!.index, 5);
    });

    test('Signs -> "Signs & Songs"', () {
      expect(matchTrack(TrackPreference.fromStream(at(e6, 4)), next)!.index, 4);
    });

    test('CC (hearing impaired, subrip) -> SDH when titles do not help', () {
      expect(matchTrack(TrackPreference.fromStream(at(e6, 5)), next)!.index, 6);
    });

    test('language is required, 639-1 / 639-2 / B codes equated', () {
      expect(matchTrack(TrackPreference.fromStream(at(e6, 1)), next)!.index, 1); // jpn -> ja
      expect(matchTrack(TrackPreference.fromStream(at(e6, 7)), next)!.index, 7); // deu -> ger
      expect(matchTrack(TrackPreference.fromStream(at(e6, 10)), next), isNull); // fra: none
    });

    test('title picks the regional variant', () {
      expect(
          matchTrack(const TrackPreference(type: JellyfinStreamType.subtitle, language: 'spa', title: 'Spanish (Latin America) Latinoamérica'), next)!
              .index,
          9);
    });

    test('codec then channels break ties', () {
      // "English" eac3 stereo: title comes first, "English Stereo" is closer
      // than "English 5.1" even though the codec differs.
      expect(matchTrack(TrackPreference.fromStream(at(e6, 2)), next)!.index, 3);
      // Same titles: codec beats channel count.
      final same = [audio(1, 'eng', 'English', 'aac', 2), audio(2, 'eng', 'English', 'eac3', 6)];
      expect(matchTrack(TrackPreference.fromStream(at(e6, 2)), same)!.index, 2);
      // No codec match: closest channel count.
      expect(
          matchTrack(const TrackPreference(type: JellyfinStreamType.audio, language: 'eng', codec: 'opus', channels: 2), next)!
              .index,
          3);
      expect(
          matchTrack(const TrackPreference(type: JellyfinStreamType.audio, language: 'eng', codec: 'opus', channels: 8), next)!
              .index,
          2);
    });

    test('type is respected', () {
      expect(matchTrack(const TrackPreference(type: JellyfinStreamType.audio, language: 'spa'), next), isNull);
    });
  });

  test('normalizeLanguage', () {
    expect(normalizeLanguage('en'), 'eng');
    expect(normalizeLanguage('en-US'), 'eng');
    expect(normalizeLanguage('FRE'), 'fra');
    expect(normalizeLanguage('und'), isNull);
    expect(normalizeLanguage(''), isNull);
    expect(normalizeLanguage('tlh'), 'tlh');
  });

  test('undetermined language only matches undetermined', () {
    final streams = [audio(1, null, null, 'aac', 2), audio(2, 'eng', null, 'aac', 2)];
    expect(matchTrack(const TrackPreference(type: JellyfinStreamType.audio, language: 'und'), streams)!.index, 1);
  });
}
