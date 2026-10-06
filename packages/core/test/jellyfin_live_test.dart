// Live tests against a real Jellyfin server. Skipped unless configured:
//
//   JELLYFIN_TEST_URL, JELLYFIN_TEST_TOKEN   server and a user access token
//   JELLYFIN_TEST_DEVICE, JELLYFIN_TEST_VERSION, JELLYFIN_TEST_DEVICE_ID,
//   JELLYFIN_TEST_CLIENT                     the token's own device fields
//
// The device fields are required because Jellyfin overwrites a token's stored
// device name and app version with whatever the Authorization header says;
// borrowing another app's token with our own fields would rename that
// device on the user's account.
//
// The write test (Playing -> Progress -> Stopped, then restore) also needs
//   JELLYFIN_TEST_WRITE_ITEM   an episode id whose whole series is unwatched
// and refuses to run if the episode or any episode of its series has been
// played or has a resume position. Never commit these values.
library;

import 'dart:io';

import 'package:sync_relay_core/core.dart';
import 'package:test/test.dart';

void main() {
  final env = Platform.environment;
  final url = env['JELLYFIN_TEST_URL'];
  final token = env['JELLYFIN_TEST_TOKEN'];
  final device = env['JELLYFIN_TEST_DEVICE'];
  final version = env['JELLYFIN_TEST_VERSION'];
  final skip = (url == null || token == null || device == null || version == null)
      ? 'JELLYFIN_TEST_* not set'
      : null;

  late JellyfinClient client;
  late JellyfinUser me;

  setUpAll(() async {
    if (skip != null) return;
    client = JellyfinClient(
      baseUrl: url!,
      clientInfo: JellyfinClientInfo(
        client: env['JELLYFIN_TEST_CLIENT'] ?? 'Watch Together',
        device: device!,
        deviceId: env['JELLYFIN_TEST_DEVICE_ID'] ?? 'wt-live-test',
        version: version!,
      ),
      accessToken: token,
    );
    me = (await client.validateToken())!;
  });

  tearDownAll(() {
    if (skip == null) client.close();
  });

  test('server info and token', () async {
    final info = await client.publicInfo();
    expect(info.id, isNotEmpty);
    expect(info.version, isNotEmpty);
    expect(me.id, client.userId);
  }, skip: skip);

  test('Quick Connect initiate works (no sign-in completed)', () async {
    final anon = JellyfinClient(
      baseUrl: url!,
      clientInfo: const JellyfinClientInfo(
          client: 'Watch Together', device: 'live test', deviceId: 'wt-live-test-qc', version: '0.0.0'),
    );
    addTearDown(anon.close);
    if (!await anon.quickConnectEnabled()) return markTestSkipped('Quick Connect disabled');
    final qc = await anon.quickConnectInitiate();
    expect(qc.code, matches(RegExp(r'^\d{6}$')));
    expect(qc.secret, isNotEmpty);
    final state = await anon.quickConnectCheck(qc.secret);
    expect(state.authenticated, isFalse);
  }, skip: skip);

  test('browse: views, resume, next up, latest, library page, search', () async {
    final views = await client.userViews();
    expect(views, isNotEmpty);
    await client.resume(limit: 5);
    await client.nextUp(limit: 5);
    final tv = views.where((v) => v.collectionType == 'tvshows').firstOrNull;
    if (tv == null) return;
    expect(await client.latest(tv.id, limit: 3), isNotEmpty);
    final page = await client.items(JellyfinItemQuery(
        parentId: tv.id, includeItemTypes: const [JellyfinItemType.series], recursive: true, limit: 3));
    expect(page.items, hasLength(3));
    expect(page.totalRecordCount, greaterThanOrEqualTo(3));
    final second = await client.items(JellyfinItemQuery(
            parentId: tv.id, includeItemTypes: const [JellyfinItemType.series], recursive: true)
        .page(3, 3));
    expect(second.items.first.id, isNot(page.items.first.id));
    final hits = await client.search(page.items.first.name.split(' ').first);
    expect(hits, isNotEmpty);
  }, skip: skip);

  test('series -> seasons -> episodes -> next, playback info, ranged stream', () async {
    final views = await client.userViews();
    final tv = views.firstWhere((v) => v.collectionType == 'tvshows');
    final series = (await client.items(JellyfinItemQuery(
            parentId: tv.id, includeItemTypes: const [JellyfinItemType.series], recursive: true, limit: 1)))
        .items
        .single;
    expect(await client.seasons(series.id), isNotEmpty);
    final eps = await client.episodes(series.id, withMediaStreams: true);
    expect(eps, isNotEmpty);
    if (eps.length > 1) expect((await client.nextEpisode(eps.first))!.id, isNot(eps.first.id));
    final detail = await client.item(eps.first.id);
    expect(detail.mediaSources, isNotEmpty);

    final pi = await client.playbackInfo(eps.first.id);
    expect(pi.playSessionId, isNotEmpty);
    final src = pi.primarySource!;
    expect(src.supportsDirectPlay, isTrue);

    final http = HttpClient();
    addTearDown(() => http.close(force: true));
    final req = await http.getUrl(client.streamUrl(eps.first.id, mediaSourceId: src.id));
    req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1023');
    final res = await req.close();
    await res.drain<void>();
    expect(res.statusCode, 206);
    expect(res.headers.value(HttpHeaders.contentRangeHeader), 'bytes 0-1023/${src.size}');
  }, skip: skip);

  final writeItem = env['JELLYFIN_TEST_WRITE_ITEM'];
  test('progress reporting changes user data, then restore', () async {
    final ep = await client.item(writeItem!);
    final siblings = await client.episodes(ep.seriesId!);
    final touched = siblings.where(
        (e) => e.userData.played || e.userData.playbackPositionTicks > 0 || e.userData.playCount > 0);
    if (touched.isNotEmpty || ep.userData.played || ep.userData.playbackPositionTicks > 0) {
      fail('refusing: series ${ep.seriesName} has watched episodes (${touched.map((e) => e.id)})');
    }

    var restored = false;
    Future<JellyfinUserData> restore() async {
      await client.markUnplayed(ep.id);
      await client.clearResumePosition(ep.id);
      restored = true;
      return client.userData(ep.id);
    }

    addTearDown(() async {
      if (!restored) await restore();
    });

    final pi = await client.playbackInfo(ep.id);
    final src = pi.primarySource!;
    final pos = (ep.runTimeTicks! * 0.3).round();
    final report = JellyfinPlaybackReport(
      itemId: ep.id,
      mediaSourceId: src.id,
      playSessionId: pi.playSessionId,
      audioStreamIndex: src.defaultAudioStreamIndex,
      subtitleStreamIndex: src.defaultSubtitleStreamIndex ?? -1,
    );
    await client.reportPlaybackStart(report);
    await client.reportPlaybackProgress(report.copyWith(positionTicks: pos));
    await client.reportPlaybackProgress(report.copyWith(positionTicks: pos, isPaused: true));
    await client.reportPlaybackStopped(report.copyWith(positionTicks: pos));

    final after = await client.userData(ep.id);
    printOnFailure('after: played=${after.played} pos=${after.playbackPositionTicks}');
    expect(after.played, isFalse);
    expect(after.playbackPositionTicks, closeTo(pos, jellyfinTicksPerSecond));

    final back = await restore();
    expect(back.played, isFalse);
    expect(back.playbackPositionTicks, 0);
    expect(back.playCount, 0);
    print('live write test on ${ep.seriesName} ${ep.episodeLabel} (${ep.id}): '
        'after=${after.playbackPositionTicks} restored pos=${back.playbackPositionTicks} '
        'played=${back.played} playCount=${back.playCount} lastPlayed=${back.lastPlayedDate}');
  }, skip: skip ?? (writeItem == null ? 'JELLYFIN_TEST_WRITE_ITEM not set' : null));
}
