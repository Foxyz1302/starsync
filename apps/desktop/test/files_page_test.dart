// restructure: rewrite in step 4 (Library + Media identity): series
// grouping on the page follows L1/L2.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:watch_together/src/files/folder_store.dart';
import 'package:watch_together/src/files/scanner.dart';
import 'package:watch_together/src/files/thumbnails.dart';
import 'package:watch_together/src/files/ui/file_tiles.dart';
import 'package:watch_together/src/files/ui/files_page.dart';

// The Files page over a real (tiny) folder tree: the scan runs in-line
// instead of in an isolate and thumbnails come from a fake loader, so
// nothing here decodes video.

late Directory tmp;
late String anime;
late FolderStore store;
late List<String> thumbRequests;
late int scans;

void touch(String path) => File(path)
  ..createSync(recursive: true)
  ..writeAsStringSync('x');

Future<FolderScan> inlineScan(String dir) async {
  scans++;
  return scanFolderSync(dir);
}

Future<Thumbnail?> fakeThumb(String path, {bool Function()? cancelled}) async {
  thumbRequests.add(path);
  return const Thumbnail('/nonexistent/thumb.jpg', Duration(minutes: 24));
}

Future<void> frames(WidgetTester tester, [int n = 10]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> pumpPage(
  WidgetTester tester, {
  Size size = const Size(1280, 800),
  bool solo = false,
  bool relayed = false,
  Future<String?> Function(String path)? onPlay,
  ThumbnailLoader? thumbnails,
  Future<String?> Function()? pickFolder,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: FilesPage(
        solo: solo,
        relayed: relayed,
        onPlay: onPlay ?? (_) async => null,
        thumbnails: thumbnails ?? fakeThumb,
        scan: inlineScan,
        store: store,
        pickFolder: pickFolder,
      ),
    ),
  ));
  await frames(tester);
}

Future<void> openFolder(WidgetTester tester, String name) async {
  await tester.tap(find.text(name).first);
  await frames(tester);
}

/// Series start collapsed: a click on the header lists the episodes.
Future<void> openSeries(WidgetTester tester, [String title = 'Show']) async {
  await tester.tap(find.descendant(of: find.byType(SeriesHeader), matching: find.text(title)));
  await frames(tester);
}

