import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:watch_together/src/files/folder_store.dart';

void main() {
  test('folders and recent files persist across a reload', () async {
    final dir = Directory.systemTemp.createTempSync('files_store_');
    addTearDown(() => dir.deleteSync(recursive: true));
    Hive.init(dir.path);

    final a = FolderStore();
    await a.ensureLoaded();
    expect(a.folders.value, isEmpty);
    expect(a.recent.value, isEmpty);
    expect(a.addFolder('/media/anime'), isTrue);
    expect(a.addFolder('/media/movies'), isTrue);
    expect(a.addFolder('/media/anime'), isFalse);
    a.removeFolder('/media/movies');
    a.addFolder('/media/films');
    for (var i = 0; i < 35; i++) {
      a.addRecent('/v/$i.mkv');
    }
    a.addRecent('/v/10.mkv'); // back to the top, not duplicated
    a.removeRecent('/v/33.mkv');
    expect(a.recent.value.first, '/v/10.mkv');
    expect(a.recent.value, hasLength(maxRecentFiles - 1));
    expect(a.recent.value.where((p) => p == '/v/10.mkv'), hasLength(1));
    await Future.delayed(const Duration(milliseconds: 100));
    await Hive.close();

    final b = FolderStore();
    await b.ensureLoaded();
    expect(b.folders.value, ['/media/anime', '/media/films']);
    expect(b.recent.value, a.recent.value);
    expect(b.recent.value.take(3), ['/v/10.mkv', '/v/34.mkv', '/v/32.mkv']);
    b.clearRecent();
    await Future.delayed(const Duration(milliseconds: 100));
    await Hive.close();

    final c = FolderStore();
    await c.ensureLoaded();
    expect(c.recent.value, isEmpty);
    expect(c.folders.value, hasLength(2));
    await Hive.close();
  });
}
