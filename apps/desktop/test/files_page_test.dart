import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:starsync/src/files/folder_store.dart';
import 'package:starsync/src/files/scanner.dart';
import 'package:starsync/src/files/thumbnails.dart';
import 'package:starsync/src/files/ui/file_tiles.dart';
import 'package:starsync/src/files/ui/files_page.dart';
import 'package:starsync/src/files/ui/library_view.dart';
import 'package:starsync/src/library/library_store.dart';
import 'package:starsync/src/library/show_matcher.dart';
import 'package:starsync/src/schedule/anilist.dart';

import 'test_graph.dart';

/// This file's composition root (see test_graph.dart).
final _graph = testGraph();

// The Files tab as a library over a real (tiny) generated tree with the
// names of a real anime folder: the scan runs in-line instead of in an
// isolate, thumbnails come from a fake loader and AniList is a fake, so
// nothing here decodes video or goes online.

final _tmp = Platform.environment['WT_TEST_TMP'] ?? Directory.systemTemp.path;

late Directory tmp;
late String anime;
late FolderStore store;
late List<String> thumbRequests;
late int scans;
late ShowMatcher matcher;
late FakeAniList aniList;

const b1 = '[Judas] Bleach 001-055 [BD 1080p][HEVC x265 10bit]';
const b2 = '[Judas] Bleach 056-111 [BD 1080p][HEVC x265 10bit]';
const b3 = '[Judas] Bleach 112-139 [BD 1080p][HEVC x265 10bit][Dual-Audio][Eng-Subs]';
const sao = '[Judas] Sword Art Online (Season 3 - Alicization) [BD 1080p][HEVC x265 10bit][Eng-Subs]';
const kimetsu =
    '[Erai-raws] Kimetsu no Yaiba - Mugenjou Hen - Movie 01 [1080p CR WEBRip HEVC AAC][MultiSub][8E47462C].mkv';

String bleach(int n) => '$anime/${n < 112 ? b2 : b3}/[Judas] Bleach - ${n.toString().padLeft(3, '0')}.mkv';

const _tybw = AniListEntry(
    id: 41467, romaji: 'BLEACH: Sennen Kessen-hen', english: 'Bleach: Thousand-Year Blood War', format: 'TV', episodes: 13);

class FakeAniList implements AniListLookup {
  final searches = <String>[];
  @override
  Future<List<AniListEntry>> searchAnime(String query) async {
    searches.add(query);
    return query.toLowerCase().contains('thousand') ? const [_tybw] : const [];
  }

  @override
  Future<AniListEntry?> anime(int id) async => null;
}

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
  bool alone = false,
  bool relayed = false,
  Future<String?> Function(String path)? onPlay,
  ThumbnailLoader? thumbnails,
  Future<String?> Function()? pickFolder,
  String? nowPlayingPath,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(scoped(_graph, MaterialApp(
    home: Scaffold(
      body: FilesPage(
        alone: alone,
        relayed: relayed,
        onPlay: onPlay ?? (_) async => null,
        thumbnails: thumbnails ?? fakeThumb,
        scan: inlineScan,
        store: store,
        matcher: matcher,
        pickFolder: pickFolder,
        nowPlayingPath: nowPlayingPath,
      ),
    ),
  )));
  await frames(tester);
}

Future<void> openPlace(WidgetTester tester, String name) async {
  await tester.tap(find.text(name).first);
  await frames(tester);
}

/// Scrolls the main list until [f] is on screen.
Future<void> reveal(WidgetTester tester, Finder f) async {
  await tester.scrollUntilVisible(f, 150,
      scrollable: find.descendant(of: find.byType(CustomScrollView), matching: find.byType(Scrollable)).first);
  await frames(tester, 3);
}

/// A show's card in the library opens its page.
Future<void> openShow(WidgetTester tester, String title) async {
  final card = find.descendant(of: find.byType(PosterCard), matching: find.text(title));
  await reveal(tester, card);
  await tester.tap(card);
  await frames(tester);
}