void main() {
  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('files_page_');
    anime = '${tmp.path}/anime';
    for (final f in [
      '[Grp] Show - 01.mkv',
      '[Grp] Show - 02.mkv',
      '[Grp] Show - 03.mkv',
      '[Grp] Show - NCOP1.mkv',
      '[Grp] Show - 01.srt',
      'Some Movie (2019).mkv',
      'notes.txt',
      'extras/cover.jpg',
    ]) {
      touch('$anime/$f');
    }
    // An in-memory box: the store loads and writes through it, with no
    // file I/O left pending in the widget tests' fake-async zone.
    await Hive.openBox(filesBoxName, bytes: Uint8List(0));
    store = FolderStore();
    await store.ensureLoaded();
    thumbRequests = [];
    scans = 0;
    resetFilesPageSession();
  });

  tearDown(() async {
    await Hive.close();
    tmp.deleteSync(recursive: true);
  });

  testWidgets('sidebar names folders by their last segment, header follows', (tester) async {
    store.addFolder('$anime/');
    await pumpPage(tester, pickFolder: () async => '${tmp.path}/movies');
    expect(find.text('Folders'), findsOneWidget);
    expect(find.text('anime'), findsOneWidget);
    expect(find.text('Recent'), findsNWidgets(2)); // sidebar + header
    expect(find.text('Nothing played yet'), findsOneWidget);
    expect(scans, 0, reason: 'folders are scanned when opened');

    await openFolder(tester, 'anime');
    expect(find.text('anime'), findsNWidgets(2)); // sidebar + header
    expect(find.text('$anime/'), findsOneWidget); // full path under it
    expect(find.text('Recent'), findsOneWidget);
    expect(find.text('5 videos'), findsOneWidget); // sidebar subtitle
    expect(scans, 1);

    // Back and forth: the scan is kept.
    await openFolder(tester, 'Recent');
    await openFolder(tester, 'anime');
    expect(scans, 1);

    // Add folder: picked, stored, opened.
    Directory('${tmp.path}/movies').createSync();
    await tester.tap(find.text('Add folder'));
    await frames(tester);
    expect(store.folders.value, ['$anime/', '${tmp.path}/movies']);
    expect(find.text('movies'), findsNWidgets(2));
    expect(find.text('No videos here'), findsOneWidget);

    await tester.tap(find.byTooltip('Remove folder').last);
    await frames(tester);
    expect(store.folders.value, ['$anime/']);
    expect(find.text('Recent'), findsNWidgets(2));
  });

  testWidgets('episodes group into series, the rest is a card grid', (tester) async {
    store.addFolder(anime);
    await pumpPage(tester);
    await openFolder(tester, 'anime');
    expect(find.byType(SeriesHeader), findsOneWidget);
    expect(find.text('Show'), findsOneWidget);
    expect(find.text('3 episodes · 1 extra · Grp'), findsOneWidget);
    // Collapsed until clicked; open for the rest of the session.
    expect(find.text('E01'), findsNothing);
    await openSeries(tester);
    for (final l in ['E01', 'E02', 'E03', 'NCOP1']) {
      expect(find.text(l), findsOneWidget);
    }
    expect(find.text('[Grp] Show - 02.mkv'), findsOneWidget);
    expect(find.byType(VideoCard), findsOneWidget);
    expect(find.text('Some Movie (2019)'), findsOneWidget);
    expect(find.text('Other videos'), findsOneWidget);
    // Durations come from the thumbnail.
    expect(find.text('24:00 · 1 KB'), findsNWidgets(4));
    expect(find.text('24:00'), findsOneWidget); // card badge

    await openFolder(tester, 'Recent');
    await openFolder(tester, 'anime');
    expect(find.text('E01'), findsOneWidget);
    await openSeries(tester);
    expect(find.text('E01'), findsNothing);
    expect(find.byType(VideoCard), findsOneWidget);
  });

  testWidgets('hidden files are counted and some can be shown', (tester) async {
    store.addFolder(anime);
    await pumpPage(tester);
    await openFolder(tester, 'anime');
    expect(find.text('5 videos in 1 series · 2 other files hidden · 1 subtitle file'),
        findsOneWidget);
    expect(find.text('notes.txt'), findsNothing);
    await tester.tap(find.text('Show some'));
    await frames(tester);
    expect(find.text('notes.txt'), findsOneWidget);
    expect(find.text('cover.jpg'), findsOneWidget);
    expect(find.text('not a video'), findsNWidgets(2));
    await tester.tap(find.text('Hide them'));
    await frames(tester);
    expect(find.text('notes.txt'), findsNothing);
  });

  testWidgets('rescan picks up new files', (tester) async {
    store.addFolder(anime);
    await pumpPage(tester);
    await openFolder(tester, 'anime');
    await openSeries(tester);
    touch('$anime/[Grp] Show - 04.mkv');
    expect(find.text('E04'), findsNothing);
    await tester.tap(find.text('Rescan'));
    await frames(tester);
    expect(scans, 2);
    expect(find.text('E04'), findsOneWidget);
    expect(find.text('4 episodes · 1 extra · Grp'), findsOneWidget);
  });

  testWidgets('a play goes to onPlay and into Recent', (tester) async {
    store.addFolder(anime);
    final played = <String>[];
    String? reply;
    await pumpPage(tester, relayed: true, onPlay: (p) async {
      played.add(p);
      return reply;
    });
    expect(find.textContaining('Keep the app open while it plays'), findsOneWidget);
    await openFolder(tester, 'anime');
    await openSeries(tester);

    await tester.tap(find.text('E02'));
    await frames(tester);
    expect(played, ['$anime/[Grp] Show - 02.mkv']);
    expect(store.recent.value, ['$anime/[Grp] Show - 02.mkv']);

    reply = 'Nobody can play mkv here';
    await tester.tap(find.text('Some Movie (2019)'));
    await frames(tester);
    expect(played, hasLength(2));
    expect(find.text('Nobody can play mkv here'), findsOneWidget);
    expect(store.recent.value, hasLength(1), reason: 'failed plays are not recent');

    await openFolder(tester, 'Recent');
    expect(find.text('Show · E02'), findsOneWidget);
    expect(find.text('[Grp] Show - 02.mkv'), findsOneWidget);
  });

  testWidgets('now playing is marked', (tester) async {
    store.addFolder(anime);
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FilesPage(
          relayed: false,
          onPlay: (_) async => null,
          nowPlayingPath: '$anime/[Grp] Show - 03.mkv',
          thumbnails: fakeThumb,
          scan: inlineScan,
          store: store,
        ),
      ),
    ));
    await frames(tester);
    await openFolder(tester, 'anime');
    await openSeries(tester);
    expect(find.text('now playing'), findsOneWidget);
    expect(find.byIcon(Icons.graphic_eq), findsOneWidget);
  });

  testWidgets('narrow: folders become chips above the list', (tester) async {
    store.addFolder('$anime/');
    await pumpPage(tester, size: const Size(600, 800));
    expect(find.text('Folders'), findsNothing);
    expect(find.widgetWithText(InputChip, 'anime'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, 'Recent'), findsOneWidget);
    await tester.tap(find.widgetWithText(InputChip, 'anime'));
    await frames(tester);
    expect(find.text('$anime/'), findsOneWidget);
    await openSeries(tester);
    expect(find.text('E01'), findsOneWidget);
    // The chip's x removes the folder, like the sidebar's.
    await tester.tap(find.byTooltip('Remove folder'));
    await frames(tester);
    expect(store.folders.value, isEmpty);
    expect(find.widgetWithText(InputChip, 'anime'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final size in const [Size(2560, 1080), Size(1100, 700), Size(900, 600), Size(420, 700)]) {
    testWidgets('no overflow at ${size.width.toInt()}x${size.height.toInt()}', (tester) async {
      store.addFolder(anime);
      for (var i = 0; i < 7; i++) {
        touch('$anime/A Movie With A Rather Long Title Indeed Part $i (2020).mkv');
      }
      store.addRecent('$anime/[Grp] Show - 01.mkv');
      await pumpPage(tester, size: size, relayed: true);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('anime').first);
      await frames(tester);
      await openSeries(tester);
      expect(find.text('E01'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Show some'));
      await frames(tester);
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -2000));
      await frames(tester);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('thumbnails load for visible tiles only, and cancel when scrolled away',
      (tester) async {
    final big = '${tmp.path}/big';
    for (var i = 1; i <= 120; i++) {
      touch('$big/Long Show - ${i.toString().padLeft(3, '0')}.mkv');
    }
    store.addFolder(big);
    final gates = <String, bool Function()>{};
    await pumpPage(tester, size: const Size(1100, 700),
        thumbnails: (path, {cancelled}) {
      thumbRequests.add(path);
      gates[path] = cancelled!;
      return Completer<Thumbnail?>().future; // never finishes
    });
    await openFolder(tester, 'big');
    await openSeries(tester, 'Long Show');
    expect(find.text('E01'), findsOneWidget);
    final first = thumbRequests.toSet();
    expect(first, isNotEmpty);
    expect(first.length, lessThan(30));
    expect(first, contains('$big/Long Show - 001.mkv'));
    expect(gates['$big/Long Show - 001.mkv']!(), isFalse);

    // Fly past the middle: tiles that only flash by never ask.
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -6000));
    await tester.pump();
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -6000));
    await frames(tester);
    expect(gates['$big/Long Show - 001.mkv']!(), isTrue);
    expect(thumbRequests, contains('$big/Long Show - 120.mkv'));
    expect(thumbRequests.toSet().length, lessThan(60));
  });
}
