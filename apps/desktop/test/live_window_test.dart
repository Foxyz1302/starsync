import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:starsync/src/playback/live_window.dart';
import 'package:starsync/src/platform/ports/player_host.dart' show liveOpenSegments;
import 'package:sync_relay_core/core.dart' show mpvEdl;

String _playlist(int count, {double seg = 2, bool ended = false}) => [
      '#EXTM3U',
      '#EXT-X-VERSION:3',
      '#EXT-X-TARGETDURATION:${seg.ceil()}',
      '#EXT-X-MEDIA-SEQUENCE:4643',
      for (var i = 0; i < count; i++) ...['#EXTINF:$seg,', 'seg$i.ts'],
      if (ended) '#EXT-X-ENDLIST',
    ].join('\n');

void main() {
  test("a live playlist's window; none once it ended or for anything else", () {
    expect(parseHlsWindow(_playlist(450)), (secs: 900.0, count: 450));
    expect(parseHlsWindow(_playlist(450, ended: true)), isNull);
    expect(parseHlsWindow('<html>'), isNull);
    final master = '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\nlow/index.m3u8\n';
    expect(parseHlsWindow(master), isNull);
    expect(hlsVariantOf(master, Uri.parse('https://cdn/x/master.m3u8')), Uri.parse('https://cdn/x/low/index.m3u8'));
    expect(hlsVariantOf(_playlist(3), Uri.parse('https://cdn/x.m3u8')), isNull);
  });

  test("the playlist inside an EDL is its first part's", () {
    const video = 'https://cdn/v/index.m3u8?a=1;b=%2', audio = 'https://cdn/a/index.m3u8';
    expect(playlistUrlOf(mpvEdl([video, audio])), video);
    expect(playlistUrlOf(audio), audio);
  });

  test('the window back from the edge, the edge taken while the cache reaches it', () {
    final w = LiveWindow();
    expect(w.fromAt(100), isNull, reason: 'nothing known');
    // Read ahead only (far behind): not the edge.
    w.noteEdge(edge: 5150, own: 5000, at: 100);
    expect(w.edgeAt(100), isNull);
    w.noteEdge(edge: 5012, own: 5000, at: 100);
    w.noteEdge(edge: 5010, own: 5000, at: 100.5);
    expect(w.edgeAt(110), 5022, reason: 'the furthest seen, on with the clock');
  });

  test('segments back to open a little before a point, within the window', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      req.response.headers.set('x-seen', req.headers.value('user-agent') ?? '');
      req.response.write(req.uri.path == '/master.m3u8'
          ? '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nmedia.m3u8\n'
          : req.headers.value('user-agent') == 'ua'
              ? _playlist(450)
              : '');
      await req.response.close();
    });
    try {
      final w = LiveWindow();
      w.noteEdge(edge: 5012, own: 5000, at: 100);
      expect(w.segmentsBack(4000, 100), isNull, reason: 'no window read');
      final url = 'http://127.0.0.1:${server.port}/master.m3u8';
      await w.read(mpvEdl([url, 'http://127.0.0.1:${server.port}/audio.m3u8']), const {'User-Agent': 'ua'});
      expect(w.playlist, (secs: 900.0, count: 450));
      // 900 s back from the edge, three segments kept out of reach.
      expect(w.fromAt(100), 5012 - 900 + 6);
      expect(w.segmentsBack(4812, 100), 102, reason: '200 s back: 100 segments, and two before the point');
      expect(w.segmentsBack(5010, 100), liveOpenSegments, reason: 'never nearer than a fresh open');
      expect(w.segmentsBack(0, 100), 449, reason: 'never further back than the window');
    } finally {
      await server.close(force: true);
    }
    final none = LiveWindow();
    await none.read('http://127.0.0.1:1/unreachable.m3u8', const {});
    expect(none.playlist, isNull);
  });
}