void main() {
  setUp(() async {
    tmp = Directory(_tmp).createTempSync('files_page_');
    anime = '${tmp.path}/Binux';
    for (final j in ['App', 'Audio', 'Video']) {
      touch('$anime/$b1/$j#D4aIyEEtZEWR9gBorzBWiMh_.lnk');
    }
    for (final n in [56, 57, 58, 59, 60, 61, 62, 63, 64, 65, 108, 109, 110, 111, 112, 113]) {
      touch(bleach(n));
    }
    for (var n = 1; n <= 3; n++) {
      touch('$anime/$sao/[Judas] Sword Art Online S3 - 0$n.mkv');
    }
    for (final x in ['Opening 1', 'Ending 1']) {
      touch('$anime/$sao/[Judas] Sword Art Online S3 - $x.mkv');
    }
    touch('$anime/$sao/[Judas] Sword Art Online S3 - 01.srt');
    touch('$anime/[Judas] Re.Zero - S04E17.mkv');
    touch('$anime/$kimetsu');
    touch('$anime/notes.txt');
    // An in-memory box: the store loads and writes through it, with no
    // file I/O left pending in the widget tests' fake-async zone.
    await Hive.openBox(filesBoxName, bytes: Uint8List(0));
    store = FolderStore();
    await store.ensureLoaded();
    aniList = FakeAniList();
    matcher = ShowMatcher(store: MemoryLibraryStore(), aniList: aniList, delay: (_) async {});
    thumbRequests = [];
    scans = 0;
    resetFilesPageSession();
  });

  tearDown(() async {
    await Hive.close();
    tmp.deleteSync(recursive: true);
  });

  testWidgets('the Library first: empty until a folder is added, then its shows', (tester) async {
    await pumpPage(tester, pickFolder: () async => anime);
    expect(find.text('Library'), findsNWidgets(2)); // sidebar + header
    expect(find.text('Your library is empty'), findsOneWidget);
    await tester.tap(find.text('Add folder').first);
    await frames(tester);
    expect(store.folders.value, [anime]);
    expect(find.text('Binux'), findsNWidgets(2)); // sidebar + header
    expect(scans, 1);
    // Back to the Library: the same scan, now grouped into shows.
    await openPlace(tester, 'Library');
    expect(scans, 1);
    expect(find.text('3 shows'), findsOneWidget); // sidebar
    expect(find.byType(PosterCard), findsNWidgets(4));
    expect(find.text('Shows'), findsOneWidget);
    expect(find.text('Movies'), findsOneWidget);

    await openPlace(tester, 'Recent');
    expect(find.text('Nothing played yet'), findsOneWidget);
    await tester.tap(find.byTooltip('Remove folder'));
    await frames(tester);
    expect(store.folders.value, isEmpty);
  });

  testWidgets('shows, a movie, counts and what is hidden', (tester) async {
    store.addFolder(anime);
    await pumpPage(tester);
    for (final t in ['Bleach', 'Re.Zero', 'Sword Art Online']) {
      expect(find.descendant(of: find.byType(PosterCard), matching: find.text(t)), findsOneWidget);
    }
    expect(find.text('16 episodes'), findsOneWidget); // Bleach
    expect(find.text('Kimetsu no Yaiba - Mugenjou Hen'), findsOneWidget);
    expect(find.text('Movie 1 · 1 KB'), findsOneWidget);
    expect(find.text('23 videos in 3 shows · 4 other files hidden · 1 subtitle file'), findsOneWidget);
    expect(find.byType(VideoCard), findsNothing, reason: 'nothing is left over');

    // The folder view says which files were left out.
    await openPlace(tester, 'Binux');
    await tester.tap(find.text('Show some'));
    await frames(tester);
    expect(find.text('notes.txt'), findsOneWidget);
    expect(find.text('App#D4aIyEEtZEWR9gBorzBWiMh_.lnk'), findsOneWidget);
  });

  testWidgets('a show page: season with its name, episodes, extras', (tester) async {
    store.addFolder(anime);
    await pumpPage(tester);
    await openShow(tester, 'Sword Art Online');
    expect(find.text('Season 3 · Alicization'), findsOneWidget);
    for (final e in ['Episode 1', 'Episode 2', 'Episode 3']) {
      expect(find.text(e), findsOneWidget);
    }
    expect(find.text('Extras'), findsOneWidget);
    expect(find.text('OP1'), findsOneWidget);
    expect(find.text('ED1'), findsOneWidget);
    expect(find.text('Play: S3 E1'), findsOneWidget);
    expect(find.text('Not matched on AniList'), findsOneWidget);
    // The open show stays open for the session; Back returns.
    await openPlace(tester, 'Recent');
    await openPlace(tester, 'Library');
    expect(find.text('Season 3 · Alicization'), findsOneWidget);
    await tester.tap(find.text('Library').last);
    await frames(tester);
    expect(find.byType(PosterCard), findsNWidgets(4));
  });

  testWidgets('next episode knows what is missing: start at 56, then skip to 108', (tester) async {
    store.addFolder(anime);
    final played = <String>[];
    await pumpPage(tester, onPlay: (p) async {
      played.add(p);
      return null;
    });
    await openShow(tester, 'Bleach');
    expect(find.text('1–55 aren\'t in your folders — start at 56?'), findsOneWidget);
    await tester.tap(find.text('Start at 56'));
    await frames(tester);
    expect(played, [bleach(56)]);
    await reveal(tester, find.text('66–107 aren\'t in your folders')); // in the list

    // Watched up to 65: the next one is 108, and the page says why.
    await reveal(tester, find.text('Episode 65'));
    await tester.tap(find.text('Episode 65'));
    await frames(tester);
    expect(store.recent.value.first, bleach(65));
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 3000));
    await frames(tester, 3);
    expect(find.text('66–107 aren\'t in your folders — skip to 108?'), findsOneWidget);
    await tester.tap(find.text('Skip to 108'));
    await frames(tester);
    expect(played.last, bleach(108));
    expect(find.text('Next: 109'), findsOneWidget);

    // The card says it too.
    await tester.tap(find.text('Library').last);
    await frames(tester);
    expect(find.text('Next: 109'), findsOneWidget);

    // Recent names the show and episode.
    await openPlace(tester, 'Recent');
    expect(find.text('Bleach · E108'), findsOneWidget);
  });

  testWidgets("right-click: a show's card puts up its next episode or opens its page; a video works with no server",
      (tester) async {
    store.addFolder(anime);
    final played = <String>[];
    await pumpPage(tester, onPlay: (p) async {
      played.add(p);
      return null;
    });
    final bleachCard = find.widgetWithText(PosterCard, 'Bleach');
    await reveal(tester, bleachCard);
    await tester.tap(bleachCard, buttons: kSecondaryButton);
    await frames(tester, 3);
    // What the show page's button plays; no server: no Up next rows.
    expect(find.text('Put it up · Episode 56'), findsOneWidget);
    expect(find.text('Add to queue'), findsNothing);
    await tester.tap(find.text('Put it up · Episode 56'));
    await frames(tester);
    expect(played, [bleach(56)]);
    await tester.tap(bleachCard, buttons: kSecondaryButton);
    await frames(tester, 3);
    await tester.tap(find.text('Open the show page'));
    await frames(tester);
    expect(find.text('Wrong show?'), findsOneWidget);
    // An episode row there: the same menu with no server.
    await reveal(tester, find.text('Episode 57'));
    await tester.tap(find.text('Episode 57'), buttons: kSecondaryButton);
    await frames(tester, 3);
    await tester.tap(find.text('Put it up'));
    await frames(tester);
    expect(played.last, bleach(57));
  });

  testWidgets('Wrong show? pins the right AniList entry and the names follow', (tester) async {
    store.addFolder(anime);
    await pumpPage(tester);
    await openShow(tester, 'Bleach');
    await tester.tap(find.text('Wrong show?'));
    await frames(tester);
    await tester.enterText(find.byType(TextField), 'Bleach Thousand-Year Blood War');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await frames(tester);
    expect(aniList.searches.last, 'Bleach Thousand-Year Blood War');
    await tester.tap(find.text('Bleach: Thousand-Year Blood War'));
    await frames(tester);
    expect(matcher.showPin('bleach'), 41467);
    expect(find.text('Bleach: Thousand-Year Blood War'), findsOneWidget); // the page's title
    expect(find.text('pinned'), findsOneWidget);
    expect(find.textContaining('files say "Bleach"'), findsOneWidget);
    await tester.tap(find.text('Library').last);
    await frames(tester);
    expect(find.descendant(of: find.byType(PosterCard), matching: find.text('Bleach: Thousand-Year Blood War')),
        findsOneWidget);
  });

  testWidgets('episode numbers: the first file is episode N', (tester) async {
    store.addFolder(anime);
    await pumpPage(tester);
    await openShow(tester, 'Sword Art Online');
    await tester.tap(find.text('Episode numbers…'));
    await frames(tester);
    await tester.enterText(find.byKey(const ValueKey('offset:3')), '25');
    await tester.tap(find.text('Save'));
    await frames(tester);
    expect(matcher.offset('sword art online', 3), 24);
    expect(find.text('Episode 25'), findsOneWidget);
  });

  testWidgets('a play goes to onPlay and into Recent; failures are shown, not kept', (tester) async {
    store.addFolder(anime);
    final played = <String>[];
    String? reply;
    await pumpPage(tester, relayed: true, onPlay: (p) async {
      played.add(p);
      return reply;
    });
    expect(find.textContaining('Keep the app open while it plays'), findsOneWidget);
    reply = 'Nobody can play mkv here';
    await reveal(tester, find.text('Kimetsu no Yaiba - Mugenjou Hen'));
    await tester.tap(find.text('Kimetsu no Yaiba - Mugenjou Hen'));
    await frames(tester);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 3000));
    await frames(tester);
    expect(played, ['$anime/$kimetsu']);
    expect(find.text('Nobody can play mkv here'), findsOneWidget);
    expect(store.recent.value, isEmpty);
  });

  testWidgets('now playing is marked on its show and row', (tester) async {
    store.addFolder(anime);
    await pumpPage(tester, nowPlayingPath: '$anime/$sao/[Judas] Sword Art Online S3 - 02.mkv');
    await openShow(tester, 'Sword Art Online');
    expect(find.text('now playing'), findsOneWidget);
    expect(find.byIcon(Icons.graphic_eq), findsOneWidget);
  });

  testWidgets('narrow: places become chips above the list', (tester) async {
    store.addFolder('$anime/');
    await pumpPage(tester, size: const Size(600, 800));
    expect(find.text('Folders'), findsNothing);
    expect(find.widgetWithText(ChoiceChip, 'Library'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, 'Recent'), findsOneWidget);
    expect(find.widgetWithText(InputChip, 'Binux'), findsOneWidget);
    await openShow(tester, 'Re.Zero');
    expect(find.text('Season 4'), findsOneWidget);
    expect(find.text('16 isn\'t in your folders'), findsNothing);
    expect(find.text('1–16 aren\'t in your folders — start at 17?'), findsOneWidget);
    await tester.tap(find.byTooltip('Remove folder'));
    await frames(tester);
    expect(store.folders.value, isEmpty);
    expect(tester.takeException(), isNull);
  });

  for (final size in const [Size(2560, 1080), Size(1100, 700), Size(900, 600), Size(420, 700)]) {
    testWidgets('no overflow at ${size.width.toInt()}x${size.height.toInt()}', (tester) async {
      store.addFolder(anime);
      for (var i = 0; i < 7; i++) {
        touch('$anime/clips/A Clip With A Rather Long Title Indeed Part $i.mkv');
      }
      store.addRecent(bleach(56));
      await pumpPage(tester, size: size, relayed: true);
      expect(tester.takeException(), isNull);
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -2000));
      await frames(tester);
      expect(tester.takeException(), isNull);
      await tester.drag(find.byType(CustomScrollView), const Offset(0, 4000));
      await frames(tester);
      await openShow(tester, 'Bleach');
      await reveal(tester, find.text('Episode 56'));
      expect(tester.takeException(), isNull);
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -2000));
      await frames(tester);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('thumbnails load for visible rows only, and cancel when scrolled away', (tester) async {
    final big = '${tmp.path}/big';
    for (var i = 1; i <= 120; i++) {
      touch('$big/Long Show - ${i.toString().padLeft(3, '0')}.mkv');
    }
    store.addFolder(big);
    final gates = <String, bool Function()>{};
    await pumpPage(tester, size: const Size(1100, 700), thumbnails: (path, {cancelled}) {
      thumbRequests.add(path);
      gates[path] = cancelled!;
      return Completer<Thumbnail?>().future; // never finishes
    });
    await openShow(tester, 'Long Show');
    expect(find.text('Episode 1'), findsOneWidget);
    final first = thumbRequests.toSet();
    expect(first, isNotEmpty);
    expect(first.length, lessThan(30));
    // (Episode 1's frame is also the header's banner, which stays.)
    expect(first, contains('$big/Long Show - 002.mkv'));
    expect(gates['$big/Long Show - 002.mkv']!(), isFalse);

    // Fly past the middle: rows that only flash by never ask.
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -6000));
    await tester.pump();
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -6000));
    await frames(tester);
    expect(gates['$big/Long Show - 002.mkv']!(), isTrue);
    expect(thumbRequests, contains('$big/Long Show - 120.mkv'));
    expect(thumbRequests.toSet().length, lessThan(60));
  });
}
