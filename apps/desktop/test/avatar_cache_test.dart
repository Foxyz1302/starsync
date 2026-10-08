import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sync_relay_core/core.dart';
import 'package:sync_relay_server/server.dart';
import 'package:watch_together/src/sync/avatar_cache.dart';
import 'package:watch_together/src/sync/sync_client.dart';

Future<void> _poll(FutureOr<bool> Function() cond, String what) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (DateTime.now().isBefore(deadline)) {
    if (await cond()) return;
    await Future.delayed(const Duration(milliseconds: 50));
  }
  fail('timed out waiting for $what');
}

void main() {
  test('pictures arrive by hash over /a/; profile renames and swaps them', () async {
    final server = SyncServer(const AppConfig(port: 0, secret: 's', name: 'avatars'));
    await server.start();
    final client = SyncClient();
    final cache = AvatarCache(client);
    var notified = 0;
    cache.addListener(() => notified++);
    final first = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, ...List<int>.generate(196, (i) => i % 256)]);
    final second = Uint8List.fromList([0xFF, 0xD8, 0xFF, ...List<int>.generate(197, (i) => 255 - i % 256)]);
    try {
      await client.connect(
        wsUri: Uri.parse('ws://127.0.0.1:${server.boundPort}/sync'),
        secret: 's',
        name: 'alice',
        avatar: base64Encode(first),
      );
      final hash = avatarHashOf(first);
      expect(client.lastState!.members.single.avatarHash, hash);
      await _poll(() => cache.bytesFor(hash) != null, 'first picture');
      expect(cache.bytesFor(hash), first);
      expect(notified, 1);

      client.sendProfile(name: 'bob', avatar: base64Encode(second));
      await _poll(() => client.lastState?.members.single.name == 'bob', 'rename');
      final next = client.lastState!.members.single.avatarHash;
      expect(next, avatarHashOf(second));
      await _poll(() => cache.bytesFor(next) != null, 'second picture');
      expect(cache.bytesFor(hash), first, reason: 'earlier pictures stay cached');

      client.sendProfile(avatar: '');
      await _poll(() => client.lastState?.members.single.avatarHash == '', 'picture removed');
      expect(cache.bytesFor(''), isNull);
    } finally {
      cache.dispose();
      await client.dispose();
      await server.stop();
    }
  });

  test('media art arrives by hash over /i/; a swap clears it', () async {
    final server = SyncServer(const AppConfig(port: 0, secret: 's', name: 'art'));
    await server.start();
    final client = SyncClient();
    final cache = ArtCache(client);
    final poster = Uint8List.fromList([0xFF, 0xD8, 0xFF, ...List<int>.generate(197, (i) => i % 256)]);
    try {
      await client.connect(
        wsUri: Uri.parse('ws://127.0.0.1:${server.boundPort}/sync'),
        secret: 's',
        name: 'alice',
      );
      client.sendSwap(const HelloMedia(name: 'Show - 01.mkv', size: 0, duration: 0, url: 'http://example.com/a.mkv'));
      await _poll(() => client.lastState?.media?['swapBy'] == client.memberId, 'swap');
      client.sendArt(client.lastState!.mediaId, poster: base64Encode(poster));
      await _poll(() => ArtCache.artHashesOf(client.lastState!).isNotEmpty, 'art in state');
      final hash = ArtCache.artHashesOf(client.lastState!).single;
      expect(hash, avatarHashOf(poster));
      await _poll(() => cache.bytesFor(hash) != null, 'art bytes');
      expect(cache.bytesFor(hash), poster);

      client.sendSwap(const HelloMedia(name: 'Other.mkv', size: 0, duration: 0, url: 'http://example.com/b.mkv'));
      await _poll(() => client.lastState?.media?['name'] == 'Other.mkv', 'second swap');
      expect(ArtCache.artHashesOf(client.lastState!), isEmpty);
    } finally {
      cache.dispose();
      await client.dispose();
      await server.stop();
    }
  });
}
