import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:starsync/src/schedule/anilist.dart';
import 'package:starsync/src/schedule/animeflow.dart';
import 'package:starsync/src/schedule/schedule_model.dart';
import 'package:starsync/src/schedule/schedule_store.dart';
import 'package:starsync/src/schedule/ui/schedule_page.dart' show keptWhen;

final _airing = Airing(
  anilistId: 7,
  title: 'Frieren',
  titleRomaji: 'Sousou no Frieren',
  episode: 5,
  airingAt: DateTime.utc(2026, 11, 6, 15, 30),
  cover: 'https://img/c.jpg',
  banner: 'https://img/b.jpg',
  color: const Color(0xff1a2b3c),
  popularity: 123456,
);

final _snapshot = ScheduleSnapshot(
  from: DateTime(2026, 10, 26),
  to: DateTime(2026, 11, 23),
  entries: [
    ScheduleEntry(
      airing: _airing,
      status: ScheduleStatus.available,
      tracked: true,
      seriesId: 3,
      season: 2,
      jellyfinEpisode: 5,
      jellyfinSeriesId: 'jf3',
      watch: const EpisodeWatch(progress: 0.4),
    ),
    ScheduleEntry(
      airing: _airing,
      status: ScheduleStatus.missing,
      reason: 'release rejected',
      lastSearchedAt: DateTime.utc(2026, 11, 7, 9),
      progress: 0.25,
    ),
  ],
  animeFlowError: null,
  me: const AnimeFlowMe(userId: 'u1', name: 'Foxy', scopes: {AnimeFlowScope.view, AnimeFlowScope.request}),
);

void main() {
  test('a kept schedule reads back as it was', () {
    final saved = DateTime(2026, 11, 7, 21, 40);
    final j = jsonDecode(jsonEncode(keptToJson(_snapshot, saved, 'k')));
    final back = keptFromJson(j, 'k')!;
    expect(back.savedAt, saved);
    final s = back.snapshot;
    expect((s.from, s.to), (_snapshot.from, _snapshot.to));
    expect(s.me?.name, 'Foxy');
    expect(s.me?.scopes, {AnimeFlowScope.view, AnimeFlowScope.request});
    final a = s.entries.first.airing;
    expect((a.anilistId, a.title, a.titleRomaji, a.episode, a.airingAt, a.cover, a.banner, a.color, a.popularity),
        (7, 'Frieren', 'Sousou no Frieren', 5, _airing.airingAt, 'https://img/c.jpg', 'https://img/b.jpg',
            const Color(0xff1a2b3c), 123456));
    final e = s.entries.first, m = s.entries.last;
    expect((e.status, e.tracked, e.seriesId, e.season, e.jellyfinEpisode, e.jellyfinSeriesId, e.watch),
        (ScheduleStatus.available, true, 3, 2, 5, 'jf3', const EpisodeWatch(progress: 0.4)));
    expect((m.status, m.reason, m.lastSearchedAt, m.progress, m.tracked, m.watch),
        (ScheduleStatus.missing, 'release rejected', DateTime.utc(2026, 11, 7, 9), 0.25, false, null));
    // Another account's file, or another format: nothing.
    expect(keptFromJson(j, 'other'), isNull);
    expect(keptFromJson({...j as Map, 'version': 0}, 'k'), isNull);
  });

  test('kept on disk, per key', () async {
    final dir = await Directory.systemTemp.createTemp('schedule-store-test');
    addTearDown(() => dir.delete(recursive: true));
    final store = ScheduleStore(dir: () async => dir);
    final at = DateTime(2026, 11, 7, 21, 40);
    await store.write(scheduleKeyFor('https://a/api', serverId: 's', userId: 'u'), _snapshot, at);
    expect((await store.read(scheduleKeyFor('https://a/api', serverId: 's', userId: 'u')))?.savedAt, at);
    expect(await store.read(scheduleKeyFor('https://a/api', serverId: 's', userId: 'other')), isNull);
    expect(await ScheduleStore(dir: () async => null).read('x'), isNull);
  });

  test('old: past an hour, or another day', () {
    final now = DateTime(2026, 11, 7, 12);
    expect(keptScheduleIsOld(DateTime(2026, 11, 7, 11, 30), now), isFalse);
    expect(keptScheduleIsOld(DateTime(2026, 11, 7, 10, 30), now), isTrue);
    expect(keptScheduleIsOld(DateTime(2026, 11, 6, 23, 50), DateTime(2026, 11, 7, 0, 10)), isTrue);
  });

  test('when it was kept, in words', () {
    final now = DateTime(2026, 11, 7, 12);
    expect(keptWhen(DateTime(2026, 11, 7, 9, 5), now), '09:05');
    expect(keptWhen(DateTime(2026, 11, 6, 21, 40), now), 'yesterday 21:40');
    expect(keptWhen(DateTime(2026, 11, 3, 8, 0), now), 'Tue 3 Nov, 08:00');
  });
}
