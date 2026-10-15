import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:starsync/src/shell/handoff.dart';

// What a drop or a paste is: decided from paths and text alone (the file
// system stands behind a fake).

void main() {
  const fs = {
    '/v/a.mkv': FileSystemEntityType.file,
    '/v/b.MP4': FileSystemEntityType.file,
    '/v/notes.txt': FileSystemEntityType.file,
    '/v/cover.jpg': FileSystemEntityType.file,
    '/v/Season 1': FileSystemEntityType.directory,
    '/v/folder.mkv': FileSystemEntityType.directory,
    r'C:\Videos\c.mkv': FileSystemEntityType.file,
  };
  Handoff of({List<String> paths = const [], String? text}) =>
      classifyHandoff(paths: paths, text: text, typeOf: (p) => fs[p] ?? FileSystemEntityType.notFound);

  test('videos by extension, in order; others dropped with them are left out', () {
    final h = of(paths: ['/v/notes.txt', '/v/b.MP4', '/v/Season 1', '/v/a.mkv']);
    expect((h as HandoffVideos).paths, ['/v/b.MP4', '/v/a.mkv']);
  });

  test('a folder (even one named like a video), else an image, else nothing', () {
    expect((of(paths: ['/v/notes.txt', '/v/folder.mkv']) as HandoffFolder).path, '/v/folder.mkv');
    expect((of(paths: ['/v/cover.jpg']) as HandoffImage).path, '/v/cover.jpg');
    expect(of(paths: ['/v/notes.txt']), isA<HandoffNothing>());
    expect(of(paths: ['/gone/x.mkv']), isA<HandoffNothing>());
    expect(of(), isA<HandoffNothing>());
  });

  test('pasted text: a link, absolute paths or file URIs; files win over text', () {
    expect(of(text: '  https://cdn.example/a b'), isA<HandoffNothing>());
    expect((of(text: ' https://youtu.be/x?t=1 \n') as HandoffLink).url, 'https://youtu.be/x?t=1');
    expect((of(text: 'HTTP://x.example/v.mp4') as HandoffLink).url, 'HTTP://x.example/v.mp4');
    expect((of(text: '/v/a.mkv\n/v/b.MP4') as HandoffVideos).paths, ['/v/a.mkv', '/v/b.MP4']);
    expect((of(text: 'file:///v/Season%201') as HandoffFolder).path, '/v/Season 1');
    expect((of(text: r'C:\Videos\c.mkv') as HandoffVideos).paths, [r'C:\Videos\c.mkv']);
    expect(of(text: 'v/a.mkv'), isA<HandoffNothing>(), reason: 'relative');
    expect(of(text: 'hello'), isA<HandoffNothing>());
    expect((of(paths: ['/v/Season 1'], text: 'https://x.example') as HandoffFolder).path, '/v/Season 1');
  });
}
