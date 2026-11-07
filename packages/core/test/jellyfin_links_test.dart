import 'package:sync_relay_core/core.dart';
import 'package:test/test.dart';

const id = 'a43e1cfa5013da4ea9323c2ebdc22c3c';
const sid = 'a3c3646f1fc722c7a34e0e47e5450b05';

void main() {
  group('normalizeServerUrl', () {
    final cases = {
      'jelly.example.com': 'https://jelly.example.com',
      '  https://jelly.example.com/  ': 'https://jelly.example.com',
      'https://jelly.example.com/web/#/home.html': 'https://jelly.example.com',
      'https://jelly.example.com/web/index.html': 'https://jelly.example.com',
      'http://192.168.1.5:8096': 'http://192.168.1.5:8096',
      '192.168.1.5:8096/web/': 'http://192.168.1.5:8096',
      'localhost:8096': 'http://localhost:8096',
      'https://example.com/jellyfin/web/#/home': 'https://example.com/jellyfin',
      'https://example.com/jellyfin/': 'https://example.com/jellyfin',
      'HTTPS://Jelly.Example.com': 'https://jelly.example.com',
      'https://jelly.example.com/Items/$id/Download?api_key=x': 'https://jelly.example.com',
    };
    cases.forEach((input, want) {
      test(input, () => expect(normalizeServerUrl(input), want));
    });

    test('rejects junk', () {
      expect(normalizeServerUrl(''), isNull);
      expect(normalizeServerUrl('ftp://x.com'), isNull);
    });
  });

  group('parseJellyfinLink', () {
    test('web details link with serverId', () {
      expect(parseJellyfinLink('https://jelly.example.com/web/#/details?id=$id&serverId=$sid'),
          const JellyfinLink(baseUrl: 'https://jelly.example.com', itemId: id, serverId: sid));
    });

    test('old web link (index.html#!/)', () {
      final l = parseJellyfinLink('https://jelly.example.com/web/index.html#!/details?id=$id')!;
      expect((l.baseUrl, l.itemId, l.serverId), ('https://jelly.example.com', id, null));
    });

    test('sub-path and port are kept', () {
      expect(parseJellyfinLink('http://10.0.0.2:8096/jf/web/#/details?id=$id')!.baseUrl,
          'http://10.0.0.2:8096/jf');
    });

    test('API links', () {
      for (final url in [
        'https://jelly.example.com/Items/$id/Download?api_key=k',
        'https://jelly.example.com/Videos/$id/stream?static=true&mediaSourceId=$id',
        'https://jelly.example.com/Videos/$id/stream.mkv',
        'https://jelly.example.com/Items/$id/Images/Primary?tag=x',
        'https://jelly.example.com/Users/95b50af4ac466551c3887fd2f9f3e785/Items/$id',
        'https://jelly.example.com/Items/$id',
      ]) {
        expect(parseJellyfinLink(url),
            const JellyfinLink(baseUrl: 'https://jelly.example.com', itemId: id), reason: url);
      }
    });

    test('dashed and upper-case GUIDs are normalised', () {
      expect(parseJellyfinLink('https://j.example.com/Items/A43E1CFA-5013-DA4E-A932-3C2EBDC22C3C')!.itemId, id);
    });

    test('not Jellyfin', () {
      expect(parseJellyfinLink('https://www.youtube.com/watch?v=abc'), isNull);
      expect(parseJellyfinLink('https://jelly.example.com/web/#/home.html'), isNull);
      expect(parseJellyfinLink('https://jelly.example.com/Items/notanid'), isNull);
      expect(parseJellyfinLink('/local/file.mkv'), isNull);
    });
  });
}
