// Pieces tracks: HLS playlist parsing (byte ranges folded, init and key
// pieces, refusals), the synthesized playlist, and the track wire.
import 'package:sync_relay_core/core.dart';
import 'package:test/test.dart';

void main() {
  final base = Uri.parse('https://cdn.example/v/index.m3u8');

  test('byte ranges fold into pieces; MAP, AES-128 key and sequence carry over to the served playlist', () {
    final p = parseHlsPlaylist('''
#EXTM3U
#EXT-X-VERSION:7
#EXT-X-TARGETDURATION:6
#EXT-X-MEDIA-SEQUENCE:5
#EXT-X-MAP:URI="main.mp4",BYTERANGE="700@0"
#EXT-X-KEY:METHOD=AES-128,URI="https://keys.example/k1",IV=0x00000000000000000000000000000001
#EXTINF:6.0,
#EXT-X-BYTERANGE:1000@700
main.mp4
#EXTINF:5.5,
#EXT-X-BYTERANGE:2000
main.mp4
#EXT-X-KEY:METHOD=NONE
#EXT-X-DISCONTINUITY
#EXTINF:4,
seg/3.ts?tok=a
#EXT-X-ENDLIST
''', base);
    expect([for (final s in p.sources) (s.url.toString(), s.offset, s.length)], [
      ('https://cdn.example/v/main.mp4', 0, 700),
      ('https://keys.example/k1', null, null),
      ('https://cdn.example/v/main.mp4', 700, 1000),
      ('https://cdn.example/v/main.mp4', 1700, 2000), // offset: end of the previous range
      ('https://cdn.example/v/seg/3.ts?tok=a', null, null),
    ]);
    // Through the wire and back: same shape, same playlist.
    final list = RelayPieceList.fromJson(p.list.toJson())!;
    expect(list.sameShape(p.list), isTrue);
    expect(list.playlist(), '''
#EXTM3U
#EXT-X-VERSION:6
#EXT-X-TARGETDURATION:6
#EXT-X-MEDIA-SEQUENCE:5
#EXT-X-PLAYLIST-TYPE:VOD
#EXT-X-MAP:URI="p/0"
#EXT-X-KEY:METHOD=AES-128,URI="p/1",IV=0x00000000000000000000000000000001
#EXTINF:6.000000,
p/2
#EXTINF:5.500000,
p/3
#EXT-X-DISCONTINUITY
#EXT-X-KEY:METHOD=NONE
#EXTINF:4.000000,
p/4
#EXT-X-ENDLIST
''');
  });

  test('refused: DRM, live, master; a malformed piece list', () {
    String pl(String body, {bool end = true}) => '#EXTM3U\n$body\n#EXTINF:4,\na.ts\n${end ? '#EXT-X-ENDLIST' : ''}';
    Matcher refused(String text) =>
        throwsA(isA<RelayPiecesException>().having((e) => e.message, 'message', text));
    expect(() => parseHlsPlaylist(pl('#EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://x"'), base), refused(drmText));
    expect(() => parseHlsPlaylist(pl('#EXT-X-KEY:METHOD=AES-128,URI="skd://x"'), base), refused(drmText));
    expect(
        () => parseHlsPlaylist(
            pl('#EXT-X-KEY:METHOD=AES-128,URI="k",KEYFORMAT="urn:uuid:edef8ba9-79d6-4ace-a3c8-27dcd51d21ed"'), base),
        refused(drmText));
    expect(() => parseHlsPlaylist(pl(''), base).list, returnsNormally);
    expect(() => parseHlsPlaylist(pl('', end: false), base), refused(liveStreamText));
    expect(() => parseHlsPlaylist('#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nv.m3u8\n', base),
        throwsA(isA<RelayPiecesException>()));
    expect(
        RelayPieceList.fromJson({
          'pieces': [
            {'d': 4.0, 'map': 0},
          ],
        }),
        isNull,
        reason: 'map must name an init piece');
    expect(
        RelayPieceList.fromJson({
          'pieces': [
            {'d': 4.0, 'iv': '0x1"\n#EXT'},
          ],
        }),
        isNull);
  });

  test('track wire: bytes entries as before, pieces with "as"; one pieces track is enough', () {
    final two = MediaRelay.fromJson({
      'source': 'm2',
      'tracks': [
        {'kind': 'video', 'as': 'pieces'},
        {'kind': 'audio', 'as': 'pieces'},
      ],
    });
    expect(two.tracks, const [RelayTrackSpec('video', pieces: true), RelayTrackSpec('audio', pieces: true)]);
    expect(two.toJson()['tracks'], [
      {'kind': 'video', 'as': 'pieces'},
      {'kind': 'audio', 'as': 'pieces'},
    ]);
    final one = MediaRelay.fromJson({
      'tracks': [
        {'kind': 'video', 'as': 'pieces'},
      ],
    });
    expect(one.tracks.single.pieces, isTrue);
    // One byte track is one file; an unknown "as" drops the list.
    expect(
        MediaRelay.fromJson({
          'tracks': [
            {'kind': 'video'},
          ],
        }).tracks,
        isEmpty);
    expect(
        MediaRelay.fromJson({
          'tracks': [
            {'kind': 'video', 'as': 'frames'},
            {'kind': 'audio'},
          ],
        }).tracks,
        isEmpty);
    expect(const MediaRelay(tracks: [RelayTrackSpec('video'), RelayTrackSpec('audio')]).toJson()['tracks'], [
      {'kind': 'video'},
      {'kind': 'audio'},
    ]);
  });
}
